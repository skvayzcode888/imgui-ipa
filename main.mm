// Dear ImGui (Metal) overlay — 8 Ball Pool mod
// Open/close: 3-finger double-tap

#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

#include "imgui.h"
#include "imgui_internal.h"
#include "imgui_impl_metal.h"

#import <mach-o/dyld.h>

#include <stdint.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

// ============================================================
//  Проверено по дизасму poolLIB.dylib (game_loop_main_logic):
//
//  [GameManager sharedGameManager] -> gm        (ObjC)
//  [gm table]                      -> table      (ObjC)
//  [table tableProperties]         -> tp         (ObjC)
//  [tp getPockets]   -> C++ vector*: ptr[0]=begin, ptr[1]=end, ptr[2]=capacity
//                       элемент = 16 байт (double x, double y)
//  [tp getPocketRadius]            -> double      (sret через x8)
//  [table balls]                   -> NSArray     (ObjC)
//  [ball position]                 -> CGPoint     (sret через x8)
//
// ============================================================
//  Флаги фич из poolLIB.dylib (подтверждено saveSettings):
//
//  0x15878D  ShowTrajectory   — Enable Trajectory Overlay
//  0x158808  ShowPrediction   — Cue Guideline
//  0x15880A  ProjectedBalls   — Collision Trajectories
//  0x15880B  ProjLines        — Projection Lines
//  0x158810  AutoGame         — Shot Assist (авто-прицел)
// ============================================================

// База poolLIB.dylib в памяти — ищем по имени
static uintptr_t g_poolLibBase = 0;

static uintptr_t GetPoolLibBase()
{
    if (g_poolLibBase) return g_poolLibBase;
    uint32_t cnt = _dyld_image_count();
    for (uint32_t i = 0; i < cnt; i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path) continue;
        const char *fname = strrchr(path, '/');
        fname = fname ? fname + 1 : path;
        if (strcmp(fname, "poolLIB.dylib") == 0) {
            g_poolLibBase = (uintptr_t)_dyld_get_image_header(i);
            return g_poolLibBase;
        }
    }
    return 0;
}

// Читаем/пишем bool флаг в poolLIB по file offset
static bool GetFlag(uintptr_t offset)
{
    uintptr_t base = GetPoolLibBase();
    if (!base) return false;
    return *(volatile bool *)(base + offset);
}

static void SetFlag(uintptr_t offset, bool val)
{
    uintptr_t base = GetPoolLibBase();
    if (!base) return;
    *(volatile bool *)(base + offset) = val;
}

// Офсеты флагов (из saveSettings poolLIB.dylib, imagebase=0)
#define FLAG_TRAJECTORY  0x15878DUL   // ShowTrajectory
#define FLAG_CUE_GUIDE   0x158808UL   // ShowPrediction (Cue Guideline)
#define FLAG_COLLISION   0x15880AUL   // ProjectedBalls (Collision Trajectories)
#define FLAG_PROJ_LINES  0x15880BUL   // ProjLines (Projection Lines)
#define FLAG_AUTOGAME    0x158810UL   // AutoGame (Shot Assist)
//  ball.number                     -> int ivar    (class_getInstanceVariable)
//  забитый шар: isfinite(pos.x)==false
// ============================================================

// SafeCall — обычный, без __unsafe_unretained
static id SafeCall(id obj, const char *sel_name)
{
    if (!obj) return nil;
    SEL s = sel_registerName(sel_name);
    if (![obj respondsToSelector:s]) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(obj, s);
}

static double SafeCallDouble(id obj, const char *sel_name)
{
    if (!obj) return 0.0;
    SEL s = sel_registerName(sel_name);
    if (![obj respondsToSelector:s]) return 0.0;
    return ((double(*)(id,SEL))objc_msgSend)(obj, s);
}

// position и getPocketRadius возвращают C++ типы через sret (x8).
// Структура > 16 байт => компилятор выставит x8 автоматически.
struct SretBuf { double v[8]; }; // 64 байта, x8 гарантированно выставляется

static double GetPocketRadius(id tp)
{
    SEL s = sel_registerName("getPocketRadius");
    if (!tp || ![tp respondsToSelector:s]) return 0.3;
    SretBuf r = ((SretBuf(*)(id,SEL))objc_msgSend)(tp, s);
    return r.v[0];
}

static CGPoint GetBallPosition(id ball)
{
    SEL s = sel_registerName("position");
    if (!ball || ![ball respondsToSelector:s]) return CGPointMake(NAN, NAN);
    SretBuf r = ((SretBuf(*)(id,SEL))objc_msgSend)(ball, s);
    // CGPoint = double x, double y — первые 16 байт
    return CGPointMake(r.v[0], r.v[1]);
}

// number через ivar — подтверждено дизасмом 0x17db8
static int BallNumber(id ball)
{
    if (!ball) return -1;
    Class cls = object_getClass(ball);
    if (!cls) return -1;
    Ivar iv = class_getInstanceVariable(cls, "number");
    if (!iv) return -1;
    ptrdiff_t off = ivar_getOffset(iv);
    if (off < 0) return -1;
    return *(int *)((uint8_t *)(__bridge void *)ball + off);
}

// getPockets возвращает C++ vector (НЕ ObjC объект).
// Дизасм 0x20810: X0 = msgSend result, LDR X9,[X0] = begin, LDR X10,[X0,#8] = end
// typedef чтобы ARC не делал retain/release
typedef uintptr_t *(*RawPtrFn)(id, SEL);

static int ReadPockets(id tp, double *outX, double *outY, int maxN)
{
    if (!tp) return 0;

    const char *names[] = { "getPockets", "getPocketAimPoints", nullptr };
    for (int ni = 0; names[ni]; ni++) {
        SEL s = sel_registerName(names[ni]);
        if (![tp respondsToSelector:s]) continue;

        // Вызов без ARC retain/release
        uintptr_t *vec = ((RawPtrFn)objc_msgSend)(tp, s);
        if (!vec) continue;

        // Проверяем валидность указателей begin/end перед чтением
        uintptr_t begin = vec[0];
        uintptr_t end   = vec[1];

        // begin и end должны быть в разумном диапазоне userspace arm64
        if (begin < 0x100000000ULL || end < 0x100000000ULL) continue;
        if (end <= begin) continue;

        uintptr_t diff = end - begin;
        // 1..6 лунок * 16 байт
        if (diff < 16 || diff > 96) continue;

        int cnt = (int)(diff / 16);
        if (cnt > maxN) cnt = maxN;

        for (int i = 0; i < cnt; i++) {
            double *p = (double *)(begin + (uintptr_t)i * 16);
            outX[i] = p[0];
            outY[i] = p[1];
        }
        return cnt;
    }
    return 0;
}

static id GetGameManager()
{
    Class cls = objc_getClass("GameManager");
    if (!cls) return nil;
    SEL s = sel_registerName("sharedGameManager");
    if (![cls respondsToSelector:s]) return nil;
    return ((id(*)(id,SEL))objc_msgSend)((id)cls, s);
}

// ============================================================
//  Game state
// ============================================================

struct PocketInfo { float x, y; int idx; };

struct GameState {
    bool       valid;
    char       err[128];
    int        pocketCount;
    PocketInfo pockets[6];
    int        nearestIdx;
    float      nearestDist;
    float      pocketRadius;
    int        totalBalls, activeBalls, pocketedBalls;
    float      cueX, cueY;
};

static GameState ReadGameState()
{
    GameState s = {};
    s.nearestIdx  = -1;
    s.nearestDist = 1e9f;

    @try {
        id gm = GetGameManager();
        if (!gm) { snprintf(s.err, sizeof(s.err), "no GameManager"); return s; }

        id table = SafeCall(gm, "table");
        if (!table) { snprintf(s.err, sizeof(s.err), "table=nil"); return s; }

        id tp = SafeCall(table, "tableProperties");
        if (!tp) { snprintf(s.err, sizeof(s.err), "tableProperties=nil"); return s; }

        // Лунки
        double px[6] = {}, py[6] = {};
        int cnt = ReadPockets(tp, px, py, 6);
        s.pocketCount = cnt;
        for (int i = 0; i < cnt; i++)
            s.pockets[i] = { (float)px[i], (float)py[i], i };

        // Радиус — возвращается через sret (x8), не через d0
        double r = GetPocketRadius(tp);
        s.pocketRadius = (r > 0.01 && r < 1000.0 && r == r) ? (float)r : 0.3f;

        // Шары
        id ballsArr = SafeCall(table, "balls");
        if (ballsArr &&
            [ballsArr respondsToSelector:@selector(count)] &&
            [ballsArr respondsToSelector:@selector(objectAtIndex:)])
        {
            NSUInteger n = [ballsArr count];
            if (n > 0 && n <= 32) {
                s.totalBalls = (int)n;
                for (NSUInteger i = 0; i < n; i++) {
                    id ball = [ballsArr objectAtIndex:i];
                    if (!ball) continue;

                    SEL posSel = sel_registerName("position");
                    if (![ball respondsToSelector:posSel]) { s.activeBalls++; continue; }

                    // position возвращает через sret (x8) — подтверждено дизасмом MyMenu+0x47DC
                    CGPoint pos = GetBallPosition(ball);

                    if (!isfinite(pos.x) || !isfinite(pos.y)) {
                        s.pocketedBalls++;
                        continue;
                    }
                    s.activeBalls++;

                    if (BallNumber(ball) == 0) {
                        s.cueX = (float)pos.x;
                        s.cueY = (float)pos.y;
                    }
                }
            }
        }

        for (int i = 0; i < s.pocketCount; i++) {
            float dx = s.pockets[i].x - s.cueX;
            float dy = s.pockets[i].y - s.cueY;
            float d  = sqrtf(dx*dx + dy*dy);
            if (d < s.nearestDist) { s.nearestDist = d; s.nearestIdx = i; }
        }

        s.valid = true;

    } @catch (NSException *e) {
        snprintf(s.err, sizeof(s.err), "exc: %s", e.reason.UTF8String ?: "?");
    } @catch (...) {
        snprintf(s.err, sizeof(s.err), "unknown exc");
    }

    return s;
}

// ============================================================
//  Menu
// ============================================================

static bool      g_showPockets = false;
static bool      g_demoWindow  = false;
static GameState g_state       = {};
static bool      g_stateOk     = false;
static void DrawMenu()
{
    ImGui::SetNextWindowSize(ImVec2(340, 420), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos (ImVec2(40,  60),  ImGuiCond_FirstUseEver);
    ImGui::Begin("crown.pw");

    ImGui::SliderFloat("UI scale", &ImGui::GetIO().FontGlobalScale, 0.6f, 2.5f);
    ImGui::Separator();

    // ---- Trajectory ----
    {
        bool traj = GetFlag(FLAG_TRAJECTORY);
        if (ImGui::Checkbox("Enable Trajectory Overlay", &traj))
            SetFlag(FLAG_TRAJECTORY, traj);

        bool guide = GetFlag(FLAG_CUE_GUIDE);
        if (ImGui::Checkbox("Cue Guideline", &guide))
            SetFlag(FLAG_CUE_GUIDE, guide);

        bool coll = GetFlag(FLAG_COLLISION);
        if (ImGui::Checkbox("Collision Trajectory", &coll))
            SetFlag(FLAG_COLLISION, coll);

        bool proj = GetFlag(FLAG_PROJ_LINES);
        if (ImGui::Checkbox("Projection Line", &proj))
            SetFlag(FLAG_PROJ_LINES, proj);

        bool autog = GetFlag(FLAG_AUTOGAME);
        if (ImGui::Checkbox("Shot Assist (AutoGame)", &autog))
            SetFlag(FLAG_AUTOGAME, autog);
    }

    ImGui::Separator();
    ImGui::Checkbox("Lunki / Shary", &g_showPockets);

    if (g_showPockets) {
        ImGui::Spacing();

        // Рисуем ТОЛЬКО из кеша — никаких вызовов игрового кода здесь
        GameState &gs = g_state;
        if (!g_stateOk || !gs.valid) {
            ImGui::TextColored(ImVec4(1,0.3f,0.3f,1), "Not in match");
            if (g_stateOk) ImGui::Text("err: %s", gs.err);
        } else {
            ImGui::TextColored(ImVec4(0.4f,1,0.4f,1),
                "Lunok: %d  r=%.2f", gs.pocketCount, gs.pocketRadius);
            if (gs.nearestIdx >= 0) {
                ImGui::TextColored(ImVec4(1,1,0.3f,1),
                    "Blizh #%d  dist=%.1f", gs.nearestIdx, gs.nearestDist);
                ImGui::Text("  X=%.2f  Y=%.2f",
                    gs.pockets[gs.nearestIdx].x, gs.pockets[gs.nearestIdx].y);
            }
            ImGui::Separator();
            for (int i = 0; i < gs.pocketCount; i++) {
                bool near = (i == gs.nearestIdx);
                if (near) ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1,1,0.3f,1));
                ImGui::Text("[%d] X=%.1f  Y=%.1f%s",
                    i, gs.pockets[i].x, gs.pockets[i].y, near ? " <--" : "");
                if (near) ImGui::PopStyleColor();
            }
            ImGui::Separator();
            ImGui::Text("Shary: %d  active=%d  zabito=%d",
                gs.totalBalls, gs.activeBalls, gs.pocketedBalls);
            ImGui::Text("Kiy:  X=%.1f  Y=%.1f", gs.cueX, gs.cueY);
        }
    }

    ImGui::Separator();
    ImGui::Checkbox("Demo", &g_demoWindow);
    ImGui::Text("%.1f FPS", ImGui::GetIO().Framerate);
    ImGui::End();

    if (g_demoWindow) ImGui::ShowDemoWindow(&g_demoWindow);
}

// ============================================================
//  Overlay
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
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.multipleTouchEnabled = YES;

    _device = MTLCreateSystemDefaultDevice();
    if (!_device) return nil;
    _queue = [_device newCommandQueue];

    _mtk = [[MTKView alloc] initWithFrame:self.bounds device:_device];
    _mtk.delegate                 = self;
    _mtk.autoresizingMask         = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _mtk.colorPixelFormat         = MTLPixelFormatBGRA8Unorm;
    _mtk.clearColor               = MTLClearColorMake(0, 0, 0, 0);
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
    io.Fonts->AddFontDefault();
    io.FontGlobalScale = 1.5f;

    ImGui_ImplMetal_Init(_device);
    return self;
}

- (void)toggleMenu
{
    self.menuOpen = !self.menuOpen;
    _mtk.hidden   = !self.menuOpen;
    _mtk.paused   = !self.menuOpen;
    if (self.menuOpen) {
        // Первое обновление сразу
        g_state   = ReadGameState();
        g_stateOk = true;
        // Периодическое обновление пока меню открыто
        [self scheduleStateUpdate];
    }
}

- (void)scheduleStateUpdate
{
    if (!self.menuOpen) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (self.menuOpen) {
            g_state   = ReadGameState();
            g_stateOk = true;
            [self scheduleStateUpdate];
        }
    });
}

- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)event
{
    if (!self.menuOpen) return nil;
    ImGuiContext *ctx = ImGui::GetCurrentContext();
    if (!ctx) return nil;
    for (ImGuiWindow *w : ctx->Windows)
        if (w->Active && !w->Hidden &&
            !(w->Flags & ImGuiWindowFlags_NoInputs) &&
            w->Rect().Contains(ImVec2((float)p.x, (float)p.y)))
            return self;
    return nil;
}

- (void)feed:(NSSet<UITouch *> *)touches down:(BOOL)down
{
    UITouch *t = touches.anyObject;
    if (!t) return;
    CGPoint p = [t locationInView:self];
    ImGuiIO &io = ImGui::GetIO();
    io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);
    io.AddMousePosEvent((float)p.x, (float)p.y);
    io.AddMouseButtonEvent(0, down);
}
- (void)touchesBegan:(NSSet *)t withEvent:(UIEvent *)e      { [self feed:t down:YES]; }
- (void)touchesMoved:(NSSet *)t withEvent:(UIEvent *)e      { [self feed:t down:YES]; }
- (void)touchesEnded:(NSSet *)t withEvent:(UIEvent *)e      { [self feed:t down:NO];  }
- (void)touchesCancelled:(NSSet *)t withEvent:(UIEvent *)e  { [self feed:t down:NO];  }
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)s {}

- (void)drawInMTKView:(MTKView *)view
{
    CGSize b = view.bounds.size;
    CGSize d = view.drawableSize;
    if (b.width <= 0 || b.height <= 0) return;

    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize             = ImVec2((float)b.width, (float)b.height);
    io.DisplayFramebufferScale = ImVec2((float)(d.width / b.width), (float)(d.height / b.height));

    static CFTimeInterval last = 0;
    CFTimeInterval now = CACurrentMediaTime();
    io.DeltaTime = (last > 0) ? (float)(now - last) : 1.f / 60.f;
    if (io.DeltaTime <= 0) io.DeltaTime = 1.f / 60.f;
    last = now;

    id<MTLCommandBuffer>     cb  = [self.queue commandBuffer];
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
//  Install
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
                           dispatch_get_main_queue(), ^{ TryInstall(attempt + 1); });
        return;
    }
    if (g_overlay) return;

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
