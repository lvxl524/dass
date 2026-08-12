// dass v1.2 — BioProtectXS × LiquidAss 0.1.0b 兼容适配层
//
// v1.2 核心思路（用户方案）：人脸验证（BioProtect 解锁弹窗出现）的瞬间
// 全局阻止 LiquidAss 运行，验证完成（弹窗消失）后释放，LiquidAss 恢复正常。
//
// v1.1 安全模式崩溃根因（已定位）：
//   · MTMaterialView layoutSubviews 内递归遍历+修改视图属性 → 触发子视图
//     重新布局 → 再次进入本 hook → 无限递归栈溢出；UIKit 另抛
//     "Layout still needs update after calling -[super layoutSubviews]"
//   · didMoveToWindow / viewDidAppear 回调栈内同步 lgSanitizeAll 全树消毒：
//     视图树正在变化时遍历并修改属性
//   · lgSanitizeSubtree 内 removeFromSuperview：遍历中增删视图层级，
//     破坏视图树/约束/观察者 → UIKit 断言崩溃
//   → BioProtect 弹窗一出现即 SpringBoard 崩溃 → 安全模式。
//
// v1.2 修复原则：
//   1. 信号 hook 只设置全局标志（lgSetBlocked），不做任何视图操作
//   2. 一切视图消毒 dispatch_async 到主队列下一 runloop 执行（视图树稳定后）
//   3. 彻底移除所有 layoutSubviews / viewDidLayoutSubviews hook
//      （布局回调内零副作用）
//   4. 消毒只改属性（hidden/alpha/layer.hidden），绝不 add/remove 视图层级
//   5. 高频检测路径用 C 函数（class_getName/strstr）替代 NSString，降低开销
//
// 时序（弹窗出现）：
//   t0 BioAlertView show / BioProtectBlurView didMoveToWindow → 标志=YES，起 timer
//   t1 内部 UIAlertController viewDidAppear（LiquidAss 注入玻璃层+隐藏背板）
//   t2 下一 runloop 异步消毒（隐藏 LGLive*/LiquidAss* 玻璃、恢复背板）→ 弹窗正常
//   t3 验证完成 dismiss → 标志=NO，停 timer，异步最终消毒 → LiquidAss 恢复
//
// 非 BioProtect 环境任何信号都不触发 → 完全透传，零副作用。
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

#pragma mark - 消毒工具（只改属性，绝不增删视图层级）

static void lgSanitizeSubtree(UIView *view) {
    if (!view) return;
    for (UIView *sub in [view.subviews copy]) {
        const char *n = class_getName(object_getClass(sub));
        // 玻璃层：隐藏而非移除（移除会破坏视图树，触发布局递归）
        if (lgNameHas(n, "LGLive") || lgNameHas(n, "LiquidAss")) {
            sub.hidden = YES;
            sub.layer.hidden = YES; // layer 直写，绕过任何 hook 链
            continue;
        }
        // 恢复被 LiquidAss 抑制的背板/材质/分隔线
        if ([sub isKindOfClass:[UIVisualEffectView class]] ||
            lgNameHas(n, "Backdrop") ||
            strcmp(n, "MTMaterialView") == 0 ||
            strcmp(n, "_UIInterfaceActionVibrantSeparatorView") == 0) {
            sub.hidden = NO;
            sub.layer.hidden = NO;
            sub.alpha = 1.0;
        }
        lgSanitizeSubtree(sub);
    }
}

static void lgSanitizeAll(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows)
        lgSanitizeSubtree(window);
}

// 异步消毒：推迟到主队列下一 runloop，确保不在 UIKit 回调栈内修改视图
static void lgSanitizeAllAsync(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        lgSanitizeAll();
    });
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
        lgSanitizeAllAsync();
    });
    dispatch_resume(source);
    gSanitizeSource = source;
}

// 只设置标志 + 管理 timer；不在这里做任何视图操作
static void lgSetBlocked(BOOL blocked) {
    if (gLGBlocked == blocked) return;
    gLGBlocked = blocked;
    if (blocked) {
        NSLog(@"[dass v1.2] BioProtect 验证开始，暂停 LiquidAss");
        gBlockedSince = CACurrentMediaTime();
        lgStartSanitizeTimer();
    } else {
        NSLog(@"[dass v1.2] 验证结束，释放 LiquidAss");
        gBlockedSince = 0;
        lgStopSanitizeTimer();
        lgSanitizeAllAsync(); // 最终消毒，确保释放后界面干净
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

#pragma mark - 拦截 hooks（属性级拦截，gLGBlocked 为 NO 时纯透传）

%group LGBlockIntercept

%hook MTMaterialView

- (void)setHidden:(BOOL)hidden {
    if (gLGBlocked) {
        hidden = NO;
        self.layer.hidden = NO;
    }
    %orig(hidden);
    if (gLGBlocked) self.layer.hidden = NO; // 无论 hook 链顺序，最终强制可见
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
        // 异步消毒：确保在 LiquidAss 的 viewDidAppear 注入之后执行
        lgSanitizeAllAsync();
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
