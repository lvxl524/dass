// dass — BioProtectXS × LiquidAss 0.1.0b 兼容适配层
//
// 背景：
//   LiquidAss 0.1.0b 把注入范围从 SpringBoard/Preferences 扩大到全部 UIKit 进程，并新增：
//     · LGGlassKit.x 中 %hook MTMaterialView setHidden: —— 只要该 material 上装了
//       LGLiveBackdropView 玻璃层就强制 hidden=YES；
//     · Hooks/Alerts.x —— 在 SpringBoard/Preferences 中把 UIAlertController 内的
//       UIVisualEffectView / *Backdrop* 视图全部隐藏并把 alpha 置 0，再插入
//       LGLiveBackdropView 玻璃层。
//   BioProtectXS 的解锁界面（BioProtectBlurView / BioProtectUnlockController /
//   UIAlertController 弹窗）大量依赖 UIVisualEffectView + UIBlurEffect 的背板渲染，
//   背板被隐藏后模糊锁屏/解锁弹窗直接“消失”，表现为插件无法工作。
//
// 方案：
//   dass 作为兼容层注入到同样的 UIKit 进程（com.apple.UIKit filter），
//   检测 BioProtect 上下文（类名含 "BioProtect" 的视图/控制器所在的窗口/祖先链），
//   在检测命中时：
//     · 强制 MTMaterialView / UIVisualEffectView / Backdrop 视图可见（hidden=NO）、alpha=1
//       —— 通过 layer.hidden 直写绕过 hook 链，与加载顺序无关；
//     · 剥离 LiquidAss 注入的 LGLiveBackdropView 玻璃层；
//     · UIAlertController 出现/布局时异步恢复其背板。
//   非 BioProtect 上下文完全透传，不影响 LiquidAss 自身功能。

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// 私有类接口声明（运行时按名字查找，SDK 无头文件）
@interface MTMaterialView : UIView @end
@interface _UIInterfaceActionVibrantSeparatorView : UIView @end

#pragma mark - BioProtect 上下文检测

static BOOL bpNameMatches(id obj) {
    if (!obj) return NO;
    NSString *name = NSStringFromClass([obj class]);
    if (!name.length) return NO;
    return [name rangeOfString:@"BioProtect"
                       options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL bpSubtreeContainsBioProtect(UIView *root, NSUInteger *budget) {
    if (!root) return NO;
    if (bpNameMatches(root)) return YES;
    if (*budget == 0) return NO;
    (*budget)--;
    for (UIView *sub in root.subviews) {
        if (bpSubtreeContainsBioProtect(sub, budget)) return YES;
        if (*budget == 0) return NO;
    }
    return NO;
}

static BOOL bpWindowIsProtected(UIWindow *window) {
    if (!window) return NO;
    static NSMapTable<UIWindow *, NSDictionary *> *cache; // weak window -> {t,p}
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMapTable weakToStrongObjectsMapTable];
    });
    NSTimeInterval now = CACurrentMediaTime();
    NSDictionary *entry = [cache objectForKey:window];
    if (entry && now - [entry[@"t"] doubleValue] < 1.0)
        return [entry[@"p"] boolValue];

    NSUInteger budget = 3000;
    BOOL isProtected = bpSubtreeContainsBioProtect(window, &budget);
    if (!isProtected) {
        for (UIViewController *vc = window.rootViewController; vc; vc = vc.presentedViewController) {
            if (bpNameMatches(vc)) { isProtected = YES; break; }
        }
    }
    [cache setObject:@{ @"t": @(now), @"p": @(isProtected) } forKey:window];
    return isProtected;
}

static BOOL bpIsBioProtectContext(UIView *view) {
    if (!view) return NO;
    for (UIView *cur = view; cur; cur = cur.superview) {
        if (bpNameMatches(cur)) return YES;
    }
    return bpWindowIsProtected(view.window);
}

static BOOL bpIsBioProtectAlert(UIAlertController *alert) {
    if (bpNameMatches(alert)) return YES;
    if (bpIsBioProtectContext(alert.view)) return YES;
    for (UIViewController *vc = alert.presentingViewController; vc; vc = vc.presentingViewController) {
        if (bpNameMatches(vc)) return YES;
        if (vc.view && bpIsBioProtectContext(vc.view)) return YES;
    }
    return NO;
}

#pragma mark - 修复工具

static void bpStripLiquidGlass(UIView *root) {
    if (!root) return;
    for (UIView *sub in [root.subviews copy]) {
        NSString *name = NSStringFromClass(sub.class);
        if ([name hasPrefix:@"LGLive"] || [name hasPrefix:@"LiquidAss"]) {
            [sub removeFromSuperview];
            continue;
        }
        bpStripLiquidGlass(sub);
    }
}

static void bpRepairSingle(UIView *view) {
    if (!view) return;
    NSString *name = NSStringFromClass(view.class);
    BOOL relevant = [view isKindOfClass:[UIVisualEffectView class]] ||
                    [name containsString:@"Backdrop"] ||
                    [name isEqualToString:@"MTMaterialView"];
    if (!relevant) return;
    view.hidden = NO;
    view.layer.hidden = NO;
    view.alpha = 1.0;
}

static void bpRepairSubtree(UIView *root) {
    if (!root) return;
    bpRepairSingle(root);
    for (UIView *sub in root.subviews) bpRepairSubtree(sub);
}

static void bpDeferRestoreAlert(UIAlertController *alert) {
    __weak UIAlertController *weakAlert = alert;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = weakAlert;
        UIView *root = a.view;
        if (!root) return;
        bpStripLiquidGlass(root);
        bpRepairSubtree(root);
    });
}

#pragma mark - Hooks

%hook MTMaterialView

- (void)setHidden:(BOOL)hidden {
    BOOL bp = bpIsBioProtectContext((UIView *)self);
    if (bp) {
        hidden = NO;
        self.layer.hidden = NO;
    }
    %orig(hidden);
    if (bp) self.layer.hidden = NO; // 无论 hook 链顺序，最终强制可见
}

- (void)layoutSubviews {
    %orig;
    if (bpIsBioProtectContext((UIView *)self)) {
        self.layer.hidden = NO;
        bpStripLiquidGlass((UIView *)self);
        bpRepairSubtree((UIView *)self);
    }
}

%end

%hook UIVisualEffectView

- (void)setHidden:(BOOL)hidden {
    BOOL bp = bpIsBioProtectContext((UIView *)self);
    if (bp) {
        hidden = NO;
        self.layer.hidden = NO;
    }
    %orig(hidden);
    if (bp) self.layer.hidden = NO;
}

- (void)setAlpha:(CGFloat)alpha {
    BOOL bp = bpIsBioProtectContext((UIView *)self);
    %orig(bp ? 1.0 : alpha);
    if (bp) {
        for (UIView *sub in self.subviews)
            if (sub.alpha < 1.0) sub.alpha = 1.0;
    }
}

- (void)didMoveToWindow {
    %orig;
    if (self.window && bpIsBioProtectContext((UIView *)self))
        bpRepairSubtree((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    if (bpIsBioProtectContext((UIView *)self))
        bpRepairSubtree((UIView *)self);
}

%end

%hook UIAlertController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (bpIsBioProtectAlert((UIAlertController *)self))
        bpDeferRestoreAlert((UIAlertController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (bpIsBioProtectAlert((UIAlertController *)self))
        bpDeferRestoreAlert((UIAlertController *)self);
}

%end

%hook _UIInterfaceActionVibrantSeparatorView

- (void)setHidden:(BOOL)hidden {
    BOOL bp = bpIsBioProtectContext((UIView *)self);
    %orig(bp ? NO : hidden);
}

- (void)setAlpha:(CGFloat)alpha {
    BOOL bp = bpIsBioProtectContext((UIView *)self);
    %orig(bp ? 1.0 : alpha);
}

%end
