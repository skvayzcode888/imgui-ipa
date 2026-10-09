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
//  Проверено по дизасму pool binary (pool 56.30.0):
//
//  [GameManager sharedGameManager] -> gm
//  [gm table]                      -> table
//  [table tableProperties]         -> tp
//  [tp getPockets]                 -> C++ vector* sret
//  [tp getPocketRadius]            -> double sret (x8)
//  [table balls]                   -> NSArray
//  [ball position]                 -> CGPoint sret (x8)
//
// ============================================================
//  Траектория — ivar offset'ы из _OBJC_IVAR_$_ символов pool binary:
//
//  UserSettingsManager._showCueBallTrajectory  @ +0x12  (bool)
//  UserSettingsManager._wideGuideline          @ +0x13  (bool)
//  GameManager.mVisualCue                      @ +0x4D0 (VisualCue*)
//  VisualCue.mVisualGuide                      @ +0x3B8 (ptr)
//  VisualGuide.showCueBallTrajectory           @ +0x36  (bool)
//     → -[GameManager setShowCueBallTrajectory]: *(visualGuide + 0x36) = value
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
//  Траектория — через ivar offset'ы из бинаря игры
// ============================================================

// Читаем raw ptr из ivar объекта (не ObjC id — обходим ARC)
static uintptr_t ReadRawPtr(id obj, ptrdiff_t off)
{
    if (!obj) return 0;
    uintptr_t raw = 0;
    @try { raw = *(uintptr_t *)((uint8_t *)(__bridge void *)obj + off); }
    @catch (...) {}
    return raw;
}

static void WriteBoolIvar(id obj, ptrdiff_t off, bool val)
{
    if (!obj) return;
    @try { *(bool *)((uint8_t *)(__bridge void *)obj + off) = val; }
    @catch (...) {}
}

static bool ReadBoolIvar(id obj, ptrdiff_t off)
{
    if (!obj) return false;
    bool val = false;
    @try { val = *(bool *)((uint8_t *)(__bridge void *)obj + off); }
    @catch (...) {}
    return val;
}

// Включаем/выключаем Cue Ball Trajectory
// Источник: -[GameManager setShowCueBallTrajectory] в pool binary
static void SetCueBallTrajectory(bool enabled)
{
    @try {
        // 1. Устанавливаем флаг в UserSettingsManager
        id usm = SafeCall((id)objc_getClass("UserSettingsManager"), "sharedUserSettingsManager");
        WriteBoolIvar(usm, 0x12, enabled);

        // 2. Вызываем [gm setShowCueBallTrajectory] — он сам читает USM и обновляет VisualGuide
        id gm = GetGameManager();
        if (gm) {
            SEL s = sel_registerName("setShowCueBallTrajectory");
            if ([gm respondsToSelector:s])
                ((void(*)(id,SEL))objc_msgSend)(gm, s);
        }
    } @catch (...) {}
}

// Включаем/выключаем Wide Guideline
static void SetWideGuideline(bool enabled)
{
    @try {
        id usm = SafeCall((id)objc_getClass("UserSettingsManager"), "sharedUserSettingsManager");
        WriteBoolIvar(usm, 0x13, enabled);

        // [UserSettingsManager setWideGuideline:] применяет изменение
        if (usm) {
            SEL s = sel_registerName("setWideGuideline:");
            if ([usm respondsToSelector:s])
                ((void(*)(id,SEL,BOOL))objc_msgSend)(usm, s, enabled ? YES : NO);
        }
    } @catch (...) {}
}

// ============================================================
//  Game state
// ============================================================

struct PocketInfo { float x, y; int idx; };

struct BallScreenInfo { float worldX, worldY; ImU32 color; int number; id ballObj; };

// forward declarations — определения ниже
static ImVec2 WorldToScreen(float worldX, float worldY);
static ImU32  BallColor(id ball);
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
    // Позиции активных шаров для рисования линий
    int           ballLineCount;
    BallScreenInfo ballLines[16];
};

static GameState ReadGameState()
{
    GameState s = {};
    s.nearestIdx  = -1;
    s.nearestDist = 1e9f;

    UpdateScreenParams(); // обновляем параметры конвертации координат

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

                    // Ball.state @ +0xA4: 0=active/inPlay, 2=pocketed, 4=hidden
                    // Из -[Ball setState:]: state==2||state==4 -> hidden
                    int ballState = 0;
                    @try { ballState = *(int *)((uint8_t *)(__bridge void *)ball + 0xA4); }
                    @catch (...) {}

                    if (ballState >= 2) {
                        s.pocketedBalls++;
                        continue;
                    }
                    s.activeBalls++;

                    // Сохраняем позицию для рисования линий
                    if (s.ballLineCount < 16) {
                        BallScreenInfo &bi = s.ballLines[s.ballLineCount++];
                        bi.worldX  = (float)pos.x;
                        bi.worldY  = (float)pos.y;
                        bi.color   = BallColor(ball);
                        bi.number  = BallNumber(ball);
                        bi.ballObj = ball; // weak ref — не retain, игровой объект живёт пока игра идёт
                    }

                    if (BallNumber(ball) == 0) {
                        s.cueX = (float)pos.x;
                        s.cueY = (float)pos.y;
                        g_cueBallRef = ball; // для PocketToScreen
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

// ============================================================
// Конвертация координат — по алгоритму sub_20A30 из poolLIB
//
// Физические координаты (ball.position, getPockets) — в пространстве физики.
// Визуальные координаты — visualBall.position (CCNode, пространство Table layer).
// Экранные — DisplaySize / windowAreaInPoints масштаб + safeArea offset.
//
// Формула (sub_20A30):
//   world = [visualBall.parent convertToWorldSpace: visualBall.position]
//   sx = DispW / winW * (world.x + safe.x)
//   sy = DispH - (world.y + safe.y) * (DispH / winH)
// ============================================================

// Кешируем параметры конвертации (заполняется каждый кадр из ReadGameState)
struct ScreenParams {
    float dispW, dispH;     // ImGui DisplaySize
    float winW,  winH;      // CCDirector._windowAreaInPoints.size
    float safeX, safeY;     // CCDirector._safeAreaInPoints.origin
    bool  valid;
};
static ScreenParams g_screenParams = {};

static void UpdateScreenParams()
{
    @try {
        id dir = SafeCall((id)objc_getClass("CCDirector"), "sharedDirector");
        if (!dir) return;

        // _windowAreaInPoints через ivar_getOffset
        Class cls = object_getClass(dir);

        // winArea
        Ivar winIvar = class_getInstanceVariable(cls, "_windowAreaInPoints");
        if (!winIvar) winIvar = class_getInstanceVariable(cls, "m_winSizeInPoints");
        if (winIvar) {
            ptrdiff_t off = ivar_getOffset(winIvar);
            if (off > 0) {
                // CGRect: origin(x,y) size(w,h) — 4 doubles or 4 floats
                float *p = (float *)((uint8_t *)(__bridge void *)dir + off);
                // CGRect layout: x, y, w, h (CGFloat = float on 32bit, double on 64bit)
                // On ARM64 iOS CGFloat = double (8 bytes)
                double *pd = (double *)p;
                // CGRect: {origin.x, origin.y, size.width, size.height}
                g_screenParams.winW  = (float)pd[2]; // size.width
                g_screenParams.winH  = (float)pd[3]; // size.height
            }
        }

        // _safeAreaInPoints
        Ivar safeIvar = class_getInstanceVariable(cls, "_safeAreaInPoints");
        if (safeIvar) {
            ptrdiff_t off = ivar_getOffset(safeIvar);
            if (off > 0) {
                double *pd = (double *)((uint8_t *)(__bridge void *)dir + off);
                g_screenParams.safeX = (float)pd[0]; // origin.x
                g_screenParams.safeY = (float)pd[1]; // origin.y
            }
        }

        // Фолбэк через selector если ivar не нашли
        if (g_screenParams.winW < 1.0f || g_screenParams.winH < 1.0f) {
            if ([dir respondsToSelector:sel_registerName("winSizeInPixels")]) {
                typedef CGSize (*SizeFn)(id,SEL);
                CGSize sz = ((SizeFn)objc_msgSend)(dir, sel_registerName("winSizeInPixels"));
                g_screenParams.winW = (float)sz.width;
                g_screenParams.winH = (float)sz.height;
            }
        }

        ImVec2 disp = ImGui::GetIO().DisplaySize;
        g_screenParams.dispW = disp.x;
        g_screenParams.dispH = disp.y;
        g_screenParams.valid = (g_screenParams.winW > 1.0f && g_screenParams.winH > 1.0f);
    } @catch (...) {}
}

// Конвертация Cocos2D world coords → ImGui screen (sub_20A30 формула)
static ImVec2 WorldToImGui(float worldX, float worldY)
{
    if (!g_screenParams.valid) return ImVec2(-9999, -9999);
    float sx = g_screenParams.dispW / g_screenParams.winW * (worldX + g_screenParams.safeX);
    float sy = g_screenParams.dispH - (worldY + g_screenParams.safeY) * (g_screenParams.dispH / g_screenParams.winH);
    return ImVec2(sx, sy);
}

// Получить Cocos2D world position шара через visualBall parent
static ImVec2 BallToScreen(id ball)
{
    if (!ball) return ImVec2(-9999, -9999);
    @try {
        typedef CGPoint (*ConvFn)(id, SEL, CGPoint);

        // ball.visualBall @ +0x18
        uintptr_t vbPtr = *(uintptr_t *)((uint8_t *)(__bridge void *)ball + 0x18);
        if (vbPtr < 0x100000000ULL || vbPtr > 0x7FFFFFFFFFFFULL) return ImVec2(-9999,-9999);
        id visualBall = (__bridge id)(void *)vbPtr;

        // [visualBall position] → CGPoint в родительском пространстве
        SEL posSel = sel_registerName("position");
        if (![visualBall respondsToSelector:posSel]) return ImVec2(-9999,-9999);
        CGPoint vbPos;
        // position возвращается в d0/d1 (ObjC метод)
        typedef CGPoint (*PosFn)(id,SEL);
        vbPos = ((PosFn)objc_msgSend)(visualBall, posSel);

        // [visualBall.parent convertToWorldSpace: vbPos]
        SEL parentSel = sel_registerName("parent");
        SEL c2wSel    = sel_registerName("convertToWorldSpace:");
        id parent = nil;
        if ([visualBall respondsToSelector:parentSel])
            parent = ((id(*)(id,SEL))objc_msgSend)(visualBall, parentSel);

        CGPoint worldPt = vbPos;
        if (parent && [parent respondsToSelector:c2wSel])
            worldPt = ((ConvFn)objc_msgSend)(parent, c2wSel, vbPos);

        return WorldToImGui((float)worldPt.x, (float)worldPt.y);
    } @catch (...) {
        return ImVec2(-9999,-9999);
    }
}

// Лунки — их координаты в физическом пространстве
// Нужно перевести через тот же visualBall parent что и шары
// Используем белый шар как референс для масштаба
static id g_cueBallRef = nil; // обновляется в ReadGameState

static ImVec2 PocketToScreen(float physX, float physY)
{
    if (!g_screenParams.valid) return ImVec2(-9999,-9999);
    if (!g_cueBallRef) return ImVec2(-9999,-9999);
    @try {
        // Физические координаты лунок совпадают с пространством visualBall parent
        // потому что [ball position] и getPockets используют одно и то же пространство
        // Просто используем WorldToImGui напрямую — лунки уже в world space
        // (sub_21228 использует ту же матрицу что и шары)
        return WorldToImGui(physX, physY);
    } @catch (...) {
        return ImVec2(-9999,-9999);
    }
}

static ImVec2 WorldToScreen(float worldX, float worldY)
{
    return WorldToImGui(worldX, worldY);
}

// Цвет шара по classification и number
// classification: 0=cue, 1=solid, 2=striped, 3=eight
static ImU32 BallColor(id ball)
{
    if (!ball) return IM_COL32(255,255,255,200);
    int cls = 0, num = 0;
    @try {
        cls = *(int *)((uint8_t *)(__bridge void *)ball + 0xA0);
        num = BallNumber(ball);
    } @catch (...) {}

    if (cls == 0) return IM_COL32(255, 255, 255, 220); // белый — cue
    if (num == 8)  return IM_COL32(20,  20,  20,  220); // чёрный
    if (cls == 2)  return IM_COL32(255, 160,  50, 220); // полосатый — оранжевый
    // Solid: цвет по номеру
    static const ImU32 solidColors[] = {
        IM_COL32(255,230, 0,220), // 1 yellow
        IM_COL32( 20, 80,220,220), // 2 blue
        IM_COL32(220, 30, 30,220), // 3 red
        IM_COL32(150,  0,150,220), // 4 purple
        IM_COL32(220, 80,  0,220), // 5 orange
        IM_COL32( 20,160, 20,220), // 6 green
        IM_COL32(180, 20, 20,220), // 7 maroon
    };
    if (num >= 1 && num <= 7) return solidColors[num - 1];
    return IM_COL32(200,200,200,200);
}

static bool      g_showPockets = false;
static bool      g_demoWindow  = false;
static bool      g_showLines   = false;  // линии от шаров к лункам
static GameState g_state       = {};
static bool      g_stateOk     = false;
static void DrawMenu()
{
    ImGui::SetNextWindowSize(ImVec2(340, 420), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos (ImVec2(40,  60),  ImGuiCond_FirstUseEver);
    ImGui::Begin("crown.pw");

    ImGui::SliderFloat("UI scale", &ImGui::GetIO().FontGlobalScale, 0.6f, 2.5f);
    ImGui::Separator();

    // ---- Trajectory (из бинаря игры) ----
    {
        id usm = SafeCall((id)objc_getClass("UserSettingsManager"), "sharedUserSettingsManager");
        bool traj = ReadBoolIvar(usm, 0x12);
        bool wide = ReadBoolIvar(usm, 0x13);

        if (ImGui::Checkbox("Cue Ball Trajectory", &traj))
            SetCueBallTrajectory(traj);

        if (ImGui::Checkbox("Wide Guideline", &wide))
            SetWideGuideline(wide);
    }

    ImGui::Separator();
    ImGui::Checkbox("Ball Lines to Pockets", &g_showLines);
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

    // ---- Fullscreen overlay: линии от шаров к лункам ----
    if (g_showLines && g_stateOk && g_state.valid) {
        ImGuiIO &io = ImGui::GetIO();
        ImGui::SetNextWindowPos(ImVec2(0, 0));
        ImGui::SetNextWindowSize(io.DisplaySize);
        ImGui::SetNextWindowBgAlpha(0.0f);
        ImGui::Begin("##overlay", nullptr,
            ImGuiWindowFlags_NoDecoration |
            ImGuiWindowFlags_NoInputs     |
            ImGuiWindowFlags_NoNav        |
            ImGuiWindowFlags_NoMove       |
            ImGuiWindowFlags_NoBringToFrontOnFocus |
            ImGuiWindowFlags_NoSavedSettings);

        ImDrawList *dl = ImGui::GetWindowDrawList();
        GameState  &gs = g_state;

        // Конвертируем лунки в экранные coords
        ImVec2 pocketSc[6];
        for (int p = 0; p < gs.pocketCount; p++)
            pocketSc[p] = WorldToImGui(gs.pockets[p].x, gs.pockets[p].y);

        // Рисуем по каждому активному шару из кеша
        for (int b = 0; b < gs.ballLineCount; b++) {
            BallScreenInfo &bi = gs.ballLines[b];
            if (!bi.ballObj) continue;

            ImVec2 ballSc = BallToScreen(bi.ballObj);
            if (ballSc.x < -1000) continue;

            ImU32 col = bi.color;
            int ballNum = bi.number;

            // Ищем ближайшую лунку к этому шару
            float minDist = 1e9f;
            int nearestP = -1;
            for (int p = 0; p < gs.pocketCount; p++) {
                if (pocketSc[p].x < -1000) continue;
                float dx = pocketSc[p].x - ballSc.x;
                float dy = pocketSc[p].y - ballSc.y;
                float d = sqrtf(dx*dx + dy*dy);
                if (d < minDist) { minDist = d; nearestP = p; }
            }
            if (nearestP < 0) continue;

            ImVec2 &psc = pocketSc[nearestP];
            float thick = (ballNum == 0) ? 3.0f : 1.8f;
            ImU32 colA = (col & 0x00FFFFFF) | 0xC0000000;
            dl->AddLine(ballSc, psc, colA, thick);
            dl->AddCircle(psc, 10.0f, IM_COL32(50,255,50,180), 12, 1.5f);
        }

        ImGui::End();
    }
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
