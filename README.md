# dass

**BioProtectXS × LiquidAss 兼容适配层**（rootless / Dopamine 2.0，iOS 15+）

## 问题

LiquidAss 0.1.0b（"next level diarrhea"大版本）新增多个全进程 hook 组件。实测证据（v1~v4 设备诊断报告 + 0.1.0b 源码精读）确认：

1. **BioProtect 解锁弹窗出现在受保护 App 进程内**（不是 SpringBoard）——崩溃证据全在 WeChat：`WeChat-2026-08-12-192045.ips` 为 scene-create watchdog `0x8BADF00D`（主线程 10s CPU 配额耗尽），栈为 `cache_t::shouldFlush ← flushCaches ← method_setImplementation` 的运行时 swizzle 风暴。
2. LiquidAss 0.1.0b 的 **Alerts.x 只跑 SpringBoard/Preferences**（`%ctor` 进程门控），与 BioProtect 锁屏无直接交集——v1.3/v1.4 的"消毒对抗 Alerts"思路方向错误：v4 trace 证明信号从未命中（无任何 BLOCK START），消毒机制全程空转。
3. 0.1.0b 新增的 **TabBar.x / Keyboard.x / Spotlight.x / ContextMenu.x 等全进程组件**（无进程门控，加载进 WeChat）在 BioProtect 锁屏 UI 上持续做样式改造（layoutSubviews 递归、keyplane 运行时 `class_addMethod`/`method_setImplementation` 等）——这是启动期 CPU 风暴的来源。

## 釜底抽薪点（源码确认）

- `lgHostEnabled(prefix)`（LGGlassKit.x）第一道门就是 `LGGlassPreferenceValue(@"Global.Enabled")` —— **`Global.Enabled=NO` 时 LiquidAss 全部组件动作停止**；
- Alerts 的 `LGAlertsEnabled()` = `LG_globalEnabled() && ...`，`LG_globalEnabled()` = `LG_prefBool(@"Global.Enabled", NO)`，同样受门控；
- 偏好域 `dylv.liquidassprefs`（CFPreferences app-domain），LGSharedSupport 与 LGGlassKit 都监听 Darwin 通知 `dylv.liquidassprefs/Reload` 刷新缓存——**写一次偏好 + post 一次通知，全进程同时生效**。

## 方案（v1.6）

1. **系统级信号**（人脸/指纹验证的通用系统入口，任何 App 触发验证都会命中，不再依赖猜 BioProtect 类名）：
   - `%hook LAContext -evaluatePolicy:localizedReason:reply:`
   - `-evaluatePolicy:options:reply:`
   - `-evaluateAccessControl:operation:options:reply:`（Secure Enclave 访问控制通道，v1.6 新增——BioProtect 若走该通道，v1.5 的两个变体会漏）
   - 每个变体：进入 → **BLOCK**：`Global.Enabled` 置 NO（仅当原值为 YES 才写，避免污染用户设置）+ `CFPreferencesAppSynchronize` + post `Reload` 通知 → LiquidAss 全进程停摆；reply 回调执行（成功/失败/取消都会回调，天然覆盖整个验证窗口）→ **RELEASE**：恢复 `Global.Enabled=YES` + post `Reload` → LiquidAss 恢复正常。
2. **弹窗取证**（v1.6 新增）：`%hook UIAlertController viewDidAppear:` 记录**每个进程的每个弹窗**——进程名、弹窗类名、title、message、presenting 链全部写入 trace，直接锁定 BioProtect 弹窗的真身（此前所有猜类名方案失败，因为不知道真实类名）；若弹窗类名/呈现链含 BioProtect 特征，同时触发 BLOCK。
3. **一次性异步消毒**：BLOCK 生效后清理已注入的 `LGLive*`/`LiquidAss*` 玻璃视图、恢复被压制的背板——此时 LiquidAss 不会重新注入，消毒安全且干净。
4. **辅助信号**（第二层保障）：BioProtect 类名检测（`UIView didMoveToWindow` / `UIViewController viewDidAppear/viewDidDisappear` / `UIAlertView show/dismiss`）。
5. **嵌套验证计数**（count++/--，归零才恢复）+ **120s 超时强制释放**兜底。

**v1.4 文件追踪**（本设备 `/usr/bin/log` 与 `/var/jb/usr/bin/log` 均不存在，系统日志通道不可用）：
- 每次 信号 / 消毒 / 偏好切换 / 释放 / 超时 写一行到 `/var/mobile/dass_trace.log`（沙盒应用自动降级到 `NSHomeDirectory()/dass_trace.log`）；
- 记录触发类名、消毒扫描/隐藏/恢复数量、所在进程名、时间戳；fsync 落盘，安全模式后 Filza 打开即可查看。

## 版本沿革

- **v1.2 崩溃**：出现验证弹窗即 watchdog 超时崩溃（`WeChat-2026-08-12-184512.ips` `0x8BADF00D` + `wakeups_resource`）→ 200ms 持续消毒 timer + `setAlpha:`/`setHidden:` 拦截与 LiquidAss 拉锯活锁。
- **v1.3 修复**：删除持续 timer 与全部属性拦截 hook（零对抗点），消毒改事件驱动一次性异步 → 不再产生 watchdog 崩溃报告，但仍进安全模式。
- **v1.4 文件追踪**：替换不可用的 log 通道，定位到"信号从未命中、消毒空转"。
- **v1.5 釜底抽薪**：LAContext 系统级信号 + `Global.Enabled` 偏好开关（源码确认门控全部组件）+ Reload 通知，从源头停掉 LiquidAss，而非视图对抗。**实机仍"验证弹窗一出即注销"**——v1.5 只覆盖两个 evaluatePolicy 变体，若 BioProtect 走 `evaluateAccessControl:` 或私有通道则信号落空。
- **v1.6 全变体 + 取证**：LAContext 信号扩至三变体（含 `evaluateAccessControl:`）；新增 UIAlertController 全进程弹窗记录（进程/类名/title/message/呈现链），把 BioProtect 弹窗真身与崩溃进程钉死，同时扩展 BLOCK 触发面。

非 BioProtect 环境（无任何验证触发）完全透传，零副作用。

## 安装

```sh
# 需要已安装 BioProtectXS (org.mr.bioprotectxs-rootless)
dpkg -i com.lvxl.dass_1.6.0_iphoneos-arm64.deb
killall -9 SpringBoard
```

无需任何设置。测试后把 `/var/mobile/dass_trace.log` 内容发回即可确认：`BLOCK START`（LAContext 命中）、`prefs: YES -> NO`（LiquidAss 停摆）、`BLOCK END`（释放恢复）。

## 构建

```sh
make clean
make package FINALPACKAGE=1
# 产物在 packages/ 目录
```
