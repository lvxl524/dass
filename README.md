# dass

**BioProtectXS × LiquidAss 兼容适配层**（rootless / Dopamine 2.0，iOS 15+）

## 问题

LiquidAss 0.1.0b 新增的 Alerts hook 在 SpringBoard/Preferences 进程中把所有 `UIAlertController` 弹窗内的 `UIVisualEffectView` / `*Backdrop*` 背板隐藏（`hidden=YES, alpha=0`），并注入 `LGLiveBackdropView` 玻璃层。

BioProtectXS 的解锁弹窗（`BioAlertView`，UIAlertView 子类，经 SBAlertItem/SBAlertManager 呈现）内部就是 UIAlertController —— 背板被隐藏后解锁弹窗的模糊背景直接消失，人脸验证界面无法正常显示。

## 方案（v1.4）

按"人脸验证瞬间暂停 LiquidAss、验证完成后释放"的思路：

1. **信号检测**（父类 hook + 类名检测，任何呈现方式都命中）：
   - `UIView -didMoveToWindow`：`BioAlertView` / `BioProtectBlurView` 出现/消失；
   - `UIViewController` 生命周期：`BioProtect*Controller` 出现/消失（含 App 进程的 `BioProtectedAppExtension`，覆盖 blockingView 遮挡阶段）；
   - `UIAlertView -show/dismiss`：`BioAlert*` 兜底。
   - 信号 hook **只设置全局标志** `gLGBlocked`，不做任何视图操作。
2. **一次性异步消毒**（验证开始 / UIAlertController viewDidAppear / 验证结束，各 `dispatch_async` 一次）：
   - 隐藏所有 `LGLive*` / `LiquidAss*` 玻璃层；
   - 恢复 `MTMaterialView` / `UIVisualEffectView` / `*Backdrop*` / 分隔线可见性与 alpha；
   - 只改属性（hidden/alpha/layer.hidden），绝不增删视图层级；只遍历最顶层 window + keyWindow。
3. **释放**：弹窗消失 → 标志复位 → LiquidAss 恢复正常（单次 300s 超时兜底）。

**v1.4 文件追踪**（本设备 `/usr/bin/log` 与 `/var/jb/usr/bin/log` 均不存在，系统日志通道不可用）：
- 每次 信号 / 消毒 / 释放 / 超时 写一行到 `/var/mobile/dass_trace.log`（沙盒应用自动降级到 `NSHomeDirectory()/dass_trace.log`）；
- 记录触发类名、消毒扫描/隐藏/恢复数量、所在进程名、时间戳；
- 崩溃/被杀前 fsync 落盘，安全模式后 Filza 打开即可查看。
- 测试后把 `dass_trace.log` 内容发回即可定位：信号是否命中、消毒是否执行、LiquidAss 视图是否被隐藏。

**v1.3 活锁修复**（v1.2 出现验证弹窗即 watchdog 超时崩溃）：
- 设备崩溃报告证据：`WeChat-2026-08-12-184512.ips` termination code `0x8BADF00D`（watchdog 主线程超时）+ `WeChat.wakeups_resource`（唤醒次数爆表）→ 主线程活锁。
- 根因：v1.2 的 200ms 持续消毒 timer + `setAlpha:`/`setHidden:` 强制拦截与 LiquidAss 互相拉锯（LiquidAss 隐藏背板 → 我们强制恢复 → LiquidAss 再隐藏 → 再恢复……主线程忙循环）。
- 修复：删除持续消毒 timer；删除全部 `setHidden:`/`setAlpha:` 拦截 hook（与 LiquidAss 零对抗点）；消毒改为事件驱动的一次性异步执行。

**v1.4 仍在排查**：v1.3 实机不再产生崩溃报告（watchdog 已消除）但仍进安全模式，且无新 .ips 崩溃文件 → 疑似 jetsam 内存杀（等待 JetsamEvent 原文件 + v1.4 trace 双重确认）。

非 BioProtect 环境（进程内无 BioProtect 相关类）任何信号都不触发 → 完全透传，零副作用。

## 安装

```sh
# 需要已安装 BioProtectXS (org.mr.bioprotectxs-rootless)
dpkg -i com.lvxl.dass_1.4.0_iphoneos-arm64.deb
killall -9 SpringBoard
```

无需任何设置。

## 构建

```sh
make clean
make package FINALPACKAGE=1
# 产物在 packages/ 目录
```
