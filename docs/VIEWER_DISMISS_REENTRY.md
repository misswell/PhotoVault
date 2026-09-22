# 详情页连续下拉修复与验证（2026-09-22）

## 已确认的根因

真机 BENG 连续三轮人工复现表明，仅放开方向仲裁、增加 generation、覆盖 `willBegin=false`，不足以解决这次无响应。

第二笔触摸在第一轮回弹期间命中 `UITransitionView`，没有进入查看器。进一步诊断证实，此时查看器根视图 `isUserInteractionEnabled=false`，而系统 Zoom 下拉 recognizer 仍然启用。触摸目标在落指时确定，所以即使回弹稍后结束，同一笔拖动仍留在转场容器上，整笔没有响应。

真机实际记录（修复根容器前，非合成探针）：

```text
1790053219.970859 viewer_touch_delivery stage=began
  active=Optional(1),cancelling=Optional(1)
  chain=UITransitionView(enabled=true)
  viewer=enabled=false,hidden=false,alpha=1.0,hit=nil
  ZoomInteractiveDismissSwipeDown:0:enabled=true
```

`.overFullScreen` 改成 `.fullScreen` 后真机仍复现，因此已恢复 `.overFullScreen`，不保留无效的呈现方式变更。

## 最终实现

- `PhotoViewerPresentationBridge.swift`：用应用拥有的 `ViewerInteractionContainerView` 作为呈现控制器根视图，以标准 child containment 嵌入原有 `UIHostingController`。可取消的 interactive generation 活跃时，根容器拒绝把自身交互关闭；提交后解除保护，沿用原有网格恢复和 outgoing viewer 禁用逻辑。没有修改系统 Zoom 动画，没有 Timer、固定延迟、动画快进、私有 API 或自定义退出动画。
- `PhotoViewerTransitionState`：`idle/cancelling` 允许方向仲裁，`dragging/committed` 不重复仲裁。保留当前工作区已有的每次 move 重查门控、touch-down 不因相位直接失败的修复。
- HostingController：`ViewerDismissInteraction` 用递增 `UInt64` 标记每轮交互；分别保存 active/cancelling token。取消决定不清 active；settle 必须同时匹配两者。旧取消、旧提交、旧 completion 不影响新一轮。`viewDidAppear` 只结算仍匹配的 cancellation；消失时清理 token。
- Bridge：所有生命周期回调先核对查看器 session，再核对 interaction generation。允许 `cancelling → interactive(new generation)`；cancelled 只接受匹配 generation 的 cancelling 阶段；程序化关闭仍等当前交互结算。
- 退出判断：`!vetoed && (willBegin || (dy > 0 && dy >= abs(dx) * 1.15))`。没有最低速度阈值；横向/零速度不能独立覆盖 UIKit 判断；缩放和平移、正在翻页的 veto 优先。
- 系统 Zoom、当前照片对应的 source cell、alignment rect、dimming、胶片分页、关闭入口和 Reduce Motion 分支保留。根容器转发状态栏和 Home Indicator 等子控制器决策。
- `PhotoVaultUITests.swift`：说明串行 XCTest 手势只验证端到端取消回归；未整理用例加入连续三次真实取消计数后再长拉退出。
- `tools/test-viewer-dismiss-state.swift`：从生产源文件提取纯策略并执行，不复制第二套实现。项目没有 `PhotoVaultTests` 单元测试 target，因此未改项目结构新增 target。

## 测试与证据

纯逻辑测试已通过：12 组方向/veto 输入，旧取消/提交/completion、未收到取消决定时的 appearance、正常 settle、五轮重入、session 清理。

DEBUG 模式另直接调用生产 Bridge handlers，验证旧 generation 1 的回调不能清掉 interactive generation 2，以及 generation 2 commit、正常取消和幂等结算。其日志明确标记 `synthetic=true`，不能作为真机 mid-bounce 手势成功的证据。

回弹时新增实际 `window.hitTest` 探针，并在 UIKit 尝试禁用根容器时检查命中。它验证触摸入口，不声称替代真实用户中途下拉。

已完成：

- 根容器修复后的完整 `PhotoViewerDismissUITests`：16 项通过，0 失败（309.503 秒）。覆盖关闭、下拉、取消、左右翻页、斜向仲裁、放大平移、退出后命中、快速重开以及未整理退出。
- 补充实际命中断言后，普通详情页五次取消通过。两项详情页幻灯片自动推进回归通过。
- 新增未整理三次取消用例首轮出现一次第二笔未启动系统 recognizer 的失败；相同代码独立复跑通过，随后连续三轮全部通过（81.634 秒），即后续四轮通过。首次失败时根视图 enabled=true、触摸已到照片，没有重现根视图禁用的原始原因；保留该不稳定记录，不以复跑抹去失败。普通五次取消和未整理三次取消的实际命中断言均通过。
- Debug iOS 真机目标构建成功，保留既有版本 1.0（34），没有上传、提交或推送。

修复后的真实模拟器转场日志（不是 generation 合成探针）：

```text
viewer_cancel_hit_test stage=preserved active=Optional(1) cancelling=nil
  enabled=true reached=true hit=_UIHostingView<AnyView>
viewer_cancel_hit_test stage=cancelling active=Optional(1) cancelling=Optional(1)
  enabled=true reached=true hit=_UIHostingView<AnyView>
```

限制：用户离开后 BENG 断开，最终根容器版本尚未安装到真机。之前已安装的三轮版本均被用户复现为仍失败；不能把那些安装记录当作最终修复交付。当前没有最终版本的真机 `generation=2 reentered` 实际手势日志，因此真机 mid-bounce 接管仍未验收。

验证产物（本机临时目录）：

- `/tmp/PhotoVault-dismiss-container-sim.xcresult`：完整 16 项通过。
- `/tmp/PhotoVault-dismiss-final-probes.xcresult`：新增普通命中探针、两项幻灯片通过；含未整理首次失败。
- `/tmp/PhotoVault-dismiss-unsorted-diagnosis.xcresult`：未整理独立复跑通过。
- `/tmp/PhotoVault-dismiss-unsorted-repeat.xcresult`：未整理连续三轮通过。
- `/tmp/PhotoVault-dismiss-final-hit-tests.log`：实际转场命中记录。
- `/tmp/PhotoVault-dismiss-container-final-build.log`：最终逻辑的 Debug iOS 构建成功。
- `/tmp/PhotoVault-dismiss-generation-device/Build/Products/Debug-iphoneos/PhotoVault.app`：待真机复测的构建。

本轮只新增/修改上述 bridge、UI 用例、纯逻辑测试脚本和本文档。原有 `AGENTS.md`、项目版本/Info.plist、`PhotoViewerViews.swift` 工作区改动均保留；没有提交或推送。

## 复验方式

```sh
swift tools/test-viewer-dismiss-state.swift
xcodebuild test -project PhotoVault.xcodeproj -scheme PhotoVault \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' \
  -only-testing:PhotoVaultUITests/PhotoViewerDismissUITests
```

真机启动参数 `-viewer-cancel-reentry-probe` 启用被动触摸诊断、实际命中断言和 generation 逻辑探针。普通详情页、未整理详情页分别执行：短拉取消 → 回弹中立即再拉，连续 3–5 次，最后长拉退出；同时核对取消后左右分页与放大后平移。

日志位于 App 容器 `Library/Caches/PhotoVaultDiagnostics.log` 和 `PhotoVaultLaunch.log`。只有不含 `synthetic=true` 的实际 `reentered`/旧 completion 被忽略序列，加上人工跟手确认，才能认定真机中途接管已经完整验收。

Apple 对系统 Zoom 连续交互和生命周期的说明：[WWDC24 — Enhance your UI animations and transitions](https://developer.apple.com/videos/play/wwdc2024/10145/)。本次根因依据本项目真机日志确认，未将文档对系统能力的描述当成修复通过的证据。
