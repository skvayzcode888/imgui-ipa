// Dear ImGui (Metal) overlay for 8 Ball Pool
// Open/close menu: double-tap with 3 fingers

#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach-o/dyld.h>

#include "imgui.h"
#include "imgui_internal.h"
#include "imgui_impl_metal.h"

#include <stdint.h>
#include <math.h>
#include <sys/mman.h>   // mincore
#include <unistd.h>

// ==========================================================================
//  OFFSETS (IDA Pro, reflection table 0xF04700, binary 8BP 56.29.2)
// ==========================================================================
//
//  AutoAim singleton addr (static, no ASLR): 0x104ECB0
//    AutoAim + 0x78   -> GameManager*
//    AutoAim + 0x88   -> GameManager* (fallback, try if 0x78 fails)
//
//  GameManager:
//    +0x400  -> Table*
//    +0x4D0  -> VisualCue*
//    +0x720  -> mPocketNominationButtons.begin  (vector<Button*>)
//    +0x728  -> mPocketNominationButtons.end
//
//  Table:
//    +0x468  -> mBalls.begin  (vector<Ball*>)
//    +0x470  -> mBalls.end
//    +0x478  -> mTableShape.begin (vector<vec2f>)  -- begin ptr
//    +0x480  -> mTableShape.end
//    +0x490  -> mTightTableShape.begin
//
//  Ball:
//    +0xA0  -> classification (int: 0=cue,1=solid,2=striped,3=eight)
//    +0xA4  -> state (int: 0=active, 1=pocketed)
//    +0xA8  -> number (int)
//    +0x20  -> physics ptr
//      physics+0x00 -> x (float)
//      physics+0x04 -> y (float)
//
//  Button (PocketNominationButton):
//    +0x08  -> world pos x (float)
//    +0x0C  -> world pos y (float)
//
//  VisualCue:
//    +0x18  -> table pos x (float)
//    +0x1C  -> table pos y (float)

// ==========================================================================
//  SAFE MEMORY READ  (iOS: проверяем страницу через mincore)
// ==========================================================================

static bool IsReadable(uintptr_t addr, size_t sz)
{
    if (addr < 0x10000 || addr == (uintptr_t)-1) return false;
    // mincore проверяет resident pages; возвращает 0 если страница доступна
    uintptr_t page = addr & ~(uintptr_t)(getpagesize() - 1);
    unsigned char vec = 0;
    return (mincore((void*)page, sz, &vec) == 0);
}

template<typename T>
static T SafeRead(uintptr_t addr, T def = T{})
{
    if (!IsReadable(addr, sizeof(T))) return def;
    return *(volatile T *)addr;
}

// ==========================================================================
//  ASLR SLIDE
// ==========================================================================

static uintptr_t g_slide = 0;

static uintptr_t GetSlide()
{
    if (g_slide) return g_slide;
    uint32_t cnt = _dyld_image_count();
    for (uint32_t i = 0; i < cnt; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "/pool")) {
            g_slide = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
            return g_slide;
        }
    }
    // fallback — первый образ
    g_slide = (uintptr_t)_dyld_get_image_vmaddr_slide(0);
    return g_slide;
}

static const uintptr_t kAutoAimStatic = 0x104ECB0; // из IDA: byte_104ECB0

// ==========================================================================
//  GAME STATE
// ==========================================================================

struct PocketInfo { float x, y; int idx; };

struct GameState {
    bool  valid;
    char  errMsg[128];
    // лунки
    int   pocketCount;
    PocketInfo pockets[6];
    int   nearestIdx;
    float nearestDist;
    // шары
    int   totalBalls;
    int   activeBalls;
    int   pocketedBalls;
    // кий
    float cueX, cueY;
    // debug
    uintptr_t dbgSlide;
    uintptr_t dbgAutoAim;
    uintptr_t dbgGameMgr;
    uintptr_t dbgTable;
};

static GameState ReadGameState()
{
    GameState s = {};
    s.valid       = false;
    s.nearestIdx  = -1;
    s.nearestDist = 1e9f;

    uintptr_t slide = GetSlide();
    s.dbgSlide = slide;

    // --- 1. AutoAim ptr ---
    uintptr_t ptrAddr = slide + kAutoAimStatic;
    uintptr_t autoAim = SafeRead<uintptr_t>(ptrAddr);
    s.dbgAutoAim = autoAim;
    if (!autoAim || autoAim == (uintptr_t)-1) {
        snprintf(s.errMsg, sizeof(s.errMsg), "AutoAim ptr = 0 (addr 0x%llX)", (unsigned long long)ptrAddr);
        return s;
    }

    // --- 2. GameManager ptr (offset +0x78 из sub_1F1720) ---
    uintptr_t gameMgr = SafeRead<uintptr_t>(autoAim + 0x78);
    if (!gameMgr || gameMgr == (uintptr_t)-1) {
        // пробуем +0x88
        gameMgr = SafeRead<uintptr_t>(autoAim + 0x88);
    }
    s.dbgGameMgr = gameMgr;
    if (!gameMgr || gameMgr == (uintptr_t)-1) {
        snprintf(s.errMsg, sizeof(s.errMsg), "GameMgr ptr = 0");
        return s;
    }

    // --- 3. Table* ---
    uintptr_t table = SafeRead<uintptr_t>(gameMgr + 0x400);
    s.dbgTable = table;
    if (!table || table == (uintptr_t)-1) {
        snprintf(s.errMsg, sizeof(s.errMsg), "Table ptr = 0");
        return s;
    }

    // --- 4. Лунки через mPocketNominationButtons ---
    uintptr_t pktBeg = SafeRead<uintptr_t>(gameMgr + 0x720);
    uintptr_t pktEnd = SafeRead<uintptr_t>(gameMgr + 0x728);
    if (pktBeg && pktEnd && pktEnd >= pktBeg && (pktEnd - pktBeg) <= 6*8) {
        int cnt = (int)((pktEnd - pktBeg) / sizeof(uintptr_t));
        for (int i = 0; i < cnt && i < 6; i++) {
            uintptr_t btn = SafeRead<uintptr_t>(pktBeg + i * sizeof(uintptr_t));
            if (!IsReadable(btn, 0x10)) continue;
            float px = SafeRead<float>(btn + 0x08);
            float py = SafeRead<float>(btn + 0x0C);
            // sanity: координаты стола обычно -500..500
            if (fabsf(px) > 5000.f || fabsf(py) > 5000.f) continue;
            s.pockets[s.pocketCount++] = { px, py, i };
        }
    }

    // --- 5. Fallback: mTableShape (begin = Table+0x478) ---
    if (s.pocketCount == 0) {
        uintptr_t shBeg = SafeRead<uintptr_t>(table + 0x478);
        uintptr_t shEnd = SafeRead<uintptr_t>(table + 0x480);
        if (shBeg && shEnd && shEnd > shBeg) {
            ptrdiff_t pts = (shEnd - shBeg) / 8;
            if (pts >= 6 && pts <= 10000) {
                int step = (int)(pts / 6);
                for (int i = 0; i < 6; i++) {
                    uintptr_t pt = shBeg + (uintptr_t)(i * step * 8);
                    if (!IsReadable(pt, 8)) continue;
                    float px = SafeRead<float>(pt);
                    float py = SafeRead<float>(pt + 4);
                    if (fabsf(px) > 5000.f || fabsf(py) > 5000.f) continue;
                    s.pockets[s.pocketCount++] = { px, py, i };
                }
            }
        }
    }

    // --- 6. Шары (Table+0x468) ---
    uintptr_t ballBeg = SafeRead<uintptr_t>(table + 0x468);
    uintptr_t ballEnd = SafeRead<uintptr_t>(table + 0x470);
    if (ballBeg && ballEnd && ballEnd >= ballBeg) {
        ptrdiff_t cnt = (ballEnd - ballBeg) / sizeof(uintptr_t);
        if (cnt > 0 && cnt <= 16) {
            s.totalBalls = (int)cnt;
            for (int i = 0; i < (int)cnt; i++) {
                uintptr_t ball = SafeRead<uintptr_t>(ballBeg + i * sizeof(uintptr_t));
                if (!IsReadable(ball, 0xB0)) continue;
                int state = SafeRead<int>(ball + 0xA4);
                if (state == 1) s.pocketedBalls++;
                else            s.activeBalls++;
            }
        }
    }

    // --- 7. Позиция кия (VisualCue) ---
    uintptr_t vcue = SafeRead<uintptr_t>(gameMgr + 0x4D0);
    if (IsReadable(vcue, 0x20)) {
        s.cueX = SafeRead<float>(vcue + 0x18);
        s.cueY = SafeRead<float>(vcue + 0x1C);
    }

    // --- 8. Ближайшая лунка ---
    for (int i = 0; i < s.pocketCount; i++) {
        float dx = s.pockets[i].x - s.cueX;
        float dy = s.pockets[i].y - s.cueY;
        float d  = sqrtf(dx*dx + dy*dy);
        if (d < s.nearestDist) { s.nearestDist = d; s.nearestIdx = i; }
    }

    s.valid = true;
    return s;
}

// ==========================================================================
//  РУССКИЙ ШРИФТ — грузим системный .ttf с устройства
//  (Arial/PingFang есть на всех iOS, поддерживают кириллицу)
// ==========================================================================

static bool LoadCyrillicFont(float size_px)
{
    // Пути к шрифтам с кириллицей на iOS
    const char *paths[] = {
        "/System/Library/Fonts/Cache/ArialMT.ttf",
        "/System/Library/Fonts/ArialMT.ttf",
        "/System/Library/Fonts/Core/ArialMT.ttf",
        "/System/Library/Fonts/LanguageSupport/Helvetica.dfont",
        "/System/Library/Fonts/Helvetica.ttc",
        nullptr
    };

    ImGuiIO &io = ImGui::GetIO();

    // Диапазоны: ASCII + кириллица
    static ImVector<ImWchar> ranges;
    ImFontGlyphRangesBuilder builder;
    builder.AddRanges(io.Fonts->GetGlyphRangesDefault());
    builder.AddRanges(io.Fonts->GetGlyphRangesCyrillic());
    builder.BuildRanges(&ranges);

    for (int i = 0; paths[i]; i++) {
        ImFont *f = io.Fonts->AddFontFromFileTTF(paths[i], size_px, nullptr, ranges.Data);
        if (f) return true;
    }

    // Последний резерв: встроенный шрифт ImGui (ASCII only, хотя бы не крашнется)
    io.Fonts->AddFontDefault();
    return false;
}

// ==========================================================================
//  МЕНЮ
// ==========================================================================

static bool g_showPockets = false;
static bool g_demoWindow  = false;

static void DrawMenu()
{
    ImGui::SetNextWindowSize(ImVec2(340, 380), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos (ImVec2(40,  60),  ImGuiCond_FirstUseEver);
    ImGui::Begin("crown.pw");

    ImGui::SliderFloat("UI scale", &ImGui::GetIO().FontGlobalScale, 0.6f, 2.5f);
    ImGui::Separator();

    ImGui::Checkbox("Info: luzы / шары", &g_showPockets);

    if (g_showPockets) {
        ImGui::Spacing();
        ImGui::PushStyleColor(ImGuiCol_ChildBg, ImVec4(0.08f, 0.08f, 0.13f, 0.95f));
        // высота 0 = авто до конца окна
        ImGui::BeginChild("##pk", ImVec2(0, 0), true);

        GameState gs = ReadGameState();

        if (!gs.valid) {
            ImGui::TextColored(ImVec4(1, 0.35f, 0.35f, 1), "Igra ne aktivna");
            ImGui::TextColored(ImVec4(0.7f,0.7f,0.7f,1), "err: %s", gs.errMsg);
            ImGui::Separator();
            ImGui::Text("slide    0x%llX", (unsigned long long)gs.dbgSlide);
            ImGui::Text("autoAim  0x%llX", (unsigned long long)gs.dbgAutoAim);
            ImGui::Text("gameMgr  0x%llX", (unsigned long long)gs.dbgGameMgr);
            ImGui::Text("table    0x%llX", (unsigned long long)gs.dbgTable);
        } else {
            // --- Лунки ---
            ImGui::TextColored(ImVec4(0.4f,1,0.4f,1),
                "Lunok vsego: %d", gs.pocketCount);

            if (gs.nearestIdx >= 0) {
                ImGui::TextColored(ImVec4(1,1,0.3f,1),
                    "Blizhayshaya: #%d  dist=%.1f",
                    gs.nearestIdx, gs.nearestDist);
                ImGui::Text("  X=%.2f  Y=%.2f",
                    gs.pockets[gs.nearestIdx].x,
                    gs.pockets[gs.nearestIdx].y);
            } else {
                ImGui::TextColored(ImVec4(0.6f,0.6f,0.6f,1), "Net dannykh po luzam");
            }

            ImGui::Separator();
            ImGui::Text("Vse luzy:");
            for (int i = 0; i < gs.pocketCount; i++) {
                bool near = (i == gs.nearestIdx);
                if (near) ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1,1,0.3f,1));
                ImGui::Text("  [%d]  X=%.2f  Y=%.2f%s",
                    i, gs.pockets[i].x, gs.pockets[i].y,
                    near ? "  <--" : "");
                if (near) ImGui::PopStyleColor();
            }
            if (gs.pocketCount == 0)
                ImGui::TextColored(ImVec4(1,0.55f,0,1),
                    "PocketNomButtons pust\n(rezhim bez vybora luzy)");

            ImGui::Separator();
            // --- Шары ---
            ImGui::Text("Shary:");
            ImGui::Text("  Vsego:   %d", gs.totalBalls);
            ImGui::Text("  Na stole:%d", gs.activeBalls);
            ImGui::TextColored(ImVec4(0.5f,0.9f,1,1),
                "  Zabito:  %d", gs.pocketedBalls);

            ImGui::Separator();
            // --- Debug ---
            ImGui::TextColored(ImVec4(0.5f,0.5f,0.5f,1),"[debug]");
            ImGui::Text("cue X=%.2f Y=%.2f", gs.cueX, gs.cueY);
            ImGui::Text("slide 0x%llX", (unsigned long long)gs.dbgSlide);
        }

        ImGui::EndChild();
        ImGui::PopStyleColor();
    }

    ImGui::Separator();
    ImGui::Checkbox("Demo window", &g_demoWindow);
    ImGui::Text("%.1f FPS", ImGui::GetIO().Framerate);
    ImGui::End();

    if (g_demoWindow) ImGui::ShowDemoWindow(&g_demoWindow);
}

// ==========================================================================
//  OVERLAY VIEW
// ==========================================================================

@interface OverlayView : UIView <MTKViewDelegate>
@property (nonatomic, strong) MTKView            *mtk;
@property (nonatomic, strong) id<MTLDevice>       device;
@property (nonatomic, strong) id<MTLCommandQueue> queue;
@property (nonatomic)         BOOL                menuOpen;
- (void)toggleMenu;
@end

@implementation OverlayView

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.multipleTouchEnabled = YES;

    _device = MTLCreateSystemDefaultDevice();
    _queue  = [_device newCommandQueue];

    _mtk = [[MTKView alloc] initWithFrame:self.bounds device:_device];
    _mtk.delegate               = self;
    _mtk.autoresizingMask       = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    _mtk.colorPixelFormat       = MTLPixelFormatBGRA8Unorm;
    _mtk.clearColor             = MTLClearColorMake(0,0,0,0);
    _mtk.backgroundColor        = UIColor.clearColor;
    _mtk.opaque                 = NO;
    _mtk.layer.opaque           = NO;
    _mtk.userInteractionEnabled = NO;
    _mtk.preferredFramesPerSecond = 60;
    _mtk.paused = YES;
    _mtk.hidden = YES;
    [self addSubview:_mtk];

    // --- ImGui ---
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = nullptr;
    io.ConfigFlags |= ImGuiConfigFlags_NoMouseCursorChange;
    ImGui::StyleColorsDark();
    ImGui::GetStyle().ScaleAllSizes(1.2f);

    // Грузим шрифт с кириллицей
    LoadCyrillicFont(18.0f);
    io.FontGlobalScale = 1.2f;

    ImGui_ImplMetal_Init(_device);
    return self;
}

- (void)toggleMenu
{
    self.menuOpen      = !self.menuOpen;
    self.mtk.hidden    = !self.menuOpen;
    self.mtk.paused    = !self.menuOpen;
}

- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)event
{
    if (!self.menuOpen) return nil;
    ImGuiContext *g = ImGui::GetCurrentContext();
    if (!g) return nil;
    for (ImGuiWindow *w : g->Windows) {
        if (w->Active && !w->Hidden &&
            (w->Flags & ImGuiWindowFlags_NoInputs) == 0 &&
            w->Rect().Contains(ImVec2((float)p.x,(float)p.y)))
            return self;
    }
    return nil;
}

- (void)feed:(NSSet<UITouch *> *)touches down:(BOOL)down
{
    UITouch *t = touches.anyObject;
    if (!t) return;
    CGPoint p = [t locationInView:self];
    ImGuiIO &io = ImGui::GetIO();
    io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);
    io.AddMousePosEvent((float)p.x,(float)p.y);
    io.AddMouseButtonEvent(0, down);
}
- (void)touchesBegan:(NSSet*)t withEvent:(UIEvent*)e    { [self feed:t down:YES]; }
- (void)touchesMoved:(NSSet*)t withEvent:(UIEvent*)e    { [self feed:t down:YES]; }
- (void)touchesEnded:(NSSet*)t withEvent:(UIEvent*)e    { [self feed:t down:NO];  }
- (void)touchesCancelled:(NSSet*)t withEvent:(UIEvent*)e{ [self feed:t down:NO];  }

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

- (void)drawInMTKView:(MTKView *)view
{
    CGSize b = view.bounds.size;
    CGSize d = view.drawableSize;
    if (b.width <= 0 || b.height <= 0) return;

    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize           = ImVec2((float)b.width,(float)b.height);
    io.DisplayFramebufferScale = ImVec2((float)(d.width/b.width),(float)(d.height/b.height));

    static CFTimeInterval last = 0;
    CFTimeInterval now = CACurrentMediaTime();
    io.DeltaTime = (last > 0) ? (float)(now - last) : (1.f/60.f);
    if (io.DeltaTime <= 0) io.DeltaTime = 1.f/60.f;
    last = now;

    id<MTLCommandBuffer>          cb  = [self.queue commandBuffer];
    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (!rpd) { [cb commit]; return; }

    ImGui_ImplMetal_NewFrame(rpd);
    ImGui::NewFrame();
    DrawMenu();
    ImGui::Render();

    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
    [enc pushDebugGroup:@"ImGui"];
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
    [enc popDebugGroup];
    [enc endEncoding];
    [cb presentDrawable:view.currentDrawable];
    [cb commit];
}
@end

// ==========================================================================
//  УСТАНОВКА В ИГРУ
// ==========================================================================

static UIWindow *FindKeyWindow()
{
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        if (ws.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ws.windows)
            if (w.isKeyWindow) return w;
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

static OverlayView *g_overlay = nil;

static void TryInstall(int attempt)
{
    UIWindow *w = FindKeyWindow();
    if (!w || !w.rootViewController.view) {
        if (attempt < 60)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{ TryInstall(attempt+1); });
        return;
    }

    g_overlay = [[OverlayView alloc] initWithFrame:w.bounds];
    [w addSubview:g_overlay];

    UITapGestureRecognizer *gr =
        [[UITapGestureRecognizer alloc] initWithTarget:g_overlay action:@selector(toggleMenu)];
    gr.numberOfTapsRequired    = 2;
    gr.numberOfTouchesRequired = 3;
    gr.cancelsTouchesInView    = NO;
    gr.delaysTouchesBegan      = NO;
    gr.delaysTouchesEnded      = NO;
    [w addGestureRecognizer:gr];
}

__attribute__((constructor))
static void Entry()
{
    dispatch_async(dispatch_get_main_queue(), ^{ TryInstall(0); });
}
