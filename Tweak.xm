// dass v1.4 — BioProtectXS × LiquidAss 0.1.0b 兼容适配层（文件追踪版）
//
// 方案（用户确认）：人脸验证（BioProtect 解锁弹窗出现）的瞬间全局暂停
// LiquidAss，验证完成（弹窗消失）后释放，LiquidAss 恢复正常。
//
// v1.2 崩溃根因（已从设备崩溃报告定位）：
//   WeChat-2026-08-12-184512.ips termination 2343432205 = 0x8BADF00D（watchdog
//   主线程超时）+ WeChat.wakeups_resource（唤醒爆表）→ 主线程活锁：
//   200ms 持续消毒 timer + setAlpha:/setHidden: 强制拦截与 LiquidAss 拉锯。
//
// v1.3 修复：删除持续 timer、删除全部属性拦截 hook（零对抗点）、
//   消毒改事件驱动一次性异步（验证开始 / UIAlertController viewDidAppear /
//   验证结束各一次），只改属性不增删视图，只遍历最顶层 window+keyWindow。
//   实机结果：不再产生崩溃报告（watchdog 已消除），但仍进安全模式，
//   且无 .ips 崩溃文件 → 疑似 jetsam 内存杀（待 JetsamEvent 原文件确认）。
//
// v1.4 变更（本版）：文件追踪，不依赖 log 命令（本设备 /usr/bin/log 与
//   /var/jb/usr/bin/log 均不存在，系统日志通道不可用）。
//   · 每次 信号 / 消毒 / 释放 / 超时 写一行到磁盘：
//     /var/mobile/dass_trace.log（SpringBoard/系统进程）
//     NSHomeDirectory()/dass_trace.log（沙盒应用自动降级到此）
//   · 消毒带计数器（扫描/隐藏/恢复数量），信号带触发类名
//   · 除追踪外，v1.3 时序逻辑完全不变（不引入任何新的对抗点）

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <stdarg.h>
#import <sys/time.h>
#import <unistd.h>

#pragma mark - 全局状态

static BOOL gLGBlocked = NO;          // YES = 人脸验证进行中，LiquidAss 暂停
static CFTimeInterval gBlockedSince = 0;
static int gScanCount = 0, gHideCount = 0, gRestoreCount = 0;

static void lgSetBlocked(BOOL blocked, const char *why);

#pragma mark - 文件追踪（不依赖 log 命令）

static FILE *gTraceFile = NULL;

static void lgTraceOpen(void) {
    if (gTraceFile) return;
    // 优先系统可写路径（SpringBoard/守护进程）；沙盒应用 fopen 失败自动降级
    gTraceFile = fopen("/var/mobile/dass_trace.log", "a");
    if (!gTraceFile) {
        NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"dass_trace.log"];
        gTraceFile = fopen(p.UTF8String, "a");
    }
    if (!gTraceFile) return;
    setvbuf(gTraceFile, NULL, _IOLBF, 0); // 行缓冲，逐行可读
}

static void lgTrace(const char *fmt, ...) {
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
    fsync(fileno(gTraceFile)); // 崩溃/被杀前确保落盘
}

#pragma mark - 快速类名检测（C 函数，避免高频路径的 NSString 分配）

static inline BOOL lgNameHas(const char *n, const char *sub) {
    return n && *n && sub && strstr(n, sub) != NULL;
}

// BioProtect 解锁弹窗相关视图类
static inline BOOL lgIsBioView(UIView *v) {
    const char *n = class_getName(object_getClass(v));
    return lgNameHas(n, "BioProtectBlurView") ||
           lgNameHas(n, "BioAlertView") ||
           strncmp(n, "BioAlert", 8) == 0;
}

// BioProtect 控制器类（含 App 进程的 BioProtectedAppExtension）
static inline BOOL lgIsBioVC(UIViewController *vc) {
    const char *n = class_getName(object_getClass(vc));
    return lgNameHas(n, "BioProtect") || strncmp(n, "BioAlert", 8) == 0;
}

// 沿 presenting 链找 BioProtect 类（用于判断弹窗归属，少量对象开销小）
static BOOL lgChainHasBio(UIViewController *vc) {
    for (UIViewController *c = vc; c; c = c.presentingViewController) {
        if (lgIsBioVC(c)) return YES;
    }
    return NO;
}

#pragma mark - 消毒工具（一次性：只改属性，绝不增删视图层级，绝不轮询）

static void lgSanitizeSubtree(UIView *view) {
    if (!view) return;
    for (UIView *sub in [view.subviews copy]) {
        gScanCount++;
        const char *n = class_getName(object_getClass(sub));
        // 玻璃层：隐藏而非移除（移除会破坏视图树，触发布局递归）
        if (lgNameHas(n, "LGLive") || lgNameHas(n, "LiquidAss")) {
            sub.hidden = YES;
            sub.layer.hidden = YES; // layer 直写，绕过任何 setHidden hook 链
            gHideCount++;
            if (gHideCount <= 20) lgTrace("hide LiquidAss view: %s\n", n);
            continue;
        }
        // 私有材质类（MTMaterialView 等）：只 layer 直写恢复。
        // 不走 setHidden: 消息——其 setHidden 可能被 LiquidAss hook 反向压制。
        if (strcmp(n, "MTMaterialView") == 0 ||
            strcmp(n, "_UIInterfaceActionVibrantSeparatorView") == 0) {
            sub.layer.hidden = NO;
            sub.alpha = 1.0;
            gRestoreCount++;
            continue;
        }
        // 背板/系统模糊层：完整恢复可见性与 alpha
        if ([sub isKindOfClass:[UIVisualEffectView class]] ||
            lgNameHas(n, "Backdrop")) {
            sub.hidden = NO;
            sub.layer.hidden = NO;
            sub.alpha = 1.0;
            gRestoreCount++;
        }
        lgSanitizeSubtree(sub);
    }
}

// 只消毒最顶层 window + keyWindow（弹窗必然在其中之一）
static void lgSanitizeOnce(void) {
    gScanCount = gHideCount = gRestoreCount = 0;
    int windowCount = 0;
    UIWindow *best = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        windowCount++;
        if (!best || w.windowLevel > best.windowLevel) best = w;
    }
    if (best) lgSanitizeSubtree(best);
    UIWindow *key = UIApplication.sharedApplication.keyWindow;
    if (key && key != best) lgSanitizeSubtree(key);
    lgTrace("sanitize: windows=%d scan=%d hide=%d restore=%d\n",
            windowCount, gScanCount, gHideCount, gRestoreCount);
}

// 异步消毒：推迟到主队列下一 runloop，确保不在 UIKit 回调栈内修改视图，
// 也确保晚于 LiquidAss 的同步注入。
static void lgSanitizeOnceAsync(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gLGBlocked && !gBlockedSince) {
            lgTrace("sanitize skipped (idle)\n");
            return;
        }
        lgSanitizeOnce();
    });
}

#pragma mark - 超时兜底（单次 dispatch_after，非周期 timer）

static void lgScheduleTimeout(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        if (gLGBlocked && gBlockedSince > 0 &&
            CACurrentMediaTime() - gBlockedSince > 300.0) {
            lgTrace("TIMEOUT 300s, force release\n");
            lgSetBlocked(NO, "timeout");
        }
    });
}

#pragma mark - 标志切换（只设标志 + 各消毒一次，无持续动作）

static void lgSetBlocked(BOOL blocked, const char *why) {
    if (gLGBlocked == blocked) return;
    gLGBlocked = blocked;
    if (blocked) {
        lgTrace("BLOCK START via %s\n", why);
        gBlockedSince = CACurrentMediaTime();
        lgSanitizeOnceAsync();
        lgScheduleTimeout();
    } else {
        lgTrace("BLOCK END\n");
        gBlockedSince = 0;
        lgSanitizeOnceAsync();
    }
}

#pragma mark - 信号 hooks（父类 hook + 类名检测，只设标志）

%group LGBlockSignals

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

#pragma mark - 兜底 hooks（只有 UIAlertController 一次性异步消毒；无任何属性拦截）

%group LGBlockIntercept

%hook UIAlertController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    BOOL bioChain = lgChainHasBio(self);
    if (gLGBlocked || bioChain) {
        lgTrace("alert didAppear class=%s blocked=%d bioChain=%d\n",
                class_getName(object_getClass(self)), gLGBlocked, bioChain);
        // 异步消毒：下一 runloop 执行，必然晚于 LiquidAss 的同步注入，
        // 一次性清除玻璃层/恢复背板，之后不再动作（无拉锯）。
        lgSanitizeOnceAsync();
    }
}

%end

%end // LGBlockIntercept

#pragma mark - 初始化

%ctor {
    lgTrace("ctor: dass v1.4 loaded\n");
    // 无条件初始化：UIView/UIViewController/UIAlertView 在全部 UIKit 进程存在，
    // hook 内类名检测在非 BioProtect 环境自然 no-op，零副作用；
    // 不依赖 BioProtect dylib 加载顺序（若 dass 先加载，类名检测照样命中）。
    %init(LGBlockSignals);
    %init(LGBlockIntercept);
}
