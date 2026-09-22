# 详情页改为导航式 Fluid Zoom 转场（2026-09-22）

> 本文描述当前实现。旧的两份说明——[串行呈现修复](VIEWER_SERIAL_PRESENTATION.md) 与
> [连续下拉修复](VIEWER_DISMISS_REENTRY.md)——记录的 `PhotoViewerPresentationBridge`
> 架构已整份删除，只作为历史记录保留。

## 为什么要换架构

旧实现对详情页用 modal `present` / `dismiss`，于是 App 必须自己复刻 UIKit 的转场生命周期：
`ViewerPresentationPhase`、`DismissalPhase`、`ViewerDismissInteraction`、`DownwardArbitrationState`、
pending request / pending dismiss、两套 generation、`ViewerInteractionContainerView`
以及一个 `ViewerDownwardIntentGesture`，全都长在 70KB 的
`PhotoViewerPresentationBridge.swift` 里。它的根本假设是**一次只能有一个转场**：
A 正在退，用户点 B，B 被放进 `pendingRequest` 等 A `finishDismissal` 之后才呈现。

这个假设有两个后果，正是用户报的两个症状：

1. **点了一下没反应**。pop 还没播完时的点击被推进队列，等动画结束才生效。
2. **下拉偶发/连续失效**。纵向手势要经过「系统 Zoom 下拉 ↔ 自定义仲裁 recognizer ↔
   `UIPageViewController` 内部 scroll pan」三方竞争，再叠加相位门控；漏任何一处就是一整笔触摸被吞。

现在改成真正的 UIKit 导航 push/pop：**转场由 UINavigationController 拥有**，App 只决定
「什么时候 push / 什么时候 pop」，以及「网格现在能不能接触摸」。UIKit 自己会把上一段
动画和下一段接起来（Fluid Transition）。

## 最终架构

```
ContentView
 └── NavigationStack                     ← 每个能开详情页的分支各一个（library / unsorted /
      │                                      album / search / smartSearch；LAN 早就是这样）
      ├── PhotoGridScreen / UnsortedPhotosScreen / SmartSearchScreen
      │    ├── @StateObject viewerNavigator: PhotoViewerNavigator
      │    ├── @StateObject transitionCoordinator: PhotoGridTransitionCoordinator
      │    ├── .background { PhotoViewerNavigationAnchor(navigator:) }   ← 取到 UINavigationController
      │    └── onOpen → navigator.open(request:gridTransitionCoordinator:makeRootView:)
      │
      └── UINavigationController 栈
           ├── [0] 网格（宿主 hosting controller）
           └── [1] PhotoViewerHostingController（一个会话一个）
                ├── transitionState: PhotoViewerTransitionState  ← 会话私有
                ├── gridTransitionCoordinator（weak）
                └── preferredTransition = .zoom(options:) { … }   ← push 之前就装好
```

### 职责划分

| 类型 | 职责 | 明确不做 |
|---|---|---|
| `PhotoViewerNavigator` | attach 导航栈、open、close、网格是否可点、生命周期日志 | 动画进度、相位、generation、pending、Timer、cooldown |
| `PhotoViewerHostingController` | 一个会话的宿主 + 生命周期回调上报 + 状态栏/底栏 | 自定义交互容器、`isUserInteractionEnabled` 覆写 |
| `PhotoViewerTransitionState` | 会话自己的 `currentIndex` / `currentAssetIdentifier` / veto / alignment | 描述 animation lifecycle |
| `PhotoGridTransitionCoordinator` | 只有网格：`sourceView(index:assetIdentifier:)`、网格交互开关 | 「当前 Viewer」、`beginViewerSession()` |
| `ViewerPagingCollectionController` | 横向分页、方向仲裁、页索引上报 | 方向仲裁的第二套实现、退场逻辑 |

### 每个 Viewer 一份 TransitionState

`PhotoViewerNavigator.open` 里为每次 push 新建：

```swift
let state = PhotoViewerTransitionState(
    sessionID: request.id,
    index: request.index,
    assetIdentifier: request.assetIdentifier
)
```

于是 A pop 与 B push 重叠时，两个会话各持有自己的状态。旧的
`PhotoGridTransitionCoordinator.viewerTransitionState` 是一个可变槽位，`beginViewerSession()`
会把它替换掉——B 一创建，A 的 source provider 就会去读 B 的状态，这正是「A/B 转场串来源」的成因。
现在 `zoomTransition(options:) 的 source closure` 直接捕获本会话的 `state`，
`PhotoViewerHostingController.gridTransitionCoordinator` 也是每个 Viewer 一份。

### 网格交互：只保留一个业务布尔

`PhotoViewerNavigator.isGridInteractionBlocked` 是网格唯一看的状态，规则表如下：

| 事件 | 值 |
|---|---|
| push 开始 | `true` |
| viewer 稳定 | `true` |
| interactive pop 开始、尚未决定 | `true` |
| **interactive pop cancel** | `true` |
| **interactive pop commit** | `false`（zoom-out 还在播，网格已可点） |
| Close Button 非交互 pop 开始 | `false` |

它不是 animation phase 镜像：`reconcileGridInteraction()` 只看三件事——
用户想要哪个会话（`desiredSessionID`）、哪个会话已 commit 正在退（`exposedOutgoingViewer`）、
导航栈里还有没有 viewer。回调全部按 `sessionID` 归属，迟到的旧回调不会改新会话。

## 手势归属

`ViewerPagingCollectionView.gestureRecognizerShouldBegin` 是**唯一**的方向仲裁：

| 输入 | 结果 |
|---|---|
| 明显横向（`|x| > |y| * 1.05`） | Pager 分页 |
| 明显纵向 | Pager 拒绝该 pan → `ZoomInteractiveDismissSwipeDown` 独占 |
| 照片放大中 (`isMediaZoomed`) | Pager 拒绝 → 图片平移 |
| 胶片条 scrub 中 | Pager 拒绝 |

`ViewerDownwardIntentGesture`、`DownwardDecision`、`DownwardResolution`、`gated` /
`reserve` / `track`、`canPrevent` / `canBePrevented` 整类删除。分页判定用**累计 translation**
而不是瞬时 velocity：`gestureRecognizerShouldBegin` 在刚够识别拖动的瞬间执行，慢速或按住再拖的手势
此时 velocity 近乎噪声（实测同一笔 281pt 的斜向拖动只有 129pt 到达 scroll view，velocity 判定会
误拒）。翻页提交阈值用 30% 视口宽度（`pagingCommitFraction`）+ 200pt/s 的 flick，对齐系统相册。

## 必须保留的一条 UIKit 兜底

🔴 **取消回弹后要自己把 viewer 的触摸还回去**，这是本轮实测到的真病根，且**属于 UIKit 的
状态而非 App 的逻辑**：interactive pop 期间 UIKit 会把被 push 的 hosting view 置
`isUserInteractionEnabled = false`，**取消路径下不会恢复**。`viewDidAppear` 时抓到的层级是

```
_UIHostingView<AnyView>(enabled=false) -> UIViewControllerWrapperView(enabled=true) -> …
```

而新 push 的 viewer 是 `enabled=true`。系统的三个 Zoom dismissal recognizer
（`ZoomInteractiveDismissLeadingEdgePan` / `SwipeDown` / `Pinch`）正好挂在这个 hosting view 上，
所以它 disabled 期间下拉**根本不会被识别**——没有 `zoom_dismiss_should_begin`、
没有 `viewWillDisappear`，什么都没有；某一笔恰好在 UIKit 重新 enable 之后落下就"恢复"了，
这就是"连续 4 次没反应、第 5 次突然退出"的来历。

因此 `PhotoViewerNavigator.restoreViewerInteraction(_:)` 在取消回调与 `viewDidAppear`
两处把 `isUserInteractionEnabled` 恢复为 `true`。它是**把输入还给用户**，不是 gate：
事件驱动、无 Timer、无asyncAfter，且只在当前为 `false` 时写入一次。

旧实现里的 `ViewerInteractionContainerView`（覆写 `isUserInteractionEnabled` setter 去拒绝
UIKit 的写入）已删除——那是和 UIKit 抢控制权；现在改为在正确的时机把它写回来。

## 日志

全部落在 `Library/Caches/PhotoVaultLaunch.log`（按 PID 分块），时间戳保留：

```
viewer_nav_push_requested session=… index=… asset=…
viewer_nav_pop_requested  session=…
viewer_nav_stack action=push|pop|releaseGrid|popCancelled|didAppear|didDisappear stack=…
viewer_viewWillAppear / viewer_viewIsAppearing / viewer_viewDidAppear /
viewer_viewWillDisappear / viewer_viewDidDisappear session=…
viewer_pop_interaction_committed / viewer_pop_interaction_cancelled session=…
viewer_grid_interaction blocked=true|false
viewer_interaction_restored session=…
viewer_pop_mid_transition interactive=… grid=reached:… hit=… enabled=…
viewer_touch_reachability stage=… reached=… chain=… zoom=[…]
zoom_dismiss_should_begin session=… willBegin=… velX=… velY=… vetoed=… result=…
viewer_pager_direction shouldBegin=… tx=… ty=… vx=… vy=…
viewer_pager_drag_begin / drag_end / decelerate_end / target / settle
viewer_fluid_transition_probe step=… failures=N
```

`viewer_pager_direction`、`viewer_pager_drag_*`、`viewer_pager_settle` 是排查"翻不动"的关键链：
它们能区分"Pager 没收手势 / 收了但目标算错 / 收了但 UIKit 弹回"。

## 探针与测试

- `-viewer-fluid-transition-probe`（App 内）：走 `navigator.open` / `navigator.close` 的真实入口，
  在 push 动画未结束时 close、在 pop 动画未结束时 open，然后断言导航栈最终只有一个 Viewer。
  它证明**没有 transition gate、没有排队**，不冒充真实手指。
- `-viewer-cancel-reentry-probe`：`viewer-cancel-count`（DEBUG 隐藏 UILabel）由 transition 自己的
  取消回调累加，证明每一笔短下拉**真的开始并取消**；`viewer_touch_reachability` 每次
  `viewDidAppear` 用真实 `window.hitTest` 回答"这一下会不会打到 Viewer"。

## NavigationSplitView 隔离的两个实测陷阱

🔴 **navigator 绝不能当 `UINavigationController.delegate`**。实测窗口里只有**一个**
`UINavigationController`（`nav@4[2:…]`），compact 宽度下 SwiftUI 的 `NavigationStack`
和 `NavigationSplitView` 共用它，而它的 delegate 正是"侧栏选中 → 详情列切换"的驱动。
曾经为了在 push Viewer 时隐藏导航栏而设了 `navigationController.delegate = self`，
结果侧栏每一行都变成"选中态更新、详情列不动"——就是 AGENTS.md 里记录过的侧栏污染。
导航栏改由 `viewerWillAppear`（隐藏）与 anchor 的 `viewWillAppear`（恢复）管理，
两者都 `animated: false`。

🔴 **anchor 不代表它已在导航栈里**。`PhotoViewerNavigationAnchor` 是被 push 中的
`NavigationStack` 宿主承载的，`navInWindow` 可能为 true 而 `contained == false`
（该分支当时还没成为详情列的可见内容）。所以 `attach` 只是把 controller 存下来，
**不要**在 attach 时断言、也不要假设当时的栈内容成立；真正使用它的是后续的 push。

## 分页与转场的判定要点

- 方向：`ViewerPagingCollectionView.gestureRecognizerShouldBegin` 用**累计 translation**
  （`max(|tx|,|ty|) >= 8` 时）判定，`|tx| > |ty| * 1.05` 才归 Pager。瞬时的
  `velocity` 只作为刚起手时的兜底——慢速斜拖在识别瞬间的 velocity 是噪声，
  纯 velocity 判定会误拒（实测 281pt 的斜拖只有 129pt 到达 scroll view）。
- 翻页提交：`scrollViewWillEndDragging` 给目标 index，阈值是 30% 视口宽
  （`pagingCommitFraction`）或 `|vx| > 200` 的方向性 flick；UIKit 自己播翻页动画。
- XCUITest 会等 idle，**无法**在动画中途注入手势；"动画期间能不能操作"只能靠 App 内探针。

## 修改范围

新增 `PhotoViewerTransition.swift`、`PhotoViewerNavigator.swift`、
`PhotoViewerHostingController.swift`、`ViewerPagingCollectionController.swift`；
删除 `PhotoViewerPresentationBridge.swift`（整文件）与 `ViewerDownwardIntentGesture` /
`NativePhotoPager` / `PhotoPagerPageController`（`PhotoViewerViews.swift` 内）；
改动 `PhotoViewerViews.swift`、`PhotoGridScreen.swift`、`ContentView.swift`、
`Search/SmartSearchScreen.swift`、`PhotoVaultUITests.swift`、`AGENTS.md` 与本文档。
未改照片数据、版本号、签名与发布配置。
