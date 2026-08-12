# dass

**BioProtectXS × LiquidAss 兼容适配层**（rootless / Dopamine 2.0，iOS 15+）

## 问题

LiquidAss 0.1.0b 将注入范围从 SpringBoard/Preferences 扩大到全部 UIKit 进程，并新增了两处与 BioProtectXS 冲突的行为：

1. `MTMaterialView setHidden:` 在装有玻璃层时强制 `hidden=YES`；
2. Alerts hook 在 SpringBoard/Preferences 中把 `UIAlertController` 内的 `UIVisualEffectView` / `*Backdrop*` 背板全部隐藏、alpha 置 0，并注入 `LGLiveBackdropView` 玻璃层。

BioProtectXS 的模糊锁屏与解锁弹窗依赖 `UIVisualEffectView + UIBlurEffect` 背板，背板被隐藏后解锁界面直接无法显示。

## 方案

`dass` 注入到同样的 UIKit 进程（`com.apple.UIKit`），检测 BioProtect 上下文（类名含 `BioProtect` 的视图/控制器所在的窗口/祖先链）：

- 强制 `MTMaterialView` / `UIVisualEffectView` / `*Backdrop*` 视图可见（`hidden=NO`）、`alpha=1`，通过 `layer.hidden` 直写绕过 hook 链，与 dylib 加载顺序无关；
- 剥离 LiquidAss 注入的 `LGLiveBackdropView` 玻璃层；
- `UIAlertController` 出现/布局时异步恢复其背板。

非 BioProtect 上下文完全透传，不影响 LiquidAss 自身功能。

## 安装

```sh
# 需要已安装 BioProtectXS (org.mr.bioprotectxs-rootless)
dpkg -i com.lvxl.dass_1.0.0_iphoneos-arm64.deb
killall -9 SpringBoard
```

无需任何设置。

## 构建

```sh
make clean
make package FINALPACKAGE=1
# 产物在 packages/ 目录
```
