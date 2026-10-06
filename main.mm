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
//  Цепочка:
//    objc_getClass("GameManager") -> Class
//    [Class sharedGameManager]    -> id gm
//    [gm table]                   -> id table (объект стола)
//    [table getPockets]           -> C++ vector-like: ptr[0]=begin, ptr[1]=end
//                                    каждый элемент = 16 байт (double x, double y)
//    [table balls]                -> аналогично, элементы = ball объекты
//    [table getPocketRadius]      -> double
//    [gm visualCue]               -> id cue
// ============================================================

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

// Читаем C++ vector-like структуру: ptr[0]=begin, ptr[1]=end, элемент=16 байт (double x,y)
// Возвращает количество точек, заполняет out[] (макс maxCount)
static int ReadVectorOfPoints(id obj, const char *selName, double *outX, double *outY, int maxCount)
{
    if (!obj) return 0;
    SEL sel = sel_registerName(selName);
    if (![obj respondsToSelector:sel]) return 0;

    // Возвращает указатель на C++ vector-like структуру
    uintptr_t *vec = (uintptr_t *)((uintptr_t(*)(id,SEL))objc_msgSend)(obj, sel);
    if (!vec) return 0;

    @try {
        uintptr_t begin = vec[0];
        uintptr_t end   = vec[1];
        if (!begin || !end || end < begin) return 0;
        uintptr_t diff = end - begin;
        int cnt = (int)(diff / 16);
        if (cnt <= 0 || cnt > 64) return 0;
        cnt = cnt < maxCount ? cnt : maxCount;
        for (int i = 0; i < cnt; i++) {
            @try {
                double *elem = (double *)(begin + (uintptr_t)i * 16);
                double x = elem[0];
                double y = elem[1];
                // Проверяем на NaN/Inf
                if (isnan(x) || isinf(x) || isnan(y) || isinf(y)) continue;
                outX[i] = x;
                outY[i] = y;
            } @catch (...) { return i; }
        }
        return cnt;
    } @catch (...) { return 0; }
}

static id GetGameManager()
{
    Class cls = objc_getClass("GameManager");
    if (!cls) return nil;
    SEL sel = sel_registerName("sharedGameManager");
    if (![cls respondsToSelector:sel]) return nil;
    return ((id(*)(id,SEL))objc_msgSend)((id)cls, sel);
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
        // 1. GameManager синглтон
        id gm = GetGameManager();
        if (!gm) {
            snprintf(s.err, sizeof(s.err), "GameManager class not found");
            return s;
        }

        // 2. Table объект
        id table = SafeMsgSend(gm, "table");
        if (!table) {
            snprintf(s.err, sizeof(s.err), "gm.table = nil (not in match?)");
            return s;
        }

        // 3. tableProperties — именно на нём живут getPockets/getPocketRadius
        id tableProps = SafeMsgSend(table, "tableProperties");
        if (!tableProps) {
            snprintf(s.err, sizeof(s.err), "table.tableProperties = nil");
            return s;
        }

        // Лунки — getPockets на tableProperties
        double pxArr[6], pyArr[6];
        int cnt = ReadVectorOfPoints(tableProps, "getPockets", pxArr, pyArr, 6);
        if (cnt == 0)
            cnt = ReadVectorOfPoints(tableProps, "getPocketAimPoints", pxArr, pyArr, 6);

        s.pocketCount = cnt;
        for (int i = 0; i < cnt; i++)
            s.pockets[i] = { (float)pxArr[i], (float)pyArr[i], i };

        // 4. Радиус лунки — тоже на tableProperties
        s.pocketRadius = (float)SafeMsgSendDouble(tableProps, "getPocketRadius");
        // Защита от NaN/Inf/0
        if (s.pocketRadius != s.pocketRadius || s.pocketRadius < 0.01f || s.pocketRadius > 1000.f)
            s.pocketRadius = 0.3f;

        // 5. Шары — [table balls]
        // balls может быть NSArray или C++ vector — проверяем оба варианта
        id ballsObj = SafeMsgSend(table, "balls");
        if (ballsObj &&
            [ballsObj respondsToSelector:@selector(count)] &&
            [ballsObj respondsToSelector:@selector(objectAtIndex:)]) {
            @try {
                NSUInteger bCount = [ballsObj count];
                if (bCount > 0 && bCount <= 32) {
                    s.totalBalls = (int)bCount;
                    for (NSUInteger i = 0; i < bCount; i++) {
                        @autoreleasepool {
                            id ball = nil;
                            @try { ball = [ballsObj objectAtIndex:i]; } @catch (...) { s.activeBalls++; continue; }
                            if (!ball) { s.activeBalls++; continue; }
                            @try {
                                if (![ball respondsToSelector:sel_registerName("position")]) {
                                    s.activeBalls++;
                                    continue;
                                }
                                CGPoint pos = ((CGPoint(*)(id,SEL))objc_msgSend)(ball, sel_registerName("position"));
                                if (isinf(pos.x) || isinf(pos.y) || isnan(pos.x) || isnan(pos.y)) {
                                    s.pocketedBalls++;
                                } else {
                                    s.activeBalls++;
                                    @try {
                                        if ([ball respondsToSelector:sel_registerName("number")]) {
                                            int num = ((int(*)(id,SEL))objc_msgSend)(ball, sel_registerName("number"));
                                            if (num == 0) { s.cueX = (float)pos.x; s.cueY = (float)pos.y; }
                                        }
                                    } @catch (...) {}
                                }
                            } @catch (...) { s.activeBalls++; }
                        }
                    }
                }
            } @catch (...) {}
        }

        // 7. Ближайшая лунка
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
            ImGui::Text("Kiy (bel shar): X=%.2f  Y=%.2f", gs.cueX, gs.cueY);
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
