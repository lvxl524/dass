# dass

**BioProtectXS × LiquidAss 兼容适配层**（rootless / Dopamine 2.0，iOS 15+）

## 问题

LiquidAss 0.1.0b（"next level diarrhea"大版本）导致 BioProtectXS（人脸/指纹应用锁）无法工作：**验证弹窗一出现就注销（安全模式）**。0.0.9a 正常。

## 定案（v1.7，源码 + diag5 实机双重证据）

1. **破坏源 = Alerts.x（0.1.0b 新增）**：对比 0.0.9a 与 0.1.0b 源码，`Hooks/Alerts.x` 在 0.0.9a 中**不存在**——与"0.0.9a 正常、0.1.0b 出问题"完全吻合。它把 SpringBoard 里所有 `UIAlertController` 弹窗的背板隐藏（`hidden/alpha=0`）、注入 `LGLiveBackdropView` 玻璃层、并持续递归改造弹窗子视图（layoutSubviews 钩子），BioProtect 验证弹窗被重创。
2. **Alerts.x 只在 SpringBoard/Preferences 进程生效**（`%ctor` 进程门控）——与 diag5 里 21:27 的 `SpringBoard SIGABRT` 崩溃（触发安全模式）一致。
3. **信号方案为什么失败**：diag5 的 trace 里 v1.5/v1.6 的 `[LA]`/`[ALERT]`/BLOCK **一条都没有**——BioProtect 4.7 走自定义弹窗 + 私有生物识别通道，不走 `LAContext evaluatePolicy` 公开 API，也不经 UIAlertController 呈现。依赖信号的防御从未触发。
4. **精准开关（源码确认）**：`LGAlertsEnabled()` = `lgHostEnabled(@"Alerts")`，读**独立偏好 `Alerts.Enabled`**（默认开）；`lgHostEnabled` 在 `Global.Enabled=YES` 时按 `<prefix>.Enabled` 独立控制各组件。

## 方案（v1.7，无条件防御）

1. **dass 在 SpringBoard/Preferences 进程加载后 2s，无条件把 `Alerts.Enabled` 写 NO + post `dylv.liquidassprefs/Reload` 通知** → LiquidAss 弹窗改造组件彻底停摆（不再隐藏背板/注入玻璃/递归改造）→ **BioProtect 验证弹窗正常显示、不再注销**；
2. **只关 `Alerts.Enabled`，不动 `Global.Enabled`** → LiquidAss 其他美化组件（TabBar/键盘/Spotlight 等）完全不受影响；
3. **保留 LAContext 三变体信号**（`evaluatePolicy:` ×2 + `evaluateAccessControl:`）：万一某验证真走 LAContext，命中时全关 `Global.Enabled` 双保险；验证结束恢复 Global，`Alerts.Enabled` 保持 NO 不回滚；
4. 保留全部取证（UIAlertController 弹窗记录 / BioProtect 类名辅助信号）、嵌套计数、120s 超时兜底、一次性异步消毒。

**文件追踪**（本设备 `/usr/bin/log` 与 `/var/jb/usr/bin/log` 均不存在，系统日志通道不可用）：每次 信号/偏好切换/消毒/释放/超时 写一行到 `/var/mobile/dass_trace.log`（沙盒应用自动降级 `NSHomeDirectory()/dass_trace.log`），fsync 落盘，安全模式后 Filza 可查看。

## 版本沿革

- **v1.2 崩溃**：200ms 持续消毒 timer + 属性拦截与 LiquidAss 拉锯 → watchdog `0x8BADF00D`。
- **v1.3**：删除对抗点 → watchdog 消除，但仍安全模式。
- **v1.4**：文件追踪 → 实锤"信号从未命中、消毒空转"。
- **v1.5**：LAContext 信号 + `Global.Enabled` 釜底抽薪 → 信号未命中，仍注销。
- **v1.6**：LAContext 三变体 + UIAlertController 全进程取证 → diag5 证明信号仍未命中，21:27 SpringBoard SIGABRT。
- **v1.7**：**无条件关闭 `Alerts.Enabled`**（0.1.0b 新增破坏源组件），不再依赖信号。

## 安装

```sh
# 需要已安装 BioProtectXS (org.mr.bioprotectxs-rootless)
dpkg -i com.lvxl.dass_1.7.0_iphoneos-arm64.deb
killall -9 SpringBoard
```

无需任何设置。装好后打开被 BioProtect 锁的 App 触发验证，验证弹窗应正常显示、不注销。测试后把 `/var/mobile/dass_trace.log` 发回确认，应能看到：

```
alerts: Alerts.Enabled -> NO, Reload posted (unconditional guard)   ← 防御生效
```

## 构建

```sh
make clean
make package FINALPACKAGE=1
# 产物在 packages/ 目录
```
