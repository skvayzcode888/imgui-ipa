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

#include <stdint.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

// ============================================================
//  GameManager через ObjC runtime (реверс рабочего мода poolLIB.dylib)
//
//  Методы GameManager:
//    +sharedGameManager   -> id  (синглтон)
//    -getPockets          -> NSArray<NSValue*> (CGPoint каждой лунки)
//    -getPocketAimPoints  -> NSArray<NSValue*> (CGPoint точек прицеливания)
//    -getPocketRadius     -> double
//    -visualCue           -> id (объект кия)
// ============================================================

// Безопасный вызов ObjC метода — возвращает nil если класс/метод не существует
static id SafeMsgSend(id obj, const char *selName)
{
    if (!obj) return nil;
    SEL sel = sel_registerName(selName);
    if (![obj respondsToSelector:sel]) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(obj, sel);
}

static double SafeMsgSendDouble(id obj, const char *selName)
{
    if (!obj) return 0.0;
    SEL sel = sel_registerName(selName);
    if (![obj respondsToSelector:sel]) return 0.0;
    return ((double(*)(id,SEL))objc_msgSend)(obj, sel);
}

static id GetGameManager()
{
    Class cls = objc_getClass("GameManager");
    if (!cls) return nil;
    if (![cls respondsToSelector:sel_registerName("sharedGameManager")]) return nil;
    return ((id(*)(id,SEL))objc_msgSend)((id)cls, sel_registerName("sharedGameManager"));
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
    float pocketRadius;
    int   totalBalls, activeBalls, pocketedBalls;
    float cueX, cueY;
};

static GameState ReadGameState()
{
    GameState s = {};
    s.nearestIdx  = -1;
    s.nearestDist = 1e9f;

    @try {
        id gm = GetGameManager();
        if (!gm) {
            snprintf(s.err, sizeof(s.err), "GameManager not found");
            return s;
        }

        // Лунки
        NSArray *pockets = (NSArray *)SafeMsgSend(gm, "getPockets");
        if (!pockets || pockets.count == 0) {
            // fallback — точки прицеливания
            pockets = (NSArray *)SafeMsgSend(gm, "getPocketAimPoints");
        }

        if (pockets && pockets.count > 0) {
            int cnt = (int)MIN(pockets.count, 6);
            s.pocketCount = cnt;
            for (int i = 0; i < cnt; i++) {
                id val = pockets[i];
                CGPoint pt = CGPointZero;
                @try {
                    // NSValue содержащий CGPoint
                    if ([val isKindOfClass:[NSValue class]])
                        pt = [(NSValue *)val CGPointValue];
                } @catch (...) {}
                s.pockets[i] = { (float)pt.x, (float)pt.y, i };
            }
        } else {
            snprintf(s.err, sizeof(s.err), "getPockets returned nil/empty");
        }

        // Радиус лунки
        s.pocketRadius = (float)SafeMsgSendDouble(gm, "getPocketRadius");
        if (s.pocketRadius < 0.1f) s.pocketRadius = 0.3f; // дефолт

        // Шары — ищем метод getBalls/balls
        NSArray *balls = (NSArray *)SafeMsgSend(gm, "getBalls");
        if (!balls) balls = (NSArray *)SafeMsgSend(gm, "balls");
        if (balls) {
            s.totalBalls = (int)balls.count;
            for (id ball in balls) {
                @try {
                    // метод isPocketed или state
                    BOOL pocketed = NO;
                    if ([ball respondsToSelector:sel_registerName("isPocketed")])
                        pocketed = ((BOOL(*)(id,SEL))objc_msgSend)(ball, sel_registerName("isPocketed"));
                    else if ([ball respondsToSelector:sel_registerName("pocketed")])
                        pocketed = ((BOOL(*)(id,SEL))objc_msgSend)(ball, sel_registerName("pocketed"));
                    if (pocketed) s.pocketedBalls++;
                    else          s.activeBalls++;
                } @catch (...) { s.activeBalls++; }
            }
        }

        // Кий — visualCue
        id cue = SafeMsgSend(gm, "visualCue");
        if (cue) {
            @try {
                // позиция кия
                if ([cue respondsToSelector:sel_registerName("position")]) {
                    id posVal = SafeMsgSend(cue, "position");
                    if (posVal && [posVal isKindOfClass:[NSValue class]]) {
                        CGPoint p = [(NSValue*)posVal CGPointValue];
                        s.cueX = (float)p.x;
                        s.cueY = (float)p.y;
                    }
                }
            } @catch (...) {}
        }

        // Ближайшая лунка к кию
        for (int i = 0; i < s.pocketCount; i++) {
            float dx = s.pockets[i].x - s.cueX;
            float dy = s.pockets[i].y - s.cueY;
            float d  = sqrtf(dx*dx + dy*dy);
            if (d < s.nearestDist) { s.nearestDist = d; s.nearestIdx = i; }
        }

        s.valid = true;

    } @catch (NSException *e) {
        snprintf(s.err, sizeof(s.err), "Exception: %s", e.reason.UTF8String ?: "?");
    } @catch (...) {
        snprintf(s.err, sizeof(s.err), "Unknown exception");
    }

    return s;
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
        ImGui::PushStyleColor(ImGuiCol_ChildBg, ImVec4(0.08f, 0.08f, 0.13f, 0.95f));
        ImGui::BeginChild("##pk", ImVec2(0, 0), true);

        GameState gs = ReadGameState();

        if (!gs.valid) {
            ImGui::TextColored(ImVec4(1, 0.35f, 0.35f, 1), "Igra ne aktivna");
            ImGui::Text("err: %s", gs.err);
        } else {
            ImGui::TextColored(ImVec4(0.4f, 1, 0.4f, 1),
                "Lunok: %d  radius=%.2f", gs.pocketCount, gs.pocketRadius);

            if (gs.nearestIdx >= 0) {
                ImGui::TextColored(ImVec4(1, 1, 0.3f, 1),
                    "Blizhayshaya #%d  dist=%.1f",
                    gs.nearestIdx, gs.nearestDist);
                ImGui::Text("  X=%.2f  Y=%.2f",
                    gs.pockets[gs.nearestIdx].x,
                    gs.pockets[gs.nearestIdx].y);
            } else {
                ImGui::TextColored(ImVec4(0.6f, 0.6f, 0.6f, 1), "Luzy: net dannykh");
            }

            ImGui::Separator();
            for (int i = 0; i < gs.pocketCount; i++) {
                bool near = (i == gs.nearestIdx);
                if (near) ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1, 1, 0.3f, 1));
                ImGui::Text("[%d] X=%.2f Y=%.2f%s",
                    i, gs.pockets[i].x, gs.pockets[i].y, near ? " <--" : "");
                if (near) ImGui::PopStyleColor();
            }
            if (gs.pocketCount == 0)
                ImGui::TextColored(ImVec4(1, 0.55f, 0, 1), "getPockets = nil");

            ImGui::Separator();
            ImGui::Text("Shary: vsego=%d  active=%d  zabito=%d",
                gs.totalBalls, gs.activeBalls, gs.pocketedBalls);
            ImGui::Text("Kiy:   X=%.2f  Y=%.2f", gs.cueX, gs.cueY);
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
