// Dear ImGui (Metal) overlay — 8 Ball Pool mod
// Open/close: 3-finger double-tap
// ARC (-fobjc-arc), ARM64, C++17

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
#include <cmath>
#include <vector>
#include <algorithm>
#include <initializer_list>
#include <mach/mach.h>
#include <libkern/OSCacheControl.h>

// ============================================================
//  Runtime патч: Infinite Guideline (без изменений)
//  Оригинальные байты: E8 13 04 39 -> Патч: FF 13 04 39
// ============================================================

static bool g_infiniteGuideline = false;

static bool PatchMemory(uintptr_t addr, const uint8_t *newBytes, size_t len)
{
    uintptr_t page    = addr & ~(uintptr_t)(PAGE_SIZE - 1);
    size_t    pageSz  = ((addr + len - page) + PAGE_SIZE - 1) & ~(size_t)(PAGE_SIZE - 1);
    kern_return_t kr  = vm_protect(mach_task_self(), page, pageSz, false,
                                   VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) return false;
    memcpy((void *)addr, newBytes, len);
    vm_protect(mach_task_self(), page, pageSz, false, VM_PROT_READ | VM_PROT_EXECUTE);
    sys_icache_invalidate((void *)addr, len);
    return true;
}

static uintptr_t GetPoolSlide()
{
    uint32_t cnt = _dyld_image_count();
    for (uint32_t i = 0; i < cnt; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        const char *base = strrchr(name, '/');
        base = base ? base + 1 : name;
        if (strcmp(base, "pool") == 0)
            return (uintptr_t)_dyld_get_image_vmaddr_slide(i);
    }
    return (uintptr_t)_dyld_get_image_vmaddr_slide(0);
}

static void SetInfiniteGuideline(bool enable)
{
    uintptr_t patchAddr = GetPoolSlide() + 0x100104534ULL;
    static const uint8_t orig[]  = { 0xE8, 0x13, 0x04, 0x39 };
    static const uint8_t patch[] = { 0xFF, 0x13, 0x04, 0x39 };
    PatchMemory(patchAddr, enable ? patch : orig, 4);
    g_infiniteGuideline = enable;
}

// ============================================================
//  Coordinate conversion
//
//  ball.visualBall — CCNode, его _position лежит в пространстве PARENT'а:
//     world = [parent convertToWorldSpace: visualBall._position]
//     ui    = [CCDirector convertToUI: world]
//     screen= GL-вью -> окно -> overlay
//  Физика (позиции мячей/лузы) -> экран: affine (МНК) по мячам, у которых
//  известны оба представления. Есть отбрасывание выбросов и диагностика.
// ============================================================

static __weak UIView *gOverlayView = nil;

// ручная подстройка, если остаётся постоянный сдвиг (слайдеры в меню)
static float g_offX = 0.f, g_offY = 0.f;
static float g_fitTol = 10.f;          // допустимая RMS-ошибка фита, points

static inline bool IsValidPt(CGPoint p) { return std::isfinite(p.x) && std::isfinite(p.y); }
static const CGPoint kBadPt = { (CGFloat)NAN, (CGFloat)NAN };

static inline id Msg0(id obj, const char *sel) {
    if (!obj) return nil;
    SEL s = sel_registerName(sel);
    if (![obj respondsToSelector:s]) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(obj, s);
}

static inline CGPoint MsgPt_Pt(id obj, SEL sel, CGPoint p) {
    return ((CGPoint(*)(id,SEL,CGPoint))objc_msgSend)(obj, sel, p);
}

static inline CGPoint MsgPt_0(id obj, SEL sel) {
    return ((CGPoint(*)(id,SEL))objc_msgSend)(obj, sel);
}

static id GetIvarObject(id obj, const char *name) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return nil;
    return object_getIvar(obj, iv);
}

static bool ReadIvarRaw(id obj, const char *name, void *out, size_t size) {
    if (!obj) return false;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return false;
    ptrdiff_t off = ivar_getOffset(iv);
    if (off <= 0) return false;
    memcpy(out, (const char *)(__bridge const void *)obj + off, size);
    return true;
}

static id CCDirectorShared() {
    Class c = NSClassFromString(@"CCDirector");
    return c ? Msg0((id)c, "sharedDirector") : nil;
}

static UIView *GLViewOf(id director) {
    if (!director) return nil;
    for (const char *n : { "openGLView", "view" }) {
        id v = Msg0(director, n);
        if ([v isKindOfClass:[UIView class]]) return (UIView *)v;
    }
    return nil;
}

// запасной вариант, если у CCDirector нет convertToUI: (cocos2d: y вниз)
static CGPoint ManualToUI(id director, CGPoint w) {
    UIView *gl = GLViewOf(director);
    CGFloat h = gl ? gl.bounds.size.height : UIScreen.mainScreen.bounds.size.height;
    return CGPointMake(w.x, h - w.y);
}

static CGPoint UIToOverlay(id director, CGPoint ui) {
    UIView *gl = GLViewOf(director);
    if (!gl) return ui;
    CGPoint inWindow = [gl convertPoint:ui toView:nil];
    UIView *ov = gOverlayView;
    return ov ? [ov convertPoint:inWindow fromView:nil] : inWindow;
}

// why: 0 ok, 1 нет visualBall, 2 нет parent/ноды, 3 нет position, 4 ошибка конвертации
static CGPoint WorldToScreenEx(double x, double y, id referenceNode, int *why) {
    int dummy; if (!why) why = &dummy;
    *why = 0;
    if (!referenceNode) { *why = 2; return kBadPt; }
    @try {
        id director = CCDirectorShared();
        if (!director) { *why = 4; return kBadPt; }
        SEL sWorld = sel_registerName("convertToWorldSpace:");
        SEL sUI    = sel_registerName("convertToUI:");
        if (![referenceNode respondsToSelector:sWorld]) { *why = 4; return kBadPt; }
        CGPoint world = MsgPt_Pt(referenceNode, sWorld, CGPointMake((CGFloat)x, (CGFloat)y));
        if (!IsValidPt(world)) { *why = 4; return kBadPt; }
        CGPoint ui = [director respondsToSelector:sUI] ? MsgPt_Pt(director, sUI, world)
                                                       : ManualToUI(director, world);
        if (!IsValidPt(ui)) { *why = 4; return kBadPt; }
        CGPoint r = UIToOverlay(director, ui);
        return CGPointMake(r.x + g_offX, r.y + g_offY);
    } @catch (...) { *why = 4; return kBadPt; }
}

// Точная экранная позиция шара через visualBall CCNode
static CGPoint BallToScreenEx(id ball, int *why) {
    int dummy; if (!why) why = &dummy;
    *why = 0;
    if (!ball) { *why = 1; return kBadPt; }
    @try {
        id visual = GetIvarObject(ball, "visualBall");
        if (!visual) { *why = 1; return kBadPt; }
        id parent = GetIvarObject(visual, "_parent");
        if (!parent) parent = Msg0(visual, "parent");
        if (!parent) { *why = 2; return kBadPt; }
        CGPoint pos;
        if (!ReadIvarRaw(visual, "_position", &pos, sizeof(pos))) {
            SEL sp = sel_registerName("position");
            if (![visual respondsToSelector:sp]) { *why = 3; return kBadPt; }
            pos = MsgPt_0(visual, sp);
        }
        if (!IsValidPt(pos)) { *why = 3; return kBadPt; }
        return WorldToScreenEx(pos.x, pos.y, parent, why);
    } @catch (...) { *why = 4; return kBadPt; }
}

static CGPoint BallToScreen(id ball) { int w; return BallToScreenEx(ball, &w); }

// ---- физическая позиция шара: -[Ball position] ----
// Ты определил, что метод возвращает через x8 (sret). Буфер большой (64 байта) и
// предзаполнен NaN: если метод на самом деле вернул CGPoint в d0/d1, буфер останется NaN —
// тогда переключаемся на HFA-вызов (он безопасен только после такого вывода).
struct SretBuf {
    double v[8];
    SretBuf() { for (int i = 0; i < 8; i++) v[i] = NAN; }
    SretBuf(const SretBuf &o) { memcpy(v, o.v, sizeof(v)); }
};

static int g_posMode = -1;   // -1 неизвестно, 0 sret(x8), 1 HFA(d0/d1)

static bool GetBallPhysPos(id ball, double *x, double *y) {
    SEL s = sel_registerName("position");
    if (![ball respondsToSelector:s]) return false;
    if (g_posMode != 1) {
        SretBuf r = ((SretBuf(*)(id,SEL))objc_msgSend)(ball, s);
        if (std::isfinite(r.v[0]) && std::isfinite(r.v[1])) {
            g_posMode = 0; *x = r.v[0]; *y = r.v[1]; return true;
        }
        if (g_posMode == 0) return false;
    }
    CGPoint p = MsgPt_0(ball, s);
    if (!IsValidPt(p)) return false;
    g_posMode = 1; *x = p.x; *y = p.y; return true;
}

// Шар в игре: state < 2 (0 active; 2 pocketed; 4 hidden) и onTable (если есть)
static bool BallInPlay(id ball) {
    if (!ball) return false;
    int st = 0;
    bool haveSt = ReadIvarRaw(ball, "state", &st, sizeof(st));
    if (haveSt && st >= 2) return false;
    SEL s = sel_registerName("onTable");
    if ([ball respondsToSelector:s])
        return ((BOOL(*)(id,SEL))objc_msgSend)(ball, s) ? true : false;
    return haveSt;
}

// ---- affine физика -> экран ----
struct Affine {
    double a=0,b=0,c=0,d=0,tx=0,ty=0;
    bool have=false;    // фит посчитан
    bool valid=false;   // и RMS в допуске
    CGPoint apply(double px, double py) const {
        return CGPointMake(a*px+b*py+tx, c*px+d*py+ty);
    }
};

struct Sample { double px, py, sx, sy; };

static double Det3(const double m[3][3]) {
    return m[0][0]*(m[1][1]*m[2][2]-m[1][2]*m[2][1])
          -m[0][1]*(m[1][0]*m[2][2]-m[1][2]*m[2][0])
          +m[0][2]*(m[1][0]*m[2][1]-m[1][1]*m[2][0]);
}
static bool Solve3(const double M[3][3], const double r[3], double out[3]) {
    double D = Det3(M);
    if (std::fabs(D) < 1e-12) return false;
    for (int c = 0; c < 3; ++c) {
        double T[3][3]; memcpy(T, M, sizeof(T));
        for (int i = 0; i < 3; ++i) T[i][c] = r[i];
        out[c] = Det3(T) / D;
    }
    return true;
}

static bool FitAffine(const std::vector<Sample> &s, Affine &T) {
    if (s.size() < 3) return false;
    double Sxx=0,Sxy=0,Syy=0,Sx=0,Sy=0,N=(double)s.size();
    double Rx[3]={0,0,0}, Ry[3]={0,0,0};
    for (auto &p : s) {
        Sxx+=p.px*p.px; Sxy+=p.px*p.py; Syy+=p.py*p.py;
        Sx+=p.px; Sy+=p.py;
        Rx[0]+=p.px*p.sx; Rx[1]+=p.py*p.sx; Rx[2]+=p.sx;
        Ry[0]+=p.px*p.sy; Ry[1]+=p.py*p.sy; Ry[2]+=p.sy;
    }
    const double M[3][3] = {{Sxx,Sxy,Sx},{Sxy,Syy,Sy},{Sx,Sy,N}};
    double ox[3], oy[3];
    if (!Solve3(M, Rx, ox) || !Solve3(M, Ry, oy)) return false;
    T.a=ox[0]; T.b=ox[1]; T.tx=ox[2];
    T.c=oy[0]; T.d=oy[1]; T.ty=oy[2];
    T.have = true;
    return true;
}

static double Residual(const Affine &T, const Sample &p) {
    CGPoint q = T.apply(p.px, p.py);
    return std::sqrt((q.x-p.sx)*(q.x-p.sx) + (q.y-p.sy)*(q.y-p.sy));
}
static double RmsOf(const Affine &T, const std::vector<Sample> &s) {
    double se = 0;
    for (auto &p : s) { double r = Residual(T, p); se += r*r; }
    return std::sqrt(se / (double)s.size());
}

// ---- диагностика фита (показывается в меню) ----
struct FitInfo {
    int ballsTotal=0, inPlay=0, samples=0, used=0;
    int noPhys=0, failVisual=0, failParent=0, failPos=0, failConv=0;
    double rms=-1;
    double p0x=0,p0y=0,s0x=0,s0y=0;      // первый сэмпл: физика -> экран
    double k0px=0,k0py=0,k0sx=0,k0sy=0;  // лунка 0: физика -> экран
    double glW=0, glH=0;
    int posMode=-1;
};

static Affine CalibrateFromBalls(NSArray *balls, FitInfo &fi) {
    Affine T;
    std::vector<Sample> s;
    fi.ballsTotal = (int)[balls count];
    for (id ball in balls) {
        if (!BallInPlay(ball)) continue;
        fi.inPlay++;
        double px, py;
        if (!GetBallPhysPos(ball, &px, &py)) { fi.noPhys++; continue; }
        int why = 0;
        CGPoint sc = BallToScreenEx(ball, &why);
        if (!IsValidPt(sc)) {
            if (why == 1) fi.failVisual++;
            else if (why == 2) fi.failParent++;
            else if (why == 3) fi.failPos++;
            else fi.failConv++;
            continue;
        }
        s.push_back({ px, py, (double)sc.x, (double)sc.y });
    }
    fi.samples = (int)s.size();
    fi.posMode = g_posMode;
    if (s.size() < 3) return T;
    if (!FitAffine(s, T)) return T;

    double rms = RmsOf(T, s);

    // отбрасываем выбросы (шар в движении/интерполяция/ошибка чтения) и пересчитываем
    if (rms > 2.0 && s.size() > 5) {
        std::vector<double> res;
        for (auto &p : s) res.push_back(Residual(T, p));
        std::vector<double> sorted = res;
        std::sort(sorted.begin(), sorted.end());
        double med = sorted[sorted.size() / 2];
        double lim = std::max(3.0 * med, 3.0);
        std::vector<Sample> s2;
        for (size_t i = 0; i < s.size(); i++) if (res[i] <= lim) s2.push_back(s[i]);
        if (s2.size() >= 4 && s2.size() < s.size()) {
            Affine T2;
            if (FitAffine(s2, T2)) {
                double r2 = RmsOf(T2, s2);
                if (r2 < rms) { T = T2; rms = r2; s = s2; }
            }
        }
    }
    fi.used = (int)s.size();
    fi.rms  = rms;
    fi.p0x = s[0].px; fi.p0y = s[0].py; fi.s0x = s[0].sx; fi.s0y = s[0].sy;
    T.valid = (rms < (double)g_fitTol);
    return T;
}

// ============================================================
//  Helpers: ObjC calls / ivar
// ============================================================

static id SafeCall(id obj, const char *sel_name) {
    if (!obj) return nil;
    SEL s = sel_registerName(sel_name);
    if (![obj respondsToSelector:s]) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(obj, s);
}

static void WriteBoolIvar(id obj, ptrdiff_t off, bool val) {
    if (!obj) return;
    @try { *(bool*)((uint8_t*)(__bridge void*)obj+off)=val; } @catch(...) {}
}
static bool ReadBoolIvar(id obj, ptrdiff_t off) {
    if (!obj) return false;
    bool val=false;
    @try { val=*(bool*)((uint8_t*)(__bridge void*)obj+off); } @catch(...) {}
    return val;
}

static id GetGameManager() {
    Class cls = objc_getClass("GameManager");
    if (!cls) return nil;
    SEL s = sel_registerName("sharedGameManager");
    if (![(id)cls respondsToSelector:s]) return nil;
    return ((id(*)(id,SEL))objc_msgSend)((id)cls, s);
}

static int BallNumber(id ball) {
    if (!ball) return -1;
    Ivar iv = class_getInstanceVariable(object_getClass(ball), "number");
    if (!iv) return -1;
    ptrdiff_t off = ivar_getOffset(iv);
    if (off < 0) return -1;
    return *(int*)((uint8_t*)(__bridge void*)ball + off);
}

// ============================================================
//  Trajectory settings
// ============================================================

static void SetCueBallTrajectory(bool enabled) {
    @try {
        id usm = SafeCall((id)objc_getClass("UserSettingsManager"), "sharedUserSettingsManager");
        WriteBoolIvar(usm, 0x12, enabled);
        id gm = GetGameManager();
        if (gm) {
            SEL s = sel_registerName("setShowCueBallTrajectory");
            if ([gm respondsToSelector:s]) ((void(*)(id,SEL))objc_msgSend)(gm,s);
        }
    } @catch(...) {}
}

static void SetWideGuideline(bool enabled) {
    @try {
        id usm = SafeCall((id)objc_getClass("UserSettingsManager"), "sharedUserSettingsManager");
        WriteBoolIvar(usm, 0x13, enabled);
        if (usm) {
            SEL s = sel_registerName("setWideGuideline:");
            if ([usm respondsToSelector:s])
                ((void(*)(id,SEL,BOOL))objc_msgSend)(usm, s, enabled?YES:NO);
        }
    } @catch(...) {}
}

// ============================================================
//  Pocket reading
//  getPockets возвращает УКАЗАТЕЛЬ на std::vector<{double x,y}> (x0), не sret.
//  Читаем begin/end напрямую — ничего не аллоцируем и не течём.
// ============================================================

struct Vec2d { double x, y; };

typedef uintptr_t *(*RawPtrFn)(id, SEL);

static int ReadPockets(id tp, Vec2d *out, int maxN) {
    if (!tp) return 0;
    const char *names[] = { "getPockets", "getPocketAimPoints", nullptr };
    for (int ni=0; names[ni]; ni++) {
        SEL s = sel_registerName(names[ni]);
        if (![tp respondsToSelector:s]) continue;
        uintptr_t *vec = ((RawPtrFn)objc_msgSend)(tp, s);
        if (!vec) continue;
        uintptr_t begin=vec[0], end=vec[1];
        if (begin<0x100000000ULL||end<0x100000000ULL||end<=begin) continue;
        uintptr_t diff=end-begin;
        if (diff<16||diff>96) continue;
        int cnt=(int)(diff/16); if(cnt>maxN) cnt=maxN;
        for (int i=0;i<cnt;i++) {
            double *p=(double*)(begin+(uintptr_t)i*16);
            out[i]={p[0],p[1]};
        }
        return cnt;
    }
    return 0;
}

// ============================================================
//  Game state (обновляется КАЖДЫЙ кадр, чтобы affine не отставал от камеры)
// ============================================================

struct GameState {
    bool  valid = false;
    char  err[128] = {};
    int   pocketCount = 0;
    Vec2d pockets[6] = {};
    int   totalBalls=0, activeBalls=0, pocketedBalls=0;
    float cueX=0, cueY=0;
    NSArray *ballsArr = nil;
    Affine  affine = {};
    FitInfo fit = {};
};

static GameState g_state   = {};
static bool      g_stateOk = false;

static GameState ReadGameState() {
    GameState s;
    @try {
        id gm = GetGameManager();
        if (!gm) { snprintf(s.err,sizeof(s.err),"no GameManager"); return s; }
        id table = SafeCall(gm,"table");
        if (!table) { snprintf(s.err,sizeof(s.err),"table=nil"); return s; }
        id tp = SafeCall(table,"tableProperties");
        if (!tp) { snprintf(s.err,sizeof(s.err),"tp=nil"); return s; }

        s.pocketCount = ReadPockets(tp, s.pockets, 6);

        id ballsArr = SafeCall(table,"balls");
        s.ballsArr = ballsArr;

        if (ballsArr && [ballsArr respondsToSelector:@selector(count)]) {
            NSUInteger n = [ballsArr count];
            s.totalBalls = (int)n;
            for (NSUInteger i=0; i<n && i<32; i++) {
                id ball = [ballsArr objectAtIndex:i];
                if (!ball) continue;
                int st=0;
                ReadIvarRaw(ball, "state", &st, sizeof(st));
                if (st >= 2) { s.pocketedBalls++; continue; }
                s.activeBalls++;
                if (BallNumber(ball)==0) {
                    double bx,by;
                    if (GetBallPhysPos(ball,&bx,&by)) { s.cueX=(float)bx; s.cueY=(float)by; }
                }
            }
        }

        if (ballsArr) s.affine = CalibrateFromBalls(ballsArr, s.fit);

        if (s.affine.have && s.pocketCount > 0) {
            CGPoint k = s.affine.apply(s.pockets[0].x, s.pockets[0].y);
            s.fit.k0px = s.pockets[0].x; s.fit.k0py = s.pockets[0].y;
            s.fit.k0sx = k.x;            s.fit.k0sy = k.y;
        }
        UIView *gl = GLViewOf(CCDirectorShared());
        if (gl) { s.fit.glW = gl.bounds.size.width; s.fit.glH = gl.bounds.size.height; }

        s.valid = true;
    } @catch(NSException *e) {
        snprintf(s.err,sizeof(s.err),"exc: %s", e.reason.UTF8String?:"?");
    } @catch(...) {
        snprintf(s.err,sizeof(s.err),"unknown exc");
    }
    return s;
}

// ============================================================
//  Menu
// ============================================================

static bool g_showPockets = true;
static bool g_demoWindow  = false;
static bool g_showLines   = false;
static bool g_showDots    = false;

static ImU32 BallColor(id ball) {
    if (!ball) return IM_COL32(255,255,255,200);
    int cls=0, num=BallNumber(ball);
    @try { cls=*(int*)((uint8_t*)(__bridge void*)ball+0xA0); } @catch(...) {}
    if (cls==0) return IM_COL32(255,255,255,220);
    if (num==8)  return IM_COL32(20,20,20,220);
    if (cls==2)  return IM_COL32(255,160,50,220);
    static const ImU32 sc[]={
        IM_COL32(255,230,0,220), IM_COL32(20,80,220,220),
        IM_COL32(220,30,30,220), IM_COL32(150,0,150,220),
        IM_COL32(220,80,0,220),  IM_COL32(20,160,20,220),
        IM_COL32(180,20,20,220)
    };
    if (num>=1&&num<=7) return sc[num-1];
    return IM_COL32(200,200,200,200);
}

static void DrawMenuWindow()
{
    ImGui::SetNextWindowSize(ImVec2(340,520), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos (ImVec2(40, 60),  ImGuiCond_FirstUseEver);
    ImGui::Begin("crown.pw");

    ImGui::SliderFloat("UI scale", &ImGui::GetIO().FontGlobalScale, 0.6f, 2.5f);
    ImGui::Separator();

    {
        id usm = SafeCall((id)objc_getClass("UserSettingsManager"),"sharedUserSettingsManager");
        bool traj = ReadBoolIvar(usm,0x12);
        bool wide = ReadBoolIvar(usm,0x13);
        if (ImGui::Checkbox("Cue Ball Trajectory",&traj)) SetCueBallTrajectory(traj);
        if (ImGui::Checkbox("Wide Guideline",&wide))       SetWideGuideline(wide);
    }
    ImGui::Separator();

    if (ImGui::Checkbox("Infinite Guideline",&g_infiniteGuideline))
        SetInfiniteGuideline(g_infiniteGuideline);
    ImGui::Separator();

    ImGui::Checkbox("Ball Lines to Pockets",&g_showLines);
    ImGui::Checkbox("Debug dots (шары/лунки)",&g_showDots);
    ImGui::SliderFloat("Offset X", &g_offX, -400.f, 400.f);
    ImGui::SliderFloat("Offset Y", &g_offY, -400.f, 400.f);
    ImGui::SliderFloat("Fit tol (pt)", &g_fitTol, 2.f, 40.f);
    ImGui::Separator();

    ImGui::Checkbox("Debug info",&g_showPockets);
    if (g_showPockets) {
        GameState &gs = g_state;
        if (!g_stateOk || !gs.valid) {
            ImGui::TextColored(ImVec4(1,.3f,.3f,1),"Not in match");
            if (g_stateOk) ImGui::Text("err: %s",gs.err);
        } else {
            const FitInfo &f = gs.fit;
            ImGui::Text("Lunok: %d  Shary: %d/%d", gs.pocketCount, gs.activeBalls, gs.totalBalls);
            ImGui::Text("inPlay %d  samples %d  used %d", f.inPlay, f.samples, f.used);
            ImGui::Text("fail: phys %d vis %d par %d pos %d conv %d",
                        f.noPhys, f.failVisual, f.failParent, f.failPos, f.failConv);
            ImGui::Text("pos ABI: %s", f.posMode==0 ? "sret(x8)" : f.posMode==1 ? "HFA(d0/d1)" : "?");
            if (f.rms >= 0) {
                bool ok = gs.affine.valid;
                ImGui::TextColored(ok ? ImVec4(.3f,1,.3f,1) : ImVec4(1,.3f,.3f,1),
                                   "Affine: %s  RMS %.2f pt", ok ? "OK" : "FAIL", f.rms);
            } else {
                ImGui::TextColored(ImVec4(1,.3f,.3f,1), "Affine: FAIL (samples<3 / вырожден)");
            }
            ImGui::Text("ball0 phys(%.3f,%.3f)", f.p0x, f.p0y);
            ImGui::Text("      -> scr(%.1f,%.1f)", f.s0x, f.s0y);
            ImGui::Text("pocket0 phys(%.3f,%.3f)", f.k0px, f.k0py);
            ImGui::Text("        -> scr(%.1f,%.1f)", f.k0sx, f.k0sy);
            ImGui::Text("GL view %.0fx%.0f", f.glW, f.glH);
        }
    }

    ImGui::Separator();
    ImGui::Checkbox("Demo",&g_demoWindow);
    ImGui::Text("%.1f FPS",ImGui::GetIO().Framerate);
    ImGui::End();

    if (g_demoWindow) ImGui::ShowDemoWindow(&g_demoWindow);
}

// Линии шар -> ближайшая лунка. Рисуем в background draw list (работает и при закрытом меню).
static void DrawBallLines()
{
    if (!(g_showLines || g_showDots)) return;
    if (!g_stateOk || !g_state.valid || !g_state.affine.valid) return;

    GameState &gs = g_state;
    ImDrawList *dl = ImGui::GetBackgroundDrawList();

    CGPoint pocketSc[6];
    for (int p = 0; p < gs.pocketCount; p++)
        pocketSc[p] = gs.affine.apply(gs.pockets[p].x, gs.pockets[p].y);

    if (g_showDots)
        for (int p = 0; p < gs.pocketCount; p++)
            dl->AddCircle(ImVec2((float)pocketSc[p].x,(float)pocketSc[p].y),
                          14.f, IM_COL32(50,255,50,230), 16, 2.f);

    NSArray *balls = gs.ballsArr;
    if (!balls) return;

    for (id ball in balls) {
        if (!BallInPlay(ball)) continue;

        CGPoint ballSc = BallToScreen(ball);
        if (!IsValidPt(ballSc)) continue;

        if (g_showDots)
            dl->AddCircle(ImVec2((float)ballSc.x,(float)ballSc.y),
                          8.f, IM_COL32(255,60,60,230), 12, 2.f);
        if (!g_showLines) continue;

        double bx, by;
        if (!GetBallPhysPos(ball, &bx, &by)) continue;

        float minD = 1e30f; int nearP = -1;
        for (int p = 0; p < gs.pocketCount; p++) {
            float dx = (float)(gs.pockets[p].x - bx);
            float dy = (float)(gs.pockets[p].y - by);
            float d = dx*dx + dy*dy;
            if (d < minD) { minD = d; nearP = p; }
        }
        if (nearP < 0) continue;

        CGPoint psc = pocketSc[nearP];
        if (!IsValidPt(psc)) continue;

        ImU32 col  = BallColor(ball);
        ImU32 colA = (col & 0x00FFFFFF) | 0xC0000000;
        float thick = (BallNumber(ball) == 0) ? 3.0f : 1.8f;

        dl->AddLine(ImVec2((float)ballSc.x,(float)ballSc.y),
                    ImVec2((float)psc.x,   (float)psc.y), colA, thick);
        dl->AddCircle(ImVec2((float)psc.x,(float)psc.y), 10.f, IM_COL32(50,255,50,180), 12, 1.5f);
    }
}

// ============================================================
//  Overlay view
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
    _queue  = [_device newCommandQueue];

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
    io.Fonts->AddFontDefault();
    io.FontGlobalScale = 1.5f;

    ImGui_ImplMetal_Init(_device);

    gOverlayView = self;   // для конвертации координат

    return self;
}

// MTKView нужен, пока открыто меню ИЛИ включены линии
- (void)refreshVisibility
{
    BOOL on = self.menuOpen || g_showLines || g_showDots;
    if (_mtk.hidden == on)  _mtk.hidden = !on;
    if (_mtk.paused == on)  _mtk.paused = !on;
}

- (void)toggleMenu
{
    self.menuOpen = !self.menuOpen;
    [self refreshVisibility];
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
    io.AddMouseButtonEvent(0,down);
}
- (void)touchesBegan:(NSSet*)t withEvent:(UIEvent*)e     { [self feed:t down:YES]; }
- (void)touchesMoved:(NSSet*)t withEvent:(UIEvent*)e     { [self feed:t down:YES]; }
- (void)touchesEnded:(NSSet*)t withEvent:(UIEvent*)e     { [self feed:t down:NO];  }
- (void)touchesCancelled:(NSSet*)t withEvent:(UIEvent*)e { [self feed:t down:NO];  }
- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)s {}

- (void)drawInMTKView:(MTKView*)view
{
    CGSize b = view.bounds.size;
    CGSize d = view.drawableSize;
    if (b.width<=0||b.height<=0) return;

    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize             = ImVec2((float)b.width,(float)b.height);
    io.DisplayFramebufferScale = ImVec2((float)(d.width/b.width),(float)(d.height/b.height));

    static CFTimeInterval last=0;
    CFTimeInterval now = CACurrentMediaTime();
    io.DeltaTime = (last>0)?(float)(now-last):1.f/60.f;
    if (io.DeltaTime<=0) io.DeltaTime=1.f/60.f;
    last=now;

    // состояние игры + affine — каждый кадр (все на главном потоке, как и игра)
    if (self.menuOpen || g_showLines || g_showDots) {
        g_state   = ReadGameState();
        g_stateOk = true;
    }

    id<MTLCommandBuffer>     cb  = [self.queue commandBuffer];
    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (!rpd) { [cb commit]; return; }

    ImGui_ImplMetal_NewFrame(rpd);
    ImGui::NewFrame();
    if (self.menuOpen) DrawMenuWindow();
    DrawBallLines();
    ImGui::Render();

    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
    [enc pushDebugGroup:@"ImGui"];
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
    [enc popDebugGroup];
    [enc endEncoding];
    [cb presentDrawable:view.currentDrawable];
    [cb commit];

    [self refreshVisibility];
}
@end

// ============================================================
//  Install
// ============================================================

static UIWindow *FindKeyWindow()
{
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene*)s;
        if (ws.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ws.windows) if (w.isKeyWindow) return w;
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

static OverlayView *g_overlay = nil;

static void TryInstall(int attempt)
{
    UIWindow *w = FindKeyWindow();
    if (!w||!w.rootViewController.view) {
        if (attempt<60)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{ TryInstall(attempt+1); });
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
