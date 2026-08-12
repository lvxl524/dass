// dass v1.5 — BioProtectXS × LiquidAss 0.1.0b 兼容适配层（偏好釜底抽薪版）
//
// 本轮结论（LiquidAss 0.1.0b 源码精读 + v4 实机报告双重证据）：
//   1. BioProtect 解锁弹窗出现在【受保护 App 进程内】（崩溃证据全在 WeChat：
//      19:20 WeChat-...-192045.ips = scene-create watchdog 0x8BADF00D，
//      主线程 10s CPU 配额耗尽，栈 = cache_t::shouldFlush ← flushCaches ←
//      method_setImplementation 的运行时 swizzle 风暴），而 LiquidAss 的
//      Alerts.x 只跑 SpringBoard/Preferences —— v1.3/v1.4 的"消毒对抗 Alerts"
//      思路方向错了：v4 trace 证明信号从未命中（无任何 BLOCK START），
//      消毒机制全程空转。
//   2. 0.1.0b 新增的 TabBar.x / Keyboard.x / Spotlight.x / ContextMenu.x 等
//      【全进程组件】会在 BioProtect 锁屏 UI 上持续做样式改造（layoutSubviews
//      递归、keyplane 运行时 class_addMethod/method_setImplementation 等），
//      这是 WeChat 启动阶段 CPU 风暴的来源。
//   3. 釜底抽薪点（已从源码确认）：
//      · lgHostEnabled(prefix) 的第一道门就是
//        LGGlassPreferenceValue(@"Global.Enabled") —— Global.Enabled=NO 时
//        LiquidAss 全部组件（TabBar/Keyboard/Alerts/Clock/CoverSheet/...）
//        的动作全部停止；
//      · Alerts 的 LGAlertsEnabled() = LG_globalEnabled() && ...，
//        LG_globalEnabled() = LG_prefBool(@"Global.Enabled", NO)，同样受门控；
//      · 偏好域 dylv.liquidassprefs（CFPreferences app-domain），
//        LGSharedSupport 与 LGGlassKit 都监听 Darwin 通知
//        "dylv.liquidassprefs/Reload" 刷新各自缓存 —— 写一次偏好 + post 一次
//        通知，全进程同时生效。
//
// v1.5 机制：
//   信号（系统级可靠信号，不再依赖猜 BioProtect 类名）：
//     · %hook LAContext -evaluatePolicy:localizedReason:reply: 与
//       -evaluatePolicy:options:reply: —— 人脸/指纹验证的系统入口，
//       任何进程、任何 App 触发验证都会命中：
//         evaluatePolicy 进入     → BLOCK（写 Global.Enabled=NO + post Reload）
//         reply 回调执行          → RELEASE（恢复 Global.Enabled=YES + post Reload）
//         （成功/失败/用户取消都会回调 reply，天然覆盖整个验证窗口）
//     · 保留 BioProtect 类名辅助信号（UIView didMoveToWindow / UIViewController
//       viewDidAppear/viewDidDisappear / UIAlertView show/dismiss）作为第二层保障
//     · 120s 超时强制释放兜底（极端情况下 reply 未回调时）
//   动作：
//     · BLOCK：CFPreferencesSetValue 把 dylv.liquidassprefs 域 Global.Enabled
//       置 NO（仅当原值为 YES 时才真正写，避免污染用户设置），
//       CFPreferencesAppSynchronize 落盘，post Darwin Reload 通知 →
//       LiquidAss 全进程停摆；随后一次性异步消毒（隐藏已注入的 LGLive/
//       LiquidAss 玻璃视图、恢复被压制的背板 —— 此时 LiquidAss 不会重新注入，
//       消毒安全且干净）
//     · RELEASE：恢复 Global.Enabled=YES + post Reload → LiquidAss 恢复正常
//     · 嵌套验证计数（count++/--，归零才恢复）；多进程各自把 YES→NO→YES，
//       无中间值污染竞态

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#import <stdio.h>
#import <stdarg.h>
#import <pthread.h>
#import <sys/time.h>
#import <unistd.h>

#pragma mark - 常量

#define LGPREFS_DOMAIN      CFSTR("dylv.liquidassprefs")
#define LGPREFS_RELOAD      CFSTR("dylv.liquidassprefs/Reload")
#define KEY_GLOBAL_ENABLED  CFSTR("Global.Enabled")

#pragma mark - 全局状态（gLock 保护）

static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static int gBlockCount = 0;            // 嵌套验证计数
static CFTimeInterval gBlockedSince = 0;
static BOOL gLGPrefsToggled = NO;      // 本进程是否真正把 Global.Enabled YES→NO 切过

#pragma mark - 文件追踪（不依赖 log 命令，v1.4 沿用；线程安全）

static FILE *gTraceFile = NULL;

static void lgTraceOpen(void) {
    if (gTraceFile) return;
    gTraceFile = fopen("/var/mobile/dass_trace.log", "a");
    if (!gTraceFile) {
        NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"dass_trace.log"];
        gTraceFile = fopen(p.UTF8String, "a");
    }
    if (!gTraceFile) return;
    setvbuf(gTraceFile, NULL, _IOLBF, 0);
}

// 调用方必须已持有 gLock
static void lgTraceLocked(const char *fmt, ...) {
    lgTraceOpen();
    if (!gTraceFile) return;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    fprintf(gTraceFile, "[dass %lld.%06lld %s] ",
            (long long)tv.tv_sec, (long long)tv.tv_usec,
            NSProcessInfo.processInfo.processName.UTF8String);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(gTraceFile, fmt, ap);
    va_end(ap);
    fflush(gTraceFile);
    fsync(fileno(gTraceFile));
}

static void lgTrace(const char *fmt, ...) {
    pthread_mutex_lock(&gLock);
    lgTraceOpen();
    if (gTraceFile) {
        struct timeval tv;
        gettimeofday(&tv, NULL);
        fprintf(gTraceFile, "[dass %lld.%06lld %s] ",
                (long long)tv.tv_sec, (long long)tv.tv_usec,
                NSProcessInfo.processInfo.processName.UTF8String);
        va_list ap;
        va_start(ap, fmt);
        vfprintf(gTraceFile, fmt, ap);
        va_end(ap);
        fflush(gTraceFile);
        fsync(fileno(gTraceFile));
    }
    pthread_mutex_unlock(&gLock);
}

#pragma mark - 偏好釜底抽薪（CFPreferences app-domain，调用方需持有 gLock）

static void lgPostReloadLocked(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         LGPREFS_RELOAD, NULL, NULL, TRUE);
}

// 把 Global.Enabled 置 NO。仅当原值为 YES 时才真正写（否则跳过，
// 避免覆盖"用户本来就关着"的状态），并记录本次是否切换。
static void lgPrefsDisableLocked(void) {
    if (gLGPrefsToggled) return;
    CFPreferencesAppSynchronize(LGPREFS_DOMAIN);
    CFPropertyListRef v = CFPreferencesCopyValue(KEY_GLOBAL_ENABLED,
                                                 LGPREFS_DOMAIN,
                                                 kCFPreferencesCurrentUser,
                                                 kCFPreferencesAnyHost);
    BOOL wasOn = (v != NULL && CFGetTypeID(v) == CFBooleanGetTypeID() &&
                  CFBooleanGetValue((CFBooleanRef)v));
    if (v) CFRelease(v);
    if (!wasOn) {
        lgTraceLocked("prefs: Global.Enabled was OFF/absent, skip toggle\n");
        return;
    }
    CFPreferencesSetValue(KEY_GLOBAL_ENABLED, kCFBooleanFalse,
                          LGPREFS_DOMAIN, kCFPreferencesCurrentUser,
                          kCFPreferencesAnyHost);
    CFPreferencesAppSynchronize(LGPREFS_DOMAIN);
    lgPostReloadLocked();
    gLGPrefsToggled = YES;
    lgTraceLocked("prefs: Global.Enabled YES -> NO, Reload posted\n");
}

// 恢复 Global.Enabled=YES。
static void lgPrefsRestoreLocked(void) {
    if (!gLGPrefsToggled) return;
    CFPreferencesSetValue(KEY_GLOBAL_ENABLED, kCFBooleanTrue,
                          LGPREFS_DOMAIN, kCFPreferencesCurrentUser,
                          kCFPreferencesAnyHost);
    CFPreferencesAppSynchronize(LGPREFS_DOMAIN);
    lgPostReloadLocked();
    gLGPrefsToggled = NO;
    lgTraceLocked("prefs: Global.Enabled NO -> YES, Reload posted\n");
}

#pragma mark - 快速类名检测（BioProtect 辅助信号）

static inline BOOL lgNameHas(const char *n, const char *sub) {
    return n && *n && sub && strstr(n, sub) != NULL;
}

static inline BOOL lgIsBioView(UIView *v) {
    const char *n = class_getName(object_getClass(v));
    return lgNameHas(n, "BioProtectBlurView") ||
           lgNameHas(n, "BioAlertView") ||
           strncmp(n, "BioAlert", 8) == 0;
}

static inline BOOL lgIsBioVC(UIViewController *vc) {
    const char *n = class_getName(object_getClass(vc));
    return lgNameHas(n, "BioProtect") || strncmp(n, "BioAlert", 8) == 0;
}

static BOOL lgChainHasBio(UIViewController *vc) {
    for (UIViewController *c = vc; c; c = c.presentingViewController) {
        if (lgIsBioVC(c)) return YES;
    }
    return NO;
}

#pragma mark - 一次性消毒（只在 LiquidAss 被禁用后执行，不会重新注入）

static void lgSanitizeSubtree(UIView *view, int *scan, int *hide, int *restore) {
    if (!view) return;
    for (UIView *sub in [view.subviews copy]) {
        (*scan)++;
        const char *n = class_getName(object_getClass(sub));
        if (lgNameHas(n, "LGLive") || lgNameHas(n, "LiquidAss")) {
            sub.hidden = YES;
            sub.layer.hidden = YES; // layer 直写，绕过任何 setHidden hook 链
            (*hide)++;
            continue;
        }
        if (strcmp(n, "MTMaterialView") == 0 ||
            strcmp(n, "_UIInterfaceActionVibrantSeparatorView") == 0) {
            sub.layer.hidden = NO;
            sub.alpha = 1.0;
            (*restore)++;
            continue;
        }
        if ([sub isKindOfClass:[UIVisualEffectView class]] ||
            lgNameHas(n, "Backdrop")) {
            sub.hidden = NO;
            sub.layer.hidden = NO;
            sub.alpha = 1.0;
            (*restore)++;
        }
        lgSanitizeSubtree(sub, scan, hide, restore);
    }
}

static void lgSanitizeOnce(void) {
    int scan = 0, hide = 0, restore = 0;
    int windowCount = 0;
    UIWindow *best = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        windowCount++;
        if (!best || w.windowLevel > best.windowLevel) best = w;
    }
    if (best) lgSanitizeSubtree(best, &scan, &hide, &restore);
    UIWindow *key = UIApplication.sharedApplication.keyWindow;
    if (key && key != best) lgSanitizeSubtree(key, &scan, &hide, &restore);
    lgTrace("sanitize: windows=%d scan=%d hide=%d restore=%d\n",
            windowCount, scan, hide, restore);
}

static void lgSanitizeOnceAsync(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        lgSanitizeOnce();
    });
}

#pragma mark - 状态切换（BLOCK / RELEASE）

static void lgScheduleTimeout(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        pthread_mutex_lock(&gLock);
        if (gBlockCount > 0 && gBlockedSince > 0 &&
            CACurrentMediaTime() - gBlockedSince > 120.0) {
            lgTraceLocked("TIMEOUT 120s, force release count=%d\n", gBlockCount);
            gBlockCount = 0;
            gBlockedSince = 0;
            lgPrefsRestoreLocked();
        }
        pthread_mutex_unlock(&gLock);
    });
}

static void lgSetBlocked(BOOL blocked, const char *why) {
    pthread_mutex_lock(&gLock);
    if (blocked) {
        gBlockCount++;
        if (gBlockCount == 1) {
            gBlockedSince = CACurrentMediaTime();
            lgTraceLocked("BLOCK START via %s (count=%d)\n", why, gBlockCount);
            lgPrefsDisableLocked();       // Global.Enabled -> NO + Reload
            lgSanitizeOnceAsync();        // 禁用后一次性清理（异步，安全）
            lgScheduleTimeout();
        } else {
            lgTraceLocked("BLOCK ++ via %s (count=%d)\n", why, gBlockCount);
        }
    } else {
        if (gBlockCount > 0) gBlockCount--;
        if (gBlockCount == 0) {
            lgTraceLocked("BLOCK END via %s\n", why);
            gBlockedSince = 0;
            lgPrefsRestoreLocked();       // Global.Enabled -> YES + Reload
        } else {
            lgTraceLocked("BLOCK -- via %s (count=%d)\n", why, gBlockCount);
        }
    }
    pthread_mutex_unlock(&gLock);
}

#pragma mark - LAContext 接口声明（NSInteger 代替 LAPolicy，避免链接 LocalAuthentication）

@class LAContext;

@interface LAContext (LGCompat)
- (void)evaluatePolicy:(NSInteger)policy localizedReason:(NSString *)localizedReason reply:(void (^)(BOOL success, NSError *error))reply;
- (void)evaluatePolicy:(NSInteger)policy options:(NSDictionary *)options reply:(void (^)(BOOL success, NSError *error))reply;
@end

#pragma mark - 信号 hooks

%group LGBlockSignals

// 主信号：人脸/指纹验证系统入口（任何进程、任何 App 触发验证都会命中）
%hook LAContext

- (void)evaluatePolicy:(NSInteger)policy localizedReason:(NSString *)localizedReason reply:(void (^)(BOOL success, NSError *error))reply {
    lgTrace("[LA] evaluatePolicy:%ld reason:%s\n",
            (long)policy, localizedReason ? localizedReason.UTF8String : "(nil)");
    lgSetBlocked(YES, "LAContext");

    void (^wrapped)(BOOL, NSError *) = [reply copy];
    void (^gate)(BOOL, NSError *) = ^(BOOL success, NSError *error) {
        lgTrace("[LA] reply success=%d error=%s\n",
                success, error ? error.localizedDescription.UTF8String : "(nil)");
        lgSetBlocked(NO, "LAContextReply");
        if (wrapped) wrapped(success, error);
    };
    %orig(policy, localizedReason, gate);
}

- (void)evaluatePolicy:(NSInteger)policy options:(NSDictionary *)options reply:(void (^)(BOOL success, NSError *error))reply {
    lgTrace("[LA] evaluatePolicy:%ld options\n", (long)policy);
    lgSetBlocked(YES, "LAContext");

    void (^wrapped)(BOOL, NSError *) = [reply copy];
    void (^gate)(BOOL, NSError *) = ^(BOOL success, NSError *error) {
        lgTrace("[LA] reply success=%d error=%s\n",
                success, error ? error.localizedDescription.UTF8String : "(nil)");
        lgSetBlocked(NO, "LAContextReply");
        if (wrapped) wrapped(success, error);
    };
    %orig(policy, options, gate);
}

%end

// 辅助信号：BioProtect 类名（第二层保障，任何呈现方式都命中）
%hook UIView

- (void)didMoveToWindow {
    %orig;
    if (lgIsBioView(self)) {
        lgTrace("signal didMoveToWindow class=%s window=%d\n",
                class_getName(object_getClass(self)), self.window != nil);
        lgSetBlocked(self.window != nil, "didMoveToWindow");
    }
}

%end

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (lgIsBioVC(self)) {
        lgTrace("signal viewDidAppear class=%s\n", class_getName(object_getClass(self)));
        lgSetBlocked(YES, "viewDidAppear");
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (lgIsBioVC(self)) {
        lgTrace("signal viewDidDisappear class=%s\n", class_getName(object_getClass(self)));
        lgSetBlocked(NO, "viewDidDisappear");
    }
}

%end

%hook UIAlertView

- (void)show {
    if (lgIsBioView((UIView *)self)) {
        lgTrace("signal UIAlertView show class=%s\n", class_getName(object_getClass(self)));
        lgSetBlocked(YES, "alertShow");
    }
    %orig;
}

- (void)dismissWithClickedButtonIndex:(NSInteger)buttonIndex animated:(BOOL)animated {
    if (lgIsBioView((UIView *)self)) {
        lgTrace("signal UIAlertView dismiss class=%s\n", class_getName(object_getClass(self)));
        lgSetBlocked(NO, "alertDismiss");
    }
    %orig(buttonIndex, animated);
}

%end

%end // LGBlockSignals

#pragma mark - 初始化

%ctor {
    lgTrace("ctor: dass v1.5 loaded\n");
    // 无条件初始化：LAContext/UIView/UIViewController/UIAlertView 在所有 UIKit
    // 进程存在，类名检测在非 BioProtect 环境自然 no-op，零副作用。
    %init(LGBlockSignals);
}
