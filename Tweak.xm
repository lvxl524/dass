// dass v1.1 — BioProtectXS × LiquidAss 0.1.0b 兼容适配层
//
// v1.1 核心思路（用户方案）：人脸验证（BioProtect 解锁弹窗出现）的瞬间
// 全局阻止 LiquidAss 运行，验证完成（弹窗消失）后释放，LiquidAss 恢复正常。
//
// v1.0 失效原因：BioProtect 解锁弹窗是 UIAlertView 子类（BioAlertView），经
// SBAlertItem/SBAlertManager 在 SpringBoard 进程呈现；UIAlertView 在 iOS 8+
// 内部就是 UIAlertController，LiquidAss Alerts.x 的 UIAlertController hook
// 命中后注入 LGLiveBackdropView 玻璃层并把弹窗内所有 UIVisualEffectView /
// *Backdrop* 背板置为 hidden/alpha=0 → 解锁弹窗模糊背景消失。而内部
// UIAlertController 的 presenting 链上没有 "BioProtect" 类（BioProtect 只做
// delegate），v1.0 的类名上下文检测命中不了，恢复逻辑没触发。
//
// v1.1 信号（父类 hook + 类名检测，任何呈现方式都命中）：
//   · UIView -didMoveToWindow   ：BioAlertView / BioProtectBlurView 出现/消失
//   · UIViewController 生命周期 ：BioProtect*Controller 出现/消失（含 App 进程的
//     BioProtectedAppExtension，覆盖 blockingView 遮挡阶段）
//   · UIAlertView -show/dismiss ：BioAlert*（兜底，直接 show 的旧 API）
// 信号触发 → 全局标志 gLGBlocked：
//   · setHidden:/setAlpha: 拦截：阻止 LiquidAss 隐藏背板（强制恢复）
//   · 持续消毒（200ms timer）：剥离 LGLive*/LiquidAss* 玻璃层、
//     恢复 MTMaterialView/UIVisualEffectView/*Backdrop* 可见性与 alpha
// 弹窗消失 → 标志复位 → LiquidAss 恢复正常。
//
// 非 BioProtect 环境（进程内无 BioAlertItem/BioProtectBlurView 等类）任何
// 信号都不会触发 → 完全透传，零副作用。
// 超时兜底：begin 后 300s 无 end 强制释放，防止标志卡死导致 LiquidAss 永久禁用。

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// 私有类接口声明（运行时按名字查找，SDK 无头文件）
@interface MTMaterialView : UIView @end
@interface _UIInterfaceActionVibrantSeparatorView : UIView @end

#pragma mark - 全局状态

static BOOL gLGBlocked = NO;          // YES = 人脸验证进行中，LiquidAss 暂停
static dispatch_source_t gSanitizeSource; // 消毒 timer
static CFTimeInterval gBlockedSince = 0;

static void lgSetBlocked(BOOL blocked);

#pragma mark - 消毒工具

static void lgSanitizeSubtree(UIView *view) {
    if (!view) return;
    for (UIView *sub in [view.subviews copy]) {
        NSString *name = NSStringFromClass(sub.class);
        // 剥离 LiquidAss 注入的玻璃层
        if ([name hasPrefix:@"LGLive"] || [name hasPrefix:@"LiquidAss"]) {
            [sub removeFromSuperview];
            continue;
        }
        // 恢复被 LiquidAss 抑制的背板/材质/分隔线
        if ([sub isKindOfClass:[UIVisualEffectView class]] ||
            [name containsString:@"Backdrop"] ||
            [name isEqualToString:@"MTMaterialView"] ||
            [name isEqualToString:@"_UIInterfaceActionVibrantSeparatorView"]) {
            sub.hidden = NO;
            sub.layer.hidden = NO; // layer 直写，绕过任何 hook 链
            sub.alpha = 1.0;
        }
        lgSanitizeSubtree(sub);
    }
}

static void lgSanitizeAll(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows)
        lgSanitizeSubtree(window);
}

#pragma mark - 消毒 timer

static void lgStopSanitizeTimer(void) {
    if (gSanitizeSource) {
        dispatch_source_cancel(gSanitizeSource);
        gSanitizeSource = nil;
    }
}

static void lgStartSanitizeTimer(void) {
    if (gSanitizeSource) return;
    dispatch_source_t source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(source,
        dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
        200 * NSEC_PER_MSEC, 0);
    dispatch_source_set_event_handler(source, ^{
        // 超时兜底：300s 无结束信号，强制释放
        if (gBlockedSince > 0 &&
            CACurrentMediaTime() - gBlockedSince > 300.0) {
            lgSetBlocked(NO);
            return;
        }
        if (!gLGBlocked) {
            lgStopSanitizeTimer();
            return;
        }
        lgSanitizeAll();
    });
    dispatch_resume(source);
    gSanitizeSource = source;
}

static void lgSetBlocked(BOOL blocked) {
    if (gLGBlocked == blocked) return;
    gLGBlocked = blocked;
    if (blocked) {
        gBlockedSince = CACurrentMediaTime();
        lgSanitizeAll();        // 立即消毒一次
        lgStartSanitizeTimer(); // 持续消毒，直到释放
    } else {
        gBlockedSince = 0;
        lgStopSanitizeTimer();
        lgSanitizeAll();        // 最终消毒，确保释放后界面干净
    }
}

#pragma mark - 信号 hooks（父类 hook + 类名检测）

%group LGBlockSignals

%hook UIView

- (void)didMoveToWindow {
    %orig;
    NSString *name = NSStringFromClass(self.class);
    if ([name containsString:@"BioProtectBlurView"] ||
        [name containsString:@"BioAlertView"] ||
        [name hasPrefix:@"BioAlert"]) {
        lgSetBlocked(self.window != nil);
    }
}

%end

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *name = NSStringFromClass(self.class);
    if ([name containsString:@"BioProtect"] ||
        [name hasPrefix:@"BioAlert"])
        lgSetBlocked(YES);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    NSString *name = NSStringFromClass(self.class);
    if ([name containsString:@"BioProtect"] ||
        [name hasPrefix:@"BioAlert"])
        lgSetBlocked(NO);
}

%end

%hook UIAlertView

- (void)show {
    NSString *name = NSStringFromClass(self.class);
    if ([name containsString:@"Bio"]) lgSetBlocked(YES);
    %orig;
}

- (void)dismissWithClickedButtonIndex:(NSInteger)buttonIndex animated:(BOOL)animated {
    NSString *name = NSStringFromClass(self.class);
    if ([name containsString:@"Bio"]) lgSetBlocked(NO);
    %orig(buttonIndex, animated);
}

%end

%end // LGBlockSignals

#pragma mark - 拦截 hooks（所有 UIKit 进程，gLGBlocked 为 NO 时纯透传）

%hook MTMaterialView

- (void)setHidden:(BOOL)hidden {
    if (gLGBlocked) {
        hidden = NO;
        self.layer.hidden = NO;
    }
    %orig(hidden);
    if (gLGBlocked) self.layer.hidden = NO; // 无论 hook 链顺序，最终强制可见
}

- (void)layoutSubviews {
    %orig;
    if (gLGBlocked) {
        self.layer.hidden = NO;
        lgSanitizeSubtree((UIView *)self);
    }
}

%end

%hook UIVisualEffectView

- (void)setHidden:(BOOL)hidden {
    if (gLGBlocked) {
        hidden = NO;
        self.layer.hidden = NO;
    }
    %orig(hidden);
    if (gLGBlocked) self.layer.hidden = NO;
}

- (void)setAlpha:(CGFloat)alpha {
    %orig(gLGBlocked ? 1.0 : alpha);
}

%end

%hook _UIInterfaceActionVibrantSeparatorView

- (void)setHidden:(BOOL)hidden {
    %orig(gLGBlocked ? NO : hidden);
}

- (void)setAlpha:(CGFloat)alpha {
    %orig(gLGBlocked ? 1.0 : alpha);
}

%end

%hook UIAlertController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (gLGBlocked) {
        // 异步消毒，确保在 LiquidAss 的 viewDidAppear 注入之后执行
        dispatch_async(dispatch_get_main_queue(), ^{ lgSanitizeAll(); });
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (gLGBlocked) {
        dispatch_async(dispatch_get_main_queue(), ^{ lgSanitizeAll(); });
    }
}

%end

#pragma mark - 初始化

%ctor {
    // 无条件初始化：UIView/UIViewController/UIAlertView 在全部 UIKit 进程存在，
    // hook 内类名检测在非 BioProtect 环境自然 no-op，零副作用；
    // 不依赖 BioProtect dylib 加载顺序（若 dass 先加载，类名检测照样命中）。
    %init(LGBlockSignals);
    // 拦截 hooks 无条件生效（gLGBlocked=NO 时纯透传）
}
