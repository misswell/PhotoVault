# 快速退出、重新打开后的下拉失效（2026-09-22）

## 根因与证据边界

本轮基线是本地 `8028bef`，工作树开始时干净。代码确认存在以下生命周期重叠路径：

1. A 的系统 Zoom dismissal committed，网格恢复交互。
2. 点击 B，`sync` 把仍在 dismiss 的 A 放入 `retiringSessions`，提前清空 hosted / presentedRequestID 并置 idle。
3. `flushPendingRequest` 用 `presentedViewController == nil || isBeingDismissed` 放行 B。
4. A 的系统 presentation controller 尚未结束，B 已在同一 presenter 上启动呈现。

这是可从代码确认的架构缺陷，与用户描述的新会话长期下拉失效相符。8028bef 增加输入容器和 generation，只解决触摸入口与迟到回调隔离，没有消除这个重叠入口。不能仅凭该路径断言 UIKit 内部 recognizer 如何损坏；需真实失败日志与修复后高频真机手势验收补证。

本次附件中仅找到文字要求，未找到可读取的 IMG_0536.MOV；没有声称已观看视频。旧的回弹触摸入口问题及历史数据保留在 `VIEWER_DISMISS_REENTRY.md`，其中旧策略不再作为当前实现说明。

## 当前实现

- 删除 `retiringSessions`、提前释放 A 的 committed 分支、`isBeingDismissed` 呈现放行和旧重叠日志。
- `ViewerPresentationPhase`（Coordinator 内别名 `PresentationPhase`）：empty → presenting(id) → presented(id) → dismissing(id)；取消 settle 回到 presented(id)，最终 finish 回到 empty。
- 呈现入口同时检查 phase == empty、presentedRequestID == nil、presenter 在 window 内、UIKit presentedViewController == nil；真正 present 前再次断言。
- `ViewerPendingRequests` 只保留最新请求；B 被 C 覆盖，A 仍保持 hosted / session / dismissing。只有旧会话清理且 UIKit 已释放，才消费 C 一次。
- 两套网格在 committed 期间点选新照片不重新锁网格；`onPresentationBegan` 在真正呈现时才恢复网格 inactive 状态。确保等待期间还可以点击 C。
- 系统 interactive 完成通过 `onDismissTransitionFinished(generation)`；程序化路径保留 dismiss completion。finished 必须匹配 session、committed phase 与 committed generation。
- `finishDismissal` 按 session 幂等：恢复输入 → 清 interaction generation → idle → 清 hosted/session → empty → 推进 bridge generation → onDismissed(oldID) → flush。
- viewDidDisappear 在没有等待已注册 transition completion 时才作为 fallback，避免提前结算正常转场；delegate 从旧 controller 自身读取 sessionID，迟到回调不能结清 B，仍可触发 flush。
- completion 内 UIKit 仍占有 presented controller 时，只安排一次 `Task.yield()` 后 flush；没有循环重试、Timer、固定延迟或 debounce。
- 仲裁为 idle=reserve、cancelling=track、dragging/committed=blocked。track 返回 gated，保持 possible；同一笔触摸每次 move 重查，settle 后才 reserve。
- `shouldBeginViewerInteractiveDismiss` 仅返回 `willBegin && !vetoed`；不再按向下速度推翻 UIKit 的 false。
- 保留 `ViewerInteractionContainerView`、系统 Zoom 动画、source cell、aspect-fit alignment、generation 隔离和原有 Reduce Motion 行为。没有切换系统 recognizer 的 enabled 状态。

## 日志与测试

`PhotoVaultLaunch.log` 记录会话 present begin/complete、dismiss begin/commit/transition complete、finish source、pending request、presenter 状态。DEBUG 呈现完成记录系统 Zoom recognizer 的公开 name / enabled / state；每笔向下触摸记录 session、phase、intent、paging 与 Zoom 状态（0=possible）。不调用私有 API。

`-viewer-interruption-probe` 在 presentation completion 后单次让出主线程，然后程序化 dismiss；在真实 dismissal animation 回调中从网格 delegate 点选第 3 张，通过真实 SwiftUI request 更新排队。sync 断言旧会话仍为 dismissing，新 present 断言旧 finish 已发生。它证明动画内请求串行化，不冒充人工触摸。

新增 UI 用例：

- `testRapidDismissReopenKeepsPullDownWorking`：10 轮 A 下拉退出 → 点 B → B 再长拉退出。
- `testRapidCloseReopenKeepsPullDownWorking`：10 轮 A 关闭 → 点 B → B 再长拉退出。
- 保留普通/未整理取消计数、左右分页、右滑、放大平移、网格命中与详情幻灯片等用例。

纯 Swift 脚本直接提取生产策略：12 组 veto、8 组 presentation gate、pending B/C 覆盖、UIKit 占用时禁止消费、消费一次、旧 callback 隔离、5 轮 generation 重入及清理。

XCTest 注入手势会等待 idle，因此即使运行在真机，连续 UI 自动测试也不能证明每次输入落在动画中间。动画内排队由探针单独验证，回弹中人工跟手仍需明确验收。

## 本轮验证记录

- 纯策略测试通过。
- 初轮 interruption probe 在 presentation completion 内同步 dismiss，测试失败；改为单次 MainActor yield 后再触发 probe dismissal。保留首次失败，不作为产品修复通过记录。
- 初轮模拟器 Close → Reopen → PullDown 十轮通过。
- 真机 Debug 编译完成，但首次 XCTest runner 在建立连接前退出 code 74，日志为 `Exiting due to IDE disconnection`，没有执行测试，真机轮数仍为 0。
- 后续最终回归和交付结果在下方追加。

主要命令产物位于 `/tmp/PhotoVault-serial-*`，不会提交编译产物或照片。

## 修改范围

`PhotoViewerPresentationBridge.swift`、`PhotoViewerViews.swift`、`PhotoGridScreen.swift`、`PhotoVaultUITests.swift`、`tools/test-viewer-dismiss-state.swift`、项目 AGENTS.md 和两份说明文档。没有修改照片数据、版本号、签名、系统动画或上传发布配置。
