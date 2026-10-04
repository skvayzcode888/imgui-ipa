// Минимальная база: Dear ImGui (Metal) оверлей поверх игры.
// Открыть/закрыть меню: двойной тап тремя пальцами.
 
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
 
#include "imgui.h"
#include "imgui_internal.h"
#include "imgui_impl_metal.h"
 
// ------------------------------------------------------------------
// ТУТ РИСУЕТСЯ ВАШЕ МЕНЮ
// ------------------------------------------------------------------
static bool g_demoWindow = false;
static bool g_featureA   = false;
static float g_value     = 1.0f;
 
static void DrawMenu()
{
    ImGui::SetNextWindowSize(ImVec2(300, 220), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos(ImVec2(40, 60), ImGuiCond_FirstUseEver);
    ImGui::Begin("crown.pw");
 
    ImGui::Text("Hello from ImGui %s", ImGui::GetVersion());
    ImGui::SliderFloat("UI scale", &ImGui::GetIO().FontGlobalScale, 0.6f, 2.5f);
    ImGui::Separator();
    ImGui::Checkbox("Feature A", &g_featureA);
    ImGui::SliderFloat("Value", &g_value, 0.0f, 10.0f);
    if (ImGui::Button("Button")) {
        // TODO: ваше действие
    }
    ImGui::Checkbox("Demo window", &g_demoWindow);
    ImGui::Text("%.1f FPS", ImGui::GetIO().Framerate);
 
    ImGui::End();
 
    if (g_demoWindow) ImGui::ShowDemoWindow(&g_demoWindow);
}
 
// ------------------------------------------------------------------
// Оверлей
// ------------------------------------------------------------------
@interface OverlayView : UIView <MTKViewDelegate>
@property (nonatomic, strong) MTKView *mtk;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> queue;
@property (nonatomic) BOOL menuOpen;
- (void)toggleMenu;
@end
 
@implementation OverlayView
 
- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (!self) return nil;
 
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.multipleTouchEnabled = NO;
 
    _device = MTLCreateSystemDefaultDevice();
    _queue  = [_device newCommandQueue];
 
    _mtk = [[MTKView alloc] initWithFrame:self.bounds device:_device];
    _mtk.delegate = self;
    _mtk.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _mtk.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    _mtk.clearColor = MTLClearColorMake(0, 0, 0, 0);
    _mtk.backgroundColor = UIColor.clearColor;
    _mtk.opaque = NO;
    _mtk.layer.opaque = NO;
    _mtk.userInteractionEnabled = NO;   // тачи принимаем в самом OverlayView
    _mtk.preferredFramesPerSecond = 60;
    _mtk.paused = YES;                  // пока меню закрыто - не рисуем
    _mtk.hidden = YES;
    [self addSubview:_mtk];
 
    // --- ImGui ---
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = nullptr;           // не писать imgui.ini
    io.ConfigFlags |= ImGuiConfigFlags_NoMouseCursorChange;
    ImGui::StyleColorsDark();
    ImGui::GetStyle().ScaleAllSizes(1.2f);  // размер отступов/виджетов
    io.FontGlobalScale = 1.2f;              // размер шрифта (меняется слайдером в меню)
 
    ImGui_ImplMetal_Init(_device);
    return self;
}
 
- (void)toggleMenu
{
    self.menuOpen = !self.menuOpen;
    self.mtk.hidden = !self.menuOpen;
    self.mtk.paused = !self.menuOpen;
}
 
// Перехватываем тач только если он попал в окно ImGui, иначе - отдаём игре.
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)event
{
    if (!self.menuOpen) return nil;
    ImGuiContext *g = ImGui::GetCurrentContext();
    if (!g) return nil;
    for (ImGuiWindow *w : g->Windows) {
        if (w->Active && !w->Hidden && (w->Flags & ImGuiWindowFlags_NoInputs) == 0 &&
            w->Rect().Contains(ImVec2((float)p.x, (float)p.y)))
            return self;
    }
    return nil;
}
 
// --- Ввод: тач -> мышь ImGui ---
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
- (void)touchesBegan:(NSSet *)t withEvent:(UIEvent *)e     { [self feed:t down:YES]; }
- (void)touchesMoved:(NSSet *)t withEvent:(UIEvent *)e     { [self feed:t down:YES]; }
- (void)touchesEnded:(NSSet *)t withEvent:(UIEvent *)e     { [self feed:t down:NO];  }
- (void)touchesCancelled:(NSSet *)t withEvent:(UIEvent *)e { [self feed:t down:NO];  }
 
// --- Рендер ---
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}
 
- (void)drawInMTKView:(MTKView *)view
{
    CGSize b = view.bounds.size;
    CGSize d = view.drawableSize;
    if (b.width <= 0 || b.height <= 0) return;
 
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2((float)b.width, (float)b.height);
    io.DisplayFramebufferScale = ImVec2((float)(d.width / b.width), (float)(d.height / b.height));
 
    static CFTimeInterval last = 0;
    CFTimeInterval now = CACurrentMediaTime();
    io.DeltaTime = last > 0 ? (float)(now - last) : (1.0f / 60.0f);
    if (io.DeltaTime <= 0) io.DeltaTime = 1.0f / 60.0f;
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
 
// ------------------------------------------------------------------
// Установка в игру
// ------------------------------------------------------------------
static UIWindow *FindKeyWindow()
{
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        if (ws.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ws.windows)
            if (w.isKeyWindow) return w;
    }
    // запасной вариант для игр без сцен
    return UIApplication.sharedApplication.windows.firstObject;
}
 
static OverlayView *g_overlay = nil;
 
static void TryInstall(int attempt)
{
    UIWindow *w = FindKeyWindow();
    if (!w || !w.rootViewController.view) {
        if (attempt < 60) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{ TryInstall(attempt + 1); });
        }
        return;
    }
 
    g_overlay = [[OverlayView alloc] initWithFrame:w.bounds];
    [w addSubview:g_overlay];
 
    // 3 пальца, 2 тапа - открыть/закрыть меню
    UITapGestureRecognizer *g = [[UITapGestureRecognizer alloc] initWithTarget:g_overlay
                                                                        action:@selector(toggleMenu)];
    g.numberOfTapsRequired = 2;
    g.numberOfTouchesRequired = 3;
    g.cancelsTouchesInView = NO;
    g.delaysTouchesBegan = NO;
    g.delaysTouchesEnded = NO;
    [w addGestureRecognizer:g];
}
 
__attribute__((constructor))
static void Entry()
{
    dispatch_async(dispatch_get_main_queue(), ^{ TryInstall(0); });
}
