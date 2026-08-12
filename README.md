# dass

**BioProtectXS × LiquidAss 兼容适配层**（rootless / Dopamine 2.0，iOS 15+）

## 问题

LiquidAss 0.1.0b 新增的 Alerts hook 在 SpringBoard/Preferences 进程中把所有 `UIAlertController` 弹窗内的 `UIVisualEffectView` / `*Backdrop*` 背板隐藏（`hidden=YES, alpha=0`），并注入 `LGLiveBackdropView` 玻璃层。

BioProtectXS 的解锁弹窗（`BioAlertView`，UIAlertView 子类，经 SBAlertItem/SBAlertManager 呈现）内部就是 UIAlertController —— 背板被隐藏后解锁弹窗的模糊背景直接消失，人脸验证界面无法正常显示。

## 方案（v1.2）

按"人脸验证瞬间暂停 LiquidAss、验证完成后释放"的思路：

1. **信号检测**（父类 hook + 类名检测，任何呈现方式都命中）：
   - `UIView -didMoveToWindow`：`BioAlertView` / `BioProtectBlurView` 出现/消失；
   - `UIViewController` 生命周期：`BioProtect*Controller` 出现/消失（含 App 进程的 `BioProtectedAppExtension`，覆盖 blockingView 遮挡阶段）；
   - `UIAlertView -show/dismiss`：`BioAlert*` 兜底。
   - 信号 hook **只设置全局标志** `gLGBlocked`，不做任何视图操作。
2. **验证期间全局阻止 LiquidAss**：
   - `setHidden:` / `setAlpha:` 拦截：LiquidAss 想隐藏背板时强制恢复（`layer.hidden` 直写，与 hook 链顺序无关）；
   - 持续消毒（200ms timer）：隐藏所有 `LGLive*` / `LiquidAss*` 玻璃层，恢复 `MTMaterialView` / `UIVisualEffectView` / `*Backdrop*` / 分隔线可见性与 alpha。
3. **释放**：弹窗消失 → 标志复位 → LiquidAss 恢复正常（300s 超时兜底防止卡死）。

**v1.2 崩溃修复**（v1.1 出现验证弹窗即进安全模式）：
- 根因：v1.1 在 UIKit 回调栈内（`layoutSubviews` / `didMoveToWindow` / `viewDidAppear`）同步遍历全视图树并修改属性/增删视图，其中 `MTMaterialView -layoutSubviews` 递归消毒触发无限布局递归 → 栈溢出；`removeFromSuperview` 破坏视图树 → UIKit 断言崩溃。
- 修复：消毒全部 `dispatch_async` 推迟到下一 runloop 执行；彻底移除所有 `layoutSubviews` 类 hook；消毒只改属性（hidden/alpha/layer.hidden），绝不增删视图层级；信号 hook 纯设标志。

非 BioProtect 环境（进程内无 BioProtect 相关类）任何信号都不触发 → 完全透传，零副作用。

## 安装

```sh
# 需要已安装 BioProtectXS (org.mr.bioprotectxs-rootless)
dpkg -i com.lvxl.dass_1.2.0_iphoneos-arm64.deb
killall -9 SpringBoard
```

无需任何设置。

## 构建

```sh
make clean
make package FINALPACKAGE=1
# 产物在 packages/ 目录
```
