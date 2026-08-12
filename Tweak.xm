// dass v1.3 — BioProtectXS × LiquidAss 0.1.0b 兼容适配层
//
// v1.3 核心思路（用户方案）：人脸验证（BioProtect 解锁弹窗出现）的瞬间
// 全局阻止 LiquidAss 运行，验证完成（弹窗消失）后释放，LiquidAss 恢复正常。
//
// v1.2 崩溃根因（已从设备崩溃报告定位）：
//   WeChat-2026-08-12-184512.ips：termination code 2343432205 = 0x8BADF00D
//   （watchdog 主线程超时）+ WeChat.wakeups_resource（唤醒次数爆表）
//   → 主线程活锁（livelock）：
//     · 200ms 持续消毒 timer 每 200ms 全 window 树遍历
//     · setAlpha:/setHidden: 强制拦截与 LiquidAss 互相拉锯：
//       LiquidAss 隐藏背板 → 我们强制恢复 1.0/NO → LiquidAss 又隐藏 →
//       我们又恢复……主线程忙循环 → watchdog 杀掉进程。
//
// v1.3 修复原则（消灭一切"持续对抗"）：
//   1. 删除 200ms 消毒 timer（事件驱动，不再轮询）
//   2. 删除全部 setHidden:/setAlpha: 拦截 hook（MTMaterialView /
//      UIVisualEffectView / _UIInterfaceActionVibrantSeparatorView）
//      —— 没有任何与 LiquidAss 的拉锯点
//   3. 消毒改为"一次性异步消毒"：只在三个时机各 dispatch_async 一次
//      · 验证开始（信号触发）
//      · UIAlertController viewDidAppear（LiquidAss 注入玻璃之后，异步必然晚于注入）
//      · 验证结束（信号触发）
//   4. 消毒范围收敛：只遍历最顶层 window + keyWindow（不再全 window 树）
//   5. 消毒只改属性（hidden/alpha/layer.hidden），绝不增删视图层级
//   6. 单次 300s 超时兜底（dispatch_after，非周期 timer）
//
// 时序（弹窗出现）：
//   t0 BioAlertView show / BioProtectBlurView didMoveToWindow → 标志=YES，异步消毒一次
//   t1 内部 UIAlertController viewDidAppear（LiquidAss 注入玻璃层+隐藏背板）
//   t2 我们的 viewDidAppear hook 异步消毒一次（下一 runloop，必然在注入后）
//      → 玻璃层隐藏、背板恢复 → 弹窗正常显示；此后双方都不再动作，无拉锯
//   t3 验证完成 dismiss → 标志=NO，异步最终消毒 → LiquidAss 恢复
//
// 非 BioProtect 环境任何信号都不触发 → 完全透传，零副作用。

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#pragma mark - 全局状态

static BOOL gLGBlocked = NO;          // YES = 人脸验证进行中，LiquidAss 暂停
static CFTimeInterval gBlockedSince = 0;

static void lgSetBlocked(BOOL blocked);

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

#pragma mark - 消毒工具（一次性：只改属性，绝不增删视图层级，绝不轮询）

static void lgSanitizeSubtree(UIView *view) {
    if (!view) return;
    for (UIView *sub in [view.subviews copy]) {
        const char *n = class_getName(object_getClass(sub));
        // 玻璃层：隐藏而非移除（移除会破坏视图树，触发布局递归）
        if (lgNameHas(n, "LGLive") || lgNameHas(n, "LiquidAss")) {
            sub.hidden = YES;
            sub.layer.hidden = YES; // layer 直写，绕过任何 setHidden hook 链
            continue;
        }
        // 私有材质类（MTMaterialView 等）：只 layer 直写恢复。
        // 不走 setHidden: 消息——其 setHidden 可能被 LiquidAss hook 反向压制。
        if (strcmp(n, "MTMaterialView") == 0 ||
            strcmp(n, "_UIInterfaceActionVibrantSeparatorView") == 0) {
            sub.layer.hidden = NO;
            sub.alpha = 1.0;
            continue;
        }
        // 背板/系统模糊层：完整恢复可见性与 alpha
        if ([sub isKindOfClass:[UIVisualEffectView class]] ||
            lgNameHas(n, "Backdrop")) {
            sub.hidden = NO;
            sub.layer.hidden = NO;
            sub.alpha = 1.0;
        }
        lgSanitizeSubtree(sub);
    }
}

// 只消毒最顶层 window + keyWindow（弹窗必然在其中之一）
static void lgSanitizeOnce(void) {
    UIWindow *best = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (!best || w.windowLevel > best.windowLevel) best = w;
    }
    if (best) lgSanitizeSubtree(best);
    UIWindow *key = UIApplication.sharedApplication.keyWindow;
    if (key && key != best) lgSanitizeSubtree(key);
}

// 异步消毒：推迟到主队列下一 runloop，确保不在 UIKit 回调栈内修改视图，
// 也确保晚于 LiquidAss 的同步注入。
static void lgSanitizeOnceAsync(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gLGBlocked && !gBlockedSince) return; // 完全空闲时不遍历
        lgSanitizeOnce();
    });
}

#pragma mark - 超时兜底（单次 dispatch_after，非周期 timer）

static void lgScheduleTimeout(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        if (gLGBlocked && gBlockedSince > 0 &&
            CACurrentMediaTime() - gBlockedSince > 300.0) {
            NSLog(@"[dass v1.3] 验证超时 300s，强制释放");
            lgSetBlocked(NO);
        }
    });
}

#pragma mark - 标志切换（只设标志 + 各消毒一次，无持续动作）

static void lgSetBlocked(BOOL blocked) {
    if (gLGBlocked == blocked) return;
    gLGBlocked = blocked;
    if (blocked) {
        NSLog(@"[dass v1.3] BioProtect 验证开始，暂停 LiquidAss");
        gBlockedSince = CACurrentMediaTime();
        lgSanitizeOnceAsync();
        lgScheduleTimeout();
    } else {
        NSLog(@"[dass v1.3] 验证结束，释放 LiquidAss");
        gBlockedSince = 0;
        lgSanitizeOnceAsync();
    }
}

#pragma mark - 信号 hooks（父类 hook + 类名检测，只设标志）

%group LGBlockSignals

%hook UIView

- (void)didMoveToWindow {
    %orig;
    if (lgIsBioView(self))
        lgSetBlocked(self.window != nil);
}

%end

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (lgIsBioVC(self))
        lgSetBlocked(YES);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (lgIsBioVC(self))
        lgSetBlocked(NO);
}

%end

%hook UIAlertView

- (void)show {
    if (lgIsBioView((UIView *)self)) lgSetBlocked(YES);
    %orig;
}

- (void)dismissWithClickedButtonIndex:(NSInteger)buttonIndex animated:(BOOL)animated {
    if (lgIsBioView((UIView *)self)) lgSetBlocked(NO);
    %orig(buttonIndex, animated);
}

%end

%end // LGBlockSignals

#pragma mark - 兜底 hooks（只有 UIAlertController 一次性异步消毒；无任何属性拦截）

%group LGBlockIntercept

%hook UIAlertController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (gLGBlocked) {
        // 异步消毒：下一 runloop 执行，必然晚于 LiquidAss 的同步注入，
        // 一次性清除玻璃层/恢复背板，之后不再动作（无拉锯）。
        lgSanitizeOnceAsync();
    }
}

%end

%end // LGBlockIntercept

#pragma mark - 初始化

%ctor {
    // 无条件初始化：UIView/UIViewController/UIAlertView 在全部 UIKit 进程存在，
    // hook 内类名检测在非 BioProtect 环境自然 no-op，零副作用；
    // 不依赖 BioProtect dylib 加载顺序（若 dass 先加载，类名检测照样命中）。
    %init(LGBlockSignals);
    %init(LGBlockIntercept);
}
