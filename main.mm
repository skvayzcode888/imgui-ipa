// Dear ImGui (Metal) overlay — 8 Ball Pool mod
// Open/close: 3-finger double-tap

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
#include <stdio.h>
#include <string.h>

// ============================================================
//  OFFSETS (IDA 8BP 56.29.2, reflection table 0xF04700)
// ============================================================
//  Global static ptr to AutoAim object: 0x104ECB0
//    AutoAim + 0x78   -> GameManager*
//    AutoAim + 0x88   -> GameManager* (fallback)
//  GameManager:
//    +0x400 -> Table*
//    +0x4D0 -> VisualCue*
//    +0x720 -> mPocketNominationButtons.begin (vector<Button*>)
//    +0x728 -> mPocketNominationButtons.end
//  Table:
//    +0x468 -> mBalls.begin
//    +0x470 -> mBalls.end
//    +0x478 -> mTableShape.begin (vector<vec2f>)
//    +0x480 -> mTableShape.end
//  Ball:
//    +0xA4  -> state (0=active, 1=pocketed)
//  Button: +0x08 -> world X, +0x0C -> world Y
//  VisualCue: +0x18 -> X, +0x1C -> Y

static const uintptr_t kAutoAimStatic = 0x104ECB0;

// ============================================================
//  SAFE READ — ObjC exception guard, никакого mincore
// ============================================================

template<typename T>
static T SafeRead(uintptr_t addr, T def = T{})
{
    // базовые sanity checks
    if (addr < 0x100000000ULL || addr == (uintptr_t)-1) return def;
    // выравнивание
    if (addr % alignof(T) != 0) return def;
    T val = def;
    @try {
        val = *(volatile T *)addr;
    } @catch (...) {
        val = def;
    }
    return val;
}

static bool IsPtr(uintptr_t p)
{
    // Валидный userspace arm64 указатель: 0x100000000 .. 0x7FFFFFFFFFFF
    return (p >= 0x100000000ULL && p <= 0x7FFFFFFFFFFFULL);
}

// ============================================================
//  ASLR
// ============================================================

static uintptr_t g_slide     = 0;
static int       g_slideIdx  = -1;  // индекс найденного образа
static char      g_imageName[256] = {};

// Ключевые слова в имени главного бинаря игры (пробуем по порядку)
static const char *kGameNames[] = {
    "8 Ball Pool",
    "8BallPool",
    "miniclip",
    "pool",
    nullptr
};

static uintptr_t GetSlide()
{
    if (g_slide) return g_slide;

    uint32_t cnt = _dyld_image_count();

    // Сначала ищем по ключевым словам (без учёта регистра не нужно — пути в iOS lowercase)
    for (int k = 0; kGameNames[k]; k++) {
        for (uint32_t i = 0; i < cnt; i++) {
            const char *n = _dyld_get_image_name(i);
            if (!n) continue;
            if (strstr(n, kGameNames[k])) {
                g_slide    = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
                g_slideIdx = (int)i;
                strncpy(g_imageName, n, sizeof(g_imageName)-1);
                return g_slide;
            }
        }
    }

    // Fallback: образ с наибольшим размером текст-сегмента — это обычно главный бинарь
    // Берём образ у которого slide НЕ равен слайду нашего dylib'а
    // (наш dylib — первый в списке или последний, главный бинарь — обычно индекс 0)
    uintptr_t mySlide = (uintptr_t)_dyld_get_image_vmaddr_slide(
        _dyld_image_count() - 1);  // наш dylib последний

    for (uint32_t i = 0; i < cnt; i++) {
        uintptr_t sl = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
        if (sl != mySlide) {
            const char *n = _dyld_get_image_name(i);
            if (n && strstr(n, ".app/")) {
                g_slide    = sl;
                g_slideIdx = (int)i;
                strncpy(g_imageName, n, sizeof(g_imageName)-1);
                return g_slide;
            }
        }
    }

    // Последний резерв: индекс 0
    g_slide    = (uintptr_t)_dyld_get_image_vmaddr_slide(0);
    g_slideIdx = 0;
    strncpy(g_imageName, _dyld_get_image_name(0) ?: "?", sizeof(g_imageName)-1);
    return g_slide;
}

// ============================================================
//  GAME STATE
// ============================================================

struct PocketInfo { float x, y; int idx; };

struct GameState {
    bool  valid;
    char  err[128];
    int   pocketCount;
    PocketInfo pockets[6];
    int   nearestIdx;
    float nearestDist;
    int   totalBalls, activeBalls, pocketedBalls;
    float cueX, cueY;
    uintptr_t dbgSlide, dbgAA, dbgGM, dbgTbl;
};

static GameState ReadGameState()
{
    GameState s = {};
    s.nearestIdx  = -1;
    s.nearestDist = 1e9f;

    s.dbgSlide = GetSlide();

    uintptr_t ptrAddr = s.dbgSlide + kAutoAimStatic;
    uintptr_t aa      = SafeRead<uintptr_t>(ptrAddr);
    s.dbgAA = aa;
    if (!IsPtr(aa)) {
        snprintf(s.err, sizeof(s.err), "AutoAim=0 @ 0x%llX", (unsigned long long)ptrAddr);
        return s;
    }

    uintptr_t gm = SafeRead<uintptr_t>(aa + 0x78);
    if (!IsPtr(gm)) gm = SafeRead<uintptr_t>(aa + 0x88);
    s.dbgGM = gm;
    if (!IsPtr(gm)) {
        snprintf(s.err, sizeof(s.err), "GameMgr=0");
        return s;
    }

    uintptr_t tbl = SafeRead<uintptr_t>(gm + 0x400);
    s.dbgTbl = tbl;
    if (!IsPtr(tbl)) {
        snprintf(s.err, sizeof(s.err), "Table=0");
        return s;
    }

    // Лунки через PocketNominationButtons
    uintptr_t pkBeg = SafeRead<uintptr_t>(gm + 0x720);
    uintptr_t pkEnd = SafeRead<uintptr_t>(gm + 0x728);
    if (IsPtr(pkBeg) && IsPtr(pkEnd) && pkEnd >= pkBeg) {
        uintptr_t diff = pkEnd - pkBeg;
        if (diff > 0 && diff <= 6 * 8) {
            int cnt = (int)(diff / sizeof(uintptr_t));
            for (int i = 0; i < cnt && i < 6; i++) {
                uintptr_t btn = SafeRead<uintptr_t>(pkBeg + (uintptr_t)i * 8);
                if (!IsPtr(btn)) continue;
                float px = SafeRead<float>(btn + 0x08);
                float py = SafeRead<float>(btn + 0x0C);
                if (px == 0.f && py == 0.f) continue;
                if (fabsf(px) > 5000.f || fabsf(py) > 5000.f) continue;
                s.pockets[s.pocketCount++] = { px, py, i };
            }
        }
    }

    // Fallback: mTableShape
    if (s.pocketCount == 0) {
        uintptr_t shBeg = SafeRead<uintptr_t>(tbl + 0x478);
        uintptr_t shEnd = SafeRead<uintptr_t>(tbl + 0x480);
        if (IsPtr(shBeg) && IsPtr(shEnd) && shEnd > shBeg) {
            uintptr_t diff = shEnd - shBeg;
            ptrdiff_t pts = (ptrdiff_t)(diff / 8);
            if (pts >= 6 && pts <= 10000) {
                int step = (int)(pts / 6);
                for (int i = 0; i < 6; i++) {
                    uintptr_t pt = shBeg + (uintptr_t)(i * step * 8);
                    float px = SafeRead<float>(pt);
                    float py = SafeRead<float>(pt + 4);
                    if (fabsf(px) > 5000.f || fabsf(py) > 5000.f) continue;
                    s.pockets[s.pocketCount++] = { px, py, i };
                }
            }
        }
    }

    // Шары
    uintptr_t bbeg = SafeRead<uintptr_t>(tbl + 0x468);
    uintptr_t bend = SafeRead<uintptr_t>(tbl + 0x470);
    if (IsPtr(bbeg) && IsPtr(bend) && bend >= bbeg) {
        uintptr_t diff = bend - bbeg;
        if (diff <= 16 * 8) {
            int cnt = (int)(diff / 8);
            s.totalBalls = cnt;
            for (int i = 0; i < cnt; i++) {
                uintptr_t ball = SafeRead<uintptr_t>(bbeg + (uintptr_t)i * 8);
                if (!IsPtr(ball)) continue;
                int st = SafeRead<int>(ball + 0xA4);
                if (st == 1) s.pocketedBalls++; else s.activeBalls++;
            }
        }
    }

    // Кий
    uintptr_t vc = SafeRead<uintptr_t>(gm + 0x4D0);
    if (IsPtr(vc)) {
        s.cueX = SafeRead<float>(vc + 0x18);
        s.cueY = SafeRead<float>(vc + 0x1C);
    }

    // Ближайшая лунка
    for (int i = 0; i < s.pocketCount; i++) {
        float dx = s.pockets[i].x - s.cueX;
        float dy = s.pockets[i].y - s.cueY;
        float d  = sqrtf(dx*dx + dy*dy);
        if (d < s.nearestDist) { s.nearestDist = d; s.nearestIdx = i; }
    }

    s.valid = true;
    return s;
}

// ============================================================
//  FONT — грузим Arial с кириллицей, только если файл есть
// ============================================================

static void LoadFont(float sz)
{
    ImGuiIO &io = ImGui::GetIO();

    const char *paths[] = {
        "/System/Library/Fonts/Cache/ArialMT.ttf",
        "/System/Library/Fonts/ArialMT.ttf",
        "/System/Library/Fonts/Core/ArialMT.ttf",
        nullptr
    };

    static ImVector<ImWchar> ranges;
    if (ranges.empty()) {
        ImFontGlyphRangesBuilder b;
        b.AddRanges(io.Fonts->GetGlyphRangesDefault());
        b.AddRanges(io.Fonts->GetGlyphRangesCyrillic());
        b.BuildRanges(&ranges);
    }

    for (int i = 0; paths[i]; i++) {
        FILE *f = fopen(paths[i], "rb");
        if (!f) continue;
        fclose(f);
        if (io.Fonts->AddFontFromFileTTF(paths[i], sz, nullptr, ranges.Data))
            return;
    }
    // fallback — ASCII
    io.Fonts->AddFontDefault();
}

// ============================================================
//  MENU
// ============================================================

static bool g_showPockets = false;
static bool g_demoWindow  = false;

static void DrawMenu()
{
    ImGui::SetNextWindowSize(ImVec2(340, 400), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos (ImVec2(40,  60),  ImGuiCond_FirstUseEver);
    ImGui::Begin("crown.pw");

    ImGui::SliderFloat("UI scale", &ImGui::GetIO().FontGlobalScale, 0.6f, 2.5f);
    ImGui::Separator();

    ImGui::Checkbox("Lunki / Shary", &g_showPockets);

    if (g_showPockets) {
        ImGui::Spacing();
        ImGui::PushStyleColor(ImGuiCol_ChildBg, ImVec4(0.08f,0.08f,0.13f,0.95f));
        ImGui::BeginChild("##pk", ImVec2(0,0), true);

        GameState gs = ReadGameState();

        if (!gs.valid) {
            ImGui::TextColored(ImVec4(1,0.35f,0.35f,1), "Igra ne aktivna");
            ImGui::Text("err: %s", gs.err);
            ImGui::Separator();
            ImGui::Text("slide   0x%llX", (unsigned long long)gs.dbgSlide);
            ImGui::Text("image:  %s", g_imageName[0] ? g_imageName : "not found");
            ImGui::Text("autoAim 0x%llX", (unsigned long long)gs.dbgAA);
            ImGui::Text("ptrAddr 0x%llX", (unsigned long long)(gs.dbgSlide + kAutoAimStatic));
            ImGui::Text("gameMgr 0x%llX", (unsigned long long)gs.dbgGM);
            ImGui::Text("table   0x%llX", (unsigned long long)gs.dbgTbl);
            ImGui::Separator();
            // Список всех образов — чтобы найти правильное имя
            ImGui::TextColored(ImVec4(0.8f,0.8f,0.3f,1), "All images (non-system):");
            uint32_t cnt = _dyld_image_count();
            for (uint32_t i = 0; i < cnt; i++) {
                const char *n = _dyld_get_image_name(i);
                if (!n) continue;
                // Пропускаем системные библиотеки
                if (strncmp(n, "/usr/lib",  8) == 0) continue;
                if (strncmp(n, "/System",   7) == 0) continue;
                if (strncmp(n, "/private/prebuilt", 17) == 0) continue;
                uintptr_t sl = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
                const char *short_n = strrchr(n, '/') ? strrchr(n,'/')+1 : n;
                ImGui::Text("[%u] 0x%llX  %s", i, (unsigned long long)sl, short_n);
            }
        } else {
            ImGui::TextColored(ImVec4(0.4f,1,0.4f,1), "Lunok: %d", gs.pocketCount);

            if (gs.nearestIdx >= 0) {
                ImGui::TextColored(ImVec4(1,1,0.3f,1),
                    "Blizhayshaya #%d  dist=%.1f",
                    gs.nearestIdx, gs.nearestDist);
                ImGui::Text("  X=%.2f  Y=%.2f",
                    gs.pockets[gs.nearestIdx].x,
                    gs.pockets[gs.nearestIdx].y);
            } else {
                ImGui::TextColored(ImVec4(0.6f,0.6f,0.6f,1), "Luzy: net dannykh");
            }

            ImGui::Separator();
            for (int i = 0; i < gs.pocketCount; i++) {
                bool near = (i == gs.nearestIdx);
                if (near) ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1,1,0.3f,1));
                ImGui::Text("[%d] X=%.2f Y=%.2f%s",
                    i, gs.pockets[i].x, gs.pockets[i].y, near ? " <--" : "");
                if (near) ImGui::PopStyleColor();
            }
            if (gs.pocketCount == 0)
                ImGui::TextColored(ImVec4(1,0.55f,0,1), "PocketButtons pust");

            ImGui::Separator();
            ImGui::Text("Shary: vsego=%d active=%d zabito=%d",
                gs.totalBalls, gs.activeBalls, gs.pocketedBalls);
            ImGui::Text("Kiy: X=%.2f Y=%.2f", gs.cueX, gs.cueY);

            ImGui::Separator();
            ImGui::TextColored(ImVec4(0.45f,0.45f,0.45f,1), "[dbg]");
            ImGui::Text("slide 0x%llX", (unsigned long long)gs.dbgSlide);
        }

        ImGui::EndChild();
        ImGui::PopStyleColor();
    }

    ImGui::Separator();
    ImGui::Checkbox("Demo", &g_demoWindow);
    ImGui::Text("%.1f FPS", ImGui::GetIO().Framerate);
    ImGui::End();

    if (g_demoWindow) ImGui::ShowDemoWindow(&g_demoWindow);
}

// ============================================================
//  OVERLAY VIEW
// ============================================================

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

    self.backgroundColor  = UIColor.clearColor;
    self.opaque           = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.multipleTouchEnabled = YES;

    _device = MTLCreateSystemDefaultDevice();
    if (!_device) return nil;
    _queue = [_device newCommandQueue];

    _mtk = [[MTKView alloc] initWithFrame:self.bounds device:_device];
    _mtk.delegate                 = self;
    _mtk.autoresizingMask         = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    _mtk.colorPixelFormat         = MTLPixelFormatBGRA8Unorm;
    _mtk.clearColor               = MTLClearColorMake(0,0,0,0);
    _mtk.backgroundColor          = UIColor.clearColor;
    _mtk.opaque                   = NO;
    _mtk.layer.opaque             = NO;
    _mtk.userInteractionEnabled   = NO;
    _mtk.preferredFramesPerSecond = 60;
    _mtk.paused                   = YES;
    _mtk.hidden                   = YES;
    [self addSubview:_mtk];

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = nullptr;
    io.ConfigFlags |= ImGuiConfigFlags_NoMouseCursorChange;
    ImGui::StyleColorsDark();
    ImGui::GetStyle().ScaleAllSizes(1.2f);
    LoadFont(18.0f);
    io.FontGlobalScale = 1.2f;

    ImGui_ImplMetal_Init(_device);
    return self;
}

- (void)toggleMenu
{
    self.menuOpen   = !self.menuOpen;
    _mtk.hidden     = !self.menuOpen;
    _mtk.paused     = !self.menuOpen;
}

- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)event
{
    if (!self.menuOpen) return nil;
    ImGuiContext *ctx = ImGui::GetCurrentContext();
    if (!ctx) return nil;
    for (ImGuiWindow *w : ctx->Windows)
        if (w->Active && !w->Hidden &&
            !(w->Flags & ImGuiWindowFlags_NoInputs) &&
            w->Rect().Contains(ImVec2((float)p.x,(float)p.y)))
            return self;
    return nil;
}

- (void)feed:(NSSet<UITouch*>*)touches down:(BOOL)down
{
    UITouch *t = touches.anyObject;
    if (!t) return;
    CGPoint p = [t locationInView:self];
    ImGuiIO &io = ImGui::GetIO();
    io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);
    io.AddMousePosEvent((float)p.x,(float)p.y);
    io.AddMouseButtonEvent(0, down);
}
-(void)touchesBegan:(NSSet*)t withEvent:(UIEvent*)e     { [self feed:t down:YES]; }
-(void)touchesMoved:(NSSet*)t withEvent:(UIEvent*)e     { [self feed:t down:YES]; }
-(void)touchesEnded:(NSSet*)t withEvent:(UIEvent*)e     { [self feed:t down:NO];  }
-(void)touchesCancelled:(NSSet*)t withEvent:(UIEvent*)e { [self feed:t down:NO];  }

-(void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)s {}

-(void)drawInMTKView:(MTKView*)view
{
    CGSize b = view.bounds.size;
    CGSize d = view.drawableSize;
    if (b.width <= 0 || b.height <= 0) return;

    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize             = ImVec2((float)b.width,(float)b.height);
    io.DisplayFramebufferScale = ImVec2((float)(d.width/b.width),(float)(d.height/b.height));

    static CFTimeInterval last = 0;
    CFTimeInterval now = CACurrentMediaTime();
    io.DeltaTime = (last > 0) ? (float)(now-last) : 1.f/60.f;
    if (io.DeltaTime <= 0) io.DeltaTime = 1.f/60.f;
    last = now;

    id<MTLCommandBuffer> cb = [self.queue commandBuffer];
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

// ============================================================
//  INSTALL
// ============================================================

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
    if (g_overlay) return; // уже установлен

    g_overlay = [[OverlayView alloc] initWithFrame:w.bounds];
    if (!g_overlay) return;
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
