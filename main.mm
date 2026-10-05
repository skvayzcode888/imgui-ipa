// Минимальная база: Dear ImGui (Metal) оверлей поверх игры.
// Открыть/закрыть меню: двойной тап тремя пальцами.

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

// ==========================================================================
//  OFFSETS (из IDA Pro — рефлексионная таблица 0xF04700)
// ==========================================================================

// Глобальный указатель на AutoAim-объект (статический синглтон).
// AutoAim+0x78  -> указатель на GameManager
// GameManager+0x400 -> Table*
// Table+0x468   -> mBalls.begin  (std::vector<Ball*>)
// Table+0x470   -> mBalls.end
// Table+0x478   -> mTableShape.begin (std::vector<vec2f>)
// Table+0x480   -> mTableShape.end
// Table+0x490   -> mTightTableShape.begin
// GameManager+0x720 -> mPocketNominationButtons (std::vector<Button*>)
// GameManager+0x728 -> mPocketNominationButtons.end
// Ball+0xA4     -> state  (0=active, 1=pocketed, ...)
// Ball+0xA0     -> classification (0=cue, 1=solid, 2=striped, 3=eight)
// Ball+0xA8     -> number
// Ball+0x20     -> _physicsProperties (ptr к позиции)
// BallPhysics+0x00 -> x (float)
// BallPhysics+0x04 -> y (float)
// Button+0x08   -> world position x (float)
// Button+0x0C   -> world position y (float)

// Смещение ASLR: найдём по имени модуля pool
static uintptr_t g_slide = 0;

static uintptr_t GetSlide() {
    if (g_slide) return g_slide;
    uint32_t cnt = _dyld_image_count();
    for (uint32_t i = 0; i < cnt; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "pool")) {
            g_slide = _dyld_get_image_vmaddr_slide(i);
            return g_slide;
        }
    }
    // fallback: первый образ (сам бинарь)
    g_slide = _dyld_get_image_vmaddr_slide(0);
    return g_slide;
}

// Статический адрес синглтона AutoAim в бинарнике (без ASLR)
// из IDA: dword_104ECB0  (это поле хранит ptr на AutoAim-объект)
static const uintptr_t kAutoAimObjAddr_Static = 0x104ECB0;

// Читаем ptr безопасно
template<typename T>
static T SafeRead(uintptr_t addr) {
    // Простая проверка выравнивания
    if (addr < 0x1000) return T{};
    return *(T *)addr;
}

// Структура лунки для нашего меню
struct PocketInfo {
    float x, y;       // мировые координаты
    int   index;      // номер (0-5)
};

// Результат каждого кадра
struct GameState {
    bool  valid;
    int   pocketCount;
    PocketInfo pockets[6];
    int   nearestIdx;
    float nearestDist;
    // Шары
    int   totalBalls;
    int   pocketedBalls;
    int   activeBalls;
};

static GameState ReadGameState() {
    GameState s = {};
    s.valid = false;

    uintptr_t slide = GetSlide();
    if (!slide) return s;

    // 1. Читаем AutoAim obj ptr
    uintptr_t autoAimPtrAddr = slide + kAutoAimObjAddr_Static;
    uintptr_t autoAimObj = SafeRead<uintptr_t>(autoAimPtrAddr);
    if (!autoAimObj || autoAimObj == (uintptr_t)-1) return s;

    // 2. GameManager ptr находится внутри AutoAim по offset +0x78
    uintptr_t gameMgr = SafeRead<uintptr_t>(autoAimObj + 0x78);
    if (!gameMgr || gameMgr == (uintptr_t)-1) return s;

    // 3. Table ptr из GameManager+0x400
    uintptr_t table = SafeRead<uintptr_t>(gameMgr + 0x400);
    if (!table || table == (uintptr_t)-1) return s;

    // ----- Лунки через mPocketNominationButtons (GameManager+0x720) -----
    // mPocketNominationButtons — std::vector<Button*>
    uintptr_t pktBegin = SafeRead<uintptr_t>(gameMgr + 0x720);
    uintptr_t pktEnd   = SafeRead<uintptr_t>(gameMgr + 0x728);

    if (pktBegin && pktEnd && pktEnd >= pktBegin) {
        ptrdiff_t count = (pktEnd - pktBegin) / sizeof(uintptr_t);
        if (count > 6) count = 6;
        s.pocketCount = (int)count;
        for (int i = 0; i < (int)count; i++) {
            uintptr_t btn = SafeRead<uintptr_t>(pktBegin + i * sizeof(uintptr_t));
            if (!btn) continue;
            // Button.worldPos или screenPos обычно по +0x08/+0x0C
            float px = SafeRead<float>(btn + 0x08);
            float py = SafeRead<float>(btn + 0x0C);
            s.pockets[i] = { px, py, i };
        }
    }

    // Если кнопок нет — пробуем через mTableShape (контур стола)
    // mTableShape: std::vector<vec2f>, Table+0x470 (begin), +0x478 (end)
    if (s.pocketCount == 0) {
        uintptr_t shapeBegin = SafeRead<uintptr_t>(table + 0x470);
        uintptr_t shapeEnd   = SafeRead<uintptr_t>(table + 0x478);
        if (shapeBegin && shapeEnd && shapeEnd > shapeBegin) {
            ptrdiff_t pts = (shapeEnd - shapeBegin) / 8; // vec2f = 8 байт
            // Лунки — через каждые pts/6 точек (6 лунок на стандартном столе)
            int step = (int)(pts / 6);
            if (step > 0 && pts >= 6) {
                s.pocketCount = 6;
                for (int i = 0; i < 6; i++) {
                    uintptr_t pt = shapeBegin + i * step * 8;
                    float px = SafeRead<float>(pt);
                    float py = SafeRead<float>(pt + 4);
                    s.pockets[i] = { px, py, i };
                }
            }
        }
    }

    // ----- Шары через Table.mBalls (Table+0x468) -----
    uintptr_t ballsBegin = SafeRead<uintptr_t>(table + 0x468);
    uintptr_t ballsEnd   = SafeRead<uintptr_t>(table + 0x470);

    if (ballsBegin && ballsEnd && ballsEnd >= ballsBegin) {
        ptrdiff_t ballCount = (ballsEnd - ballsBegin) / sizeof(uintptr_t);
        if (ballCount > 16) ballCount = 16;
        s.totalBalls = (int)ballCount;
        for (int i = 0; i < (int)ballCount; i++) {
            uintptr_t ball = SafeRead<uintptr_t>(ballsBegin + i * sizeof(uintptr_t));
            if (!ball) continue;
            int state = SafeRead<int>(ball + 0xA4);
            if (state == 1) s.pocketedBalls++;
            else            s.activeBalls++;
        }
    }

    // ----- Ближайшая лунка к кию -----
    // Позиция кия: GameManager+0x78 -> VisualCue, offset +0x18/+0x1C (x/y из sub_1F1720)
    uintptr_t visualCue = SafeRead<uintptr_t>(gameMgr + 0x4D0);
    float cueX = 0, cueY = 0;
    if (visualCue && visualCue != (uintptr_t)-1) {
        cueX = SafeRead<float>(visualCue + 0x18);
        cueY = SafeRead<float>(visualCue + 0x1C);
    }

    s.nearestIdx  = -1;
    s.nearestDist = 1e9f;
    for (int i = 0; i < s.pocketCount; i++) {
        float dx = s.pockets[i].x - cueX;
        float dy = s.pockets[i].y - cueY;
        float d  = sqrtf(dx*dx + dy*dy);
        if (d < s.nearestDist) {
            s.nearestDist = d;
            s.nearestIdx  = i;
        }
    }

    s.valid = true;
    return s;
}

// ==========================================================================
//  МЕНЮ
// ==========================================================================
static bool  g_showPockets   = false;
static bool  g_demoWindow    = false;

static void DrawMenu()
{
    ImGui::SetNextWindowSize(ImVec2(320, 340), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos(ImVec2(40, 60),  ImGuiCond_FirstUseEver);
    ImGui::Begin("crown.pw");

    ImGui::SliderFloat("UI scale", &ImGui::GetIO().FontGlobalScale, 0.6f, 2.5f);
    ImGui::Separator();

    // --- Чекбокс лунок ---
    ImGui::Checkbox("Показать инфо о лунках", &g_showPockets);

    if (g_showPockets) {
        ImGui::Spacing();
        ImGui::PushStyleColor(ImGuiCol_ChildBg, ImVec4(0.1f, 0.1f, 0.15f, 0.9f));
        ImGui::BeginChild("pockets_child", ImVec2(0, 0), true);

        GameState gs = ReadGameState();

        if (!gs.valid) {
            ImGui::TextColored(ImVec4(1,0.4f,0.4f,1), "Игра не активна / данные недоступны");
            ImGui::TextColored(ImVec4(0.6f,0.6f,0.6f,1), "Slide: 0x%llX", (unsigned long long)GetSlide());
        } else {
            // Общая сводка
            ImGui::TextColored(ImVec4(0.4f,1,0.4f,1), "Всего лунок: %d", gs.pocketCount);
            ImGui::Text("Шаров на столе:  %d", gs.activeBalls);
            ImGui::Text("Забито шаров:    %d", gs.pocketedBalls);
            ImGui::Text("Всего шаров:     %d", gs.totalBalls);
            ImGui::Separator();

            // Ближайшая лунка
            if (gs.nearestIdx >= 0) {
                ImGui::TextColored(ImVec4(1,1,0.3f,1),
                    "Ближайшая луза: #%d  dist=%.1f",
                    gs.nearestIdx, gs.nearestDist);
                ImGui::Text("  X=%.2f  Y=%.2f",
                    gs.pockets[gs.nearestIdx].x,
                    gs.pockets[gs.nearestIdx].y);
            } else {
                ImGui::TextColored(ImVec4(0.6f,0.6f,0.6f,1), "Ближайшая: нет данных");
            }
            ImGui::Separator();

            // Список всех лунок
            ImGui::Text("Все лунки:");
            for (int i = 0; i < gs.pocketCount; i++) {
                bool isNearest = (i == gs.nearestIdx);
                if (isNearest)
                    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1,1,0.3f,1));

                ImGui::Text("  [%d] X=%.2f  Y=%.2f%s",
                    i,
                    gs.pockets[i].x,
                    gs.pockets[i].y,
                    isNearest ? "  <-- ближайшая" : "");

                if (isNearest)
                    ImGui::PopStyleColor();
            }

            if (gs.pocketCount == 0) {
                ImGui::TextColored(ImVec4(1,0.6f,0,1),
                    "Лунки не найдены.\n"
                    "mPocketNominationButtons пуст.\n"
                    "(режим без выбора лузы?)");
            }
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
