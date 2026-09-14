# PhotoVault 项目协作约定与踩坑记录

这份文档记录 PhotoVault 在大图库、iCloud、详情分页、手势和真机验证中遇到的问题。后续修改本项目时，先遵守这里的约定，再考虑视觉或结构调整。

## 项目边界

- 这是原生 SwiftUI + PhotoKit 的 iOS / iPadOS 相册，部署目标为 iOS/iPadOS 26.0。
- 优先使用系统组件和系统交互，不为已经有系统能力的地方重复实现复杂自绘控件。
- 只修改 PhotoVault 项目目录，父级工作区里的其他项目和未相关改动必须保留。
- 不要用 `git reset --hard`、`git checkout --` 或清理工作树来解决本项目问题。

## 页面称呼约定

对话、提交说明和日志分析统一使用以下称呼，括号里是对应的代码入口。

### 主页面

| 统一称呼 | 指什么 | 代码入口 |
|---|---|---|
| 首页 | NavigationSplitView 整体（侧栏 + 右侧内容区） | `ContentView` |
| 侧栏 | 左侧列表：图库、未整理、文件夹、普通相册、共享相册 | `ContentView` 内的 `List` |
| 图库页 | 侧栏选中“图库”后的全库网格 | `PhotoGridScreen` |
| 相册网格页 | 点开某个普通/共享相册后的网格 | `PhotoGridScreen`（album 模式） |
| 未整理页 | 未整理照片网格（SQLite 元数据分页） | `UnsortedPhotosScreen` |
| 文件夹相册页 | 侧栏“文件夹相册”进入的外部文件夹浏览入口（SMB/NAS、本机、U 盘） | `LANAlbumHomeScreen` |
| 详情页 | 全屏看图 + 左右翻页；统称叫“详情页”，需要区分时叫“普通详情页 / 未整理详情页” | `PhotoViewerView` / `IndexedPhotoViewerView` |
| 幻灯片页 | 自动播放的全屏页，同样分普通/未整理两种 | `SlideshowView` / `IndexedSlideshowView` |
| 设置面板 | 首页右上角入口弹出的设置 sheet | `PhotoVaultSettingsView` |

### 页面内的部件

| 统一称呼 | 指什么 | 代码入口 |
|---|---|---|
| 胶片条（底部缩略图） | 详情页底部的横向缩略图条 | `ViewerFilmstrip` / `IndexedViewerFilmstrip` |
| 底部操作栏 | 详情页下方单行的分享/收藏/删除工具栏 | `PhotoViewerViews.swift` 内的工具栏 |
| 信息面板 | 详情页“信息”按钮弹出的照片信息 sheet | info sheet |
| 相册选择器 | “添加到相册”弹出的 sheet | `AlbumPickerSheet` |
| 搜索结果页 | 在侧栏搜索框输入后过滤出的相册列表 | `PhotoSearchResultsScreen` |
| 权限页 | 还没授予照片权限时的引导页 | `PhotoPermissionView` |

### 容易混淆的区分

- “图库页”只指侧栏选“图库”进来的全库视图；点进某个相册后的叫“相册网格页”。两者复用 `PhotoGridScreen`，但数据范围不同。
- 详情页和幻灯片页各有两种变体：普通相册和图库走 `PhotoViewerView` / `SlideshowView`；未整理走 `IndexedPhotoViewerView` / `IndexedSlideshowView`（元数据分页那套）。

## 10 万张照片和 iCloud 性能

- 大图库必须保留为 `PHFetchResult<PHAsset>`，不要转换成 `[PHAsset]` 或一次性创建 10 万个 SwiftUI 行。
- 普通图库用懒加载/可回收的 `UICollectionView` 和 `PHCachingImageManager`；只缓存可见范围及附近范围。
- “未整理”照片不要在主线程遍历整个图库。使用后台 SQLite 索引和资产 ID 集合，详情页按页读取（当前实现的元数据页为 60 条）。
- 索引更新必须走增量：`PHPersistentChangeToken` 的有效性由 PhotoKit 自己保证（token 过期时 `fetchPersistentChanges` 抛错 → 兜底全量重建），不得用库签名（count/首尾 ID）去否决 token——截图按时间倒序插到第 0 位必然改签名，签名否决会让每张新截图都触发 10 万条全量重建。
- 索引库的读（`hasUsableIndex`/`unsortedIdentifiers`/`stats`）必须走专用读连接（`readQueue`），写重建事务（可达几十秒）不能阻塞未整理页翻页和详情加载；WAL 模式下读连接看到的是最后一次提交的快照。读连接必须以 READWRITE 打开——READONLY 连接无法执行 WAL 恢复（上个进程被杀时 `-shm` 需要恢复），会导致所有读失败、未整理永久 loading、并误触发全量重建；任何读失败还必须兜底重试写连接（`readWithFallback` 模式），读取不允许因第二条连接的问题而失败。
- 详情分页器（`IndexedAssetPager`）在索引同步结束（`isIndexingUnsorted` true→false）时必须重新拉取当前窗口：页面加载可能被 store 的代次守卫丢弃，没有这次补拉详情会永远停在占位符。
- 未整理的删除/加入相册必须乐观更新索引：PhotoKit 提交成功后立即调 `optimisticallyRemoveAssets`（`indexStore.removeAssets`，按 ID 删除）或 `optimisticallyAddMembership`（重算归属），直接发布重算后的 `unsortedCount` 驱动网格和详情即时刷新；不得等变更观察者 → 全量对账的慢回路。后续持久化变更对同一批 ID 的同步是幂等的，不会冲突。
- 用户在系统删除确认弹窗点“取消”会以 `PHPhotosError.userCancelled`（3072）回调：必须静默当作无操作（不报错、不动索引、不乐观更新），只有真正确认删除才走乐观移除。
- 库变更后的相册元数据重扫必须廉价：数量用 `estimatedAssetCount`（NSNotFound 才回退全量枚举），预览用 `fetchLimit = 1` 的单行请求；禁止对每个相册做完整成员枚举，否则每次截图/删除都是一次全库级别的元数据扫描。
- 图片解码红线：`PhotoImageManager.requestImage` 的回调里统一 `preparingForDisplay()` 预解码（PhotoKit 回调线程），禁止把懒解码的 UIImage 直接抛给主线程首次渲染——那是快速滚动掉帧的元凶。
- PhotoKit 缓存窗口只归预取代理管（`prefetchItemsAt`/`cancelPrefetchingForItemsAt`）：单元格里不得再逐个 `startCaching`/`stopCaching`，既多余又会踢掉预取刚建好的条目。
- 释放缓存只认 `.background`，`.inactive`（控制中心/横幅/切换器路过）不清；后台释放走 `dropTransientCaches()`，保留 16MB 上限的 `albumThumbnailCache`，回前台时列表/卡片缩略图零请求。首页平铺卡片、侧栏行、选择器行统一走该缓存。
- 索引进度指示只能是工具栏右上角的小号 `ProgressView`（未整理页 `isIndexingUnsorted`、网格页 `isLoadingAlbums`），禁止重新引入遮挡式进度条/浮层。
- 胶片缩略图也必须回收，按可见范围和元数据页加载；不能为了底部缩略图重新物化完整结果集。
- 图片请求必须区分查看器、幻灯片、可见网格和远端预取优先级。进入新页面、退出页面、切换相册或场景进入后台时取消不再需要的请求。
- 每次异步请求都要带 request key / 资产 ID 校验，旧请求回调不能覆盖新页面的状态。
- iCloud 的低清/降级图片仍是可以显示的有效帧；不能把“还没拿到原图”当成空白页或阻塞分页。
- 加载状态不能通过插入或移除大块 UI 改变布局，否则会导致页面跳动和点击错位。进度应放在不占布局的位置。
- 网格刷新必须是缓存优先：`refresh()` 不得把已有的 `allPhotos` 置空，旧 fetch 结果（PHFetchResult 本身是活数据）在后台重新扫描期间继续显示，图库页/相册网格页不能出现整屏阻塞加载；后台扫描时在网格页右上角显示与首页同款的小号 `ProgressView`（`store.isLoadingAlbums && assets != nil` 时出现）。只有首次启动确实没有任何数据时才允许整屏“正在读取照片”。
- 冷启动首帧只允许一个 PhotoKit 请求。启动窗口（`openLaunchWindow`：和整库同一个查询 + `fetchLimit`，取最新几百张）必须独占，解析完成后 `beginBulkRefresh` 才能发起整库 fetch、相册元数据扫描和变更观察者注册——实测把这几个一起打给 `photolibraryd`，会把几百条的启动窗口拖到 2.9s。`authorizationStatus` 不得在属性初始化式里同步读 `PHPhotoLibrary.authorizationStatus`（那会在 SwiftUI 第一次求值 body 时挡住首帧），要从 `UserDefaults` 种子起手、在 `start()` 里读真值纠正并落盘。整库结果一物化就要在主线程单独发布 `allPhotos`，不得和相册枚举合并在同一个回调里，否则 10 万张的网格要等 163 个相册查完才出现。启动耗时用 `photoVaultTraceLaunch` 记录，落在 `Library/Caches/PhotoVaultLaunch.log`（按 PID 分块追加，不随主诊断日志的 512 KB 滚动丢失）；查真机启动耗时就拉这个文件。注意 `xcrun devicectl device process terminate` 必须带 `--pid`，只给 bundle id 会报错退出、App 其实没被杀掉，测出来的都是「热启动」。
- 列表滑动性能红线：索引扫描进度必须经 `publishIndexProgress` 节流（每秒最多 ~4 次，阶段切换和完成必发），禁止把每个扫描 tick 直接发布成 `@Published`——那会让首页、网格和弹出面板整树重建；`assets(in:)` 的 PHFetchResult 必须按相册 ID 缓存复用；相册行缩略图（首页/选择器/搜索结果）统一走 `albumThumbnailCache`（`cacheResult: true, cacheScope: .albumThumbnail, usesPhotoKitCaching: false`）；DEBUG 诊断日志只写 OSLog 和沙盒文件，不在主线程 `print`。

## 首页相册结构和布局

- 相册数据按“文件夹 -> 相册”建模，不能把文件夹内的相册平铺到根级。
- 普通相册、共享相册和文件夹的列表行必须与系统设置页同款高度（紧凑单行，约 44pt）：28pt 正方形图标槽、图标与文字间距固定 10pt、标题居左、数量/摘要以 secondary 文字靠右；禁止回到大图标 + 两行堆叠的旧样式。平铺卡片视觉不受此条约束。
- 普通相册和共享相册都支持折叠；箭头向右表示收起，箭头向下表示展开，必须和文件夹使用同一逻辑。
- 文件夹本身始终以列表行展示；列表/平铺切换只改变相册内容，不把文件夹行变成平铺卡片。
- 列表模式下文件夹内相册保留层级缩进；平铺模式下文件夹内相册的左右宽度、上下间距要与普通/共享相册一致，不得因为嵌套容器产生更窄卡片。
- 列表/平铺切换按钮是整个相册区域的统一按钮，应放在标题同一行的右上角，不能单独占一行。
- 平铺列数必须由实际可用宽度计算，不能只依赖会保留旧行高的自适应布局。切换列数后要同步更新行高/网格身份，避免出现“有高度但内容空白”或顶部大面积空白。
- 双指张开应增加列数/放大，双指捏合应减少列数/缩小；平铺卡片的点击必须等手势判定结束后再触发，不能放大后误进入相册。
- 列数是用户设置，要用持久化值保存；进入相册时不能重置为默认列数。普通、共享和文件夹内容的切换规则要保持一致。
- 更新列表时只显示轻量状态，不插入会改变滚动位置的 loading 区域。
- 网格长按菜单统一为：收藏、快速收藏夹子菜单、添加到相册、移除相册（仅当照片已在用户相册中；单个归属时是直接的“从「XX」移除”，多个归属时是“移除相册”子菜单）、分享、删除。相册归属用 `PhotoLibraryStore.userAlbums(containing:)` 查询，只在菜单即将显示时执行一次。删除不做人肉二次确认——`PHAssetChangeRequest.deleteAssets` 自带系统确认弹窗，App 内再弹一层是重复拦截。
- “快速收藏夹”指用户在相册选择器里用星标自行标记的一组常用相册（不是某个固定相册）。标记集合按 `PhotoQuickAlbums.storageKey` 持久化为相册 ID 数组（`PhotoLibraryStore.quickAlbumIDs`，@Published），长按子菜单按标记顺序列出这些相册，点一下直接加入，已在的项打勾；没有标记相册时整个子菜单隐藏。旧版单相册 ID（`legacyStorageKey`）首次读取时迁移。
- 相册选择器（添加到相册）必须与侧栏同构：行样式与设置页同高（28pt 图标槽、标题居左、数量靠右的紧凑单行），顶层相册平铺在前，文件夹行可展开，展开后先子文件夹再相册，每层缩进一级；行尾是快速收藏星标（点星标只切换标记，不选中相册、不关闭面板）。箭头向右表示收起、向下表示展开，与侧栏同一逻辑。图库页、未整理页、普通详情页、未整理详情页共用 `AlbumPickerSheet`，改动时四处行为要保持一致。

## 详情页分页：必须保持连续可滑动

- 不要用动态变化的绝对索引 `TabView` 页面窗口来实现详情分页。页面集合变化后，SwiftUI 的 `TabView`/内部 `UIPageViewController` 可能与 selection 失步，典型症状是第一次能滑、第二次卡住。
- 当前系统滑动样式使用 `NativePhotoPager` + UIKit `UIPageViewController`。分页控制器保留当前页及前后邻页，使用 delegate 的 `didFinishAnimating` 唯一地更新 `currentIndex`，不要在动画中立即把 selection 归中。
- 外部胶片点击跳转也必须经过同一个 UIKit 分页控制器；要有重复 programmatic transition 保护，不能在图片下载导致的多次 SwiftUI 更新中重启动画。
- 胶片条是实时 scrub 语义（对齐 iOS 26 相册）：拖动/减速过程中 `scrollViewDidScroll` 持续把中心标记下的缩略图索引写回 `currentIndex`，主图即时跟着切，不能等滚动停止才切换。scrub 期间胶片条不做 `scrollToItem` 回中、不逐帧写 `position`，松手后停在原位。scrub 状态经 `onScrubbingChanged` 传给 `NativePhotoPager`（`isScrubbing`），scrub 分支必须用 `setViewControllers(animated: false)` 即时换页——动画式 programmatic transition 的 pending 保护会丢掉连发的索引更新。自定义切换样式在 scrub 期间禁用过渡动画。
- `viewControllerBefore`/`viewControllerAfter` 在边界返回 `nil`；不能创建负索引或超范围页面。
- 未整理详情页仍按元数据页懒加载，缺少资产时显示占位页；资产到达后只更新对应页面，不重置分页控制器。
- 系统样式不要再叠加自定义水平 `DragGesture`。自定义淡入、推入、缩放样式可以使用单独的自定义 pager，但要保证一次手势只推进一次索引。
- 图片自身的单指拖拽不能在 1 倍缩放时注册为有效手势，否则会抢走详情分页。当前规则是 1 倍时把单指滑动交给分页，只有缩放大于约 1.01 倍后才允许图片平移。
- 双指缩放、放大后的平移和单指分页必须互斥；切页或页面消失时必须清除 `isZooming`，不能让旧页的缩放状态阻塞新页。
- `AssetImageView` 不要给每张图片单独加 opacity 淡入。详情页的切换动画由 pager 统一负责，否则会出现一张滑动、一张淡入的割裂效果，尤其是 iCloud 图片返回时更明显。
- 详情页底部操作栏对齐原生相册的悬浮工具栏样式：图标按钮一律用 iOS 26 液态玻璃（`.glassEffect(.regular.interactive(), in: Circle())`，顶栏、底栏、菜单、幻灯片控制同一套），不包胶囊/毛玻璃容器背景；46pt 命中区、均匀分布整个宽度、不留提示文字。玻璃按钮不得引入影响分页命中区域的额外手势层。
- 分享面板必须用 `ActivityPresenter.present(items:onDismiss:)` 从最顶层 UIKit VC 呈现，不能把 `UIActivityViewController` 托管进 SwiftUI `.sheet`——后者首帧尺寸错误导致面板内容跳位。`requestShareItems` 准备临时文件期间（iCloud 照片可能很慢）必须给出原位反馈（详情页分享按钮原 46pt 框内切换为 ProgressView，网格侧禁用按钮），并用 `isPreparingShare` 防止重复触发；临时文件在 `onDismiss` 清理。
- 图片可以延伸到全屏，但关闭、信息、全屏等控制必须在安全区域内，不能被状态栏、灵动岛、Home Indicator 或底部黑边遮挡。
- 查看器的呈现/退出是"哪来的回哪"的空间转场（P0 原则）：退出目标永远是**当前正在看的照片**对应的网格 cell，不是进入时的那张。实现走 `PhotoViewerPresentationBridge`（`.background` 里的 `UIViewControllerRepresentable`，用真实 UIKit `present` 呈现 `UIHostingController`）+ iOS 26 系统缩放转场（`preferredTransition = .zoom(options:sourceViewProvider:)`）。**`fullScreenCover` 做不了这个**——SwiftUI 自己持有 hosting controller，`preferredTransition` 设上时呈现已完成；不要改回 fullScreenCover。
- 退出目标由 `PhotoViewerTransitionState`（currentIndex + currentAssetIdentifier）决定：查看器**每次翻页**都要 `update(index:assetIdentifier:)`，退出时只读当前值、绝不读 initialIndex。网格侧 `PhotoGridTransitionCoordinator.sourceView(index:assetIdentifier:)` 持弱引用 collectionView 查找目标 cell：index 先用 assetIdentifier 校验，不一致时在 ±24 邻域内按 identifier 重扫（删除会平移索引），找不到（照片已删）返回 nil 让 UIKit 走默认转场；目标 cell 不可见时先 `scrollToItem(.centeredVertically, animated: false)` + `layoutIfNeeded()`（此时查看器盖着网格，用户看不到跳动）。禁止建全库 identifier→index/cell 缓存。
- 退出只有单一入口 `requestDismiss(reason:)`（`isDismissing` 防重入）：关闭按钮、下拉提交、移出相册等都调它；视觉一律交给系统缩放转场，**禁止再写"成功后向下飞出"的自定义轨迹**（旧 `ViewerMotion.completionOffset` 已删）。系统转场的交互式下拉（`ZoomInteractiveDismissSwipeDown`）自带跟手进度和取消连续性，不要叠自定义 mediaScale/offset/cornerRadius 双重变换。
- 🔴 **系统发起的退出必须兜底复位状态（实测 P0）**：下拉提交后 UIKit 自己结束呈现，`dismissIfNeeded` 的 completion 和 delegate 都可能不走——若不复位，屏幕上 `viewerRequest` 残留非 nil、`isViewerTransitioning` 卡在 true、网格 `collectionView.isUserInteractionEnabled = false`，表现为"查看器明明退出了，之后点什么都没反应"。兜底是 `PhotoViewerHostingController.viewDidDisappear`（bridge 内子类）→ `hostedViewDidVanish(controller:)`：与 programmatic 路径、`presentationControllerDidDismiss` 三路信号全部收敛进 `finishDismissal(sessionID:)`，谁先到谁复位，其余幂等。⚠️ 兜底必须带**会话校验**：`guard hosted === controller`（`presentationControllerDidDismiss` 同理校验 `presentedViewController`），否则一个已经结清的旧查看器迟到的 `viewDidDisappear` 会把**刚打开的新会话**误判为已结束。
- 🔴 **退出状态必须是三态，不能用 began 一把梭**：`Coordinator.DismissalPhase` = `.idle` / `.interactive` / `.committed`。`.interactive` 是"系统下拉正在拖"（可能取消），`.committed` 是"这次退出一定会走完"。**只有 commit 才释放网格**：`dismissTransitionCommitted()` 里 `setGridInteractionEnabled(true)` + `outgoingViewerInteractionRoot().isUserInteractionEnabled = false`。关闭按钮与其它 programmatic 退出在 `dismissIfNeeded` 里直接视为 committed（不可取消）；系统下拉靠 `transitionCoordinator.notifyWhenInteractionChanges` 的 `context.isCancelled` 决定 cancel/commit。`viewWillAppear` 仅作取消兜底，`dismissTransitionCancelled()` 以 `phase != .idle` 幂等。
- 🔴 **只允许关掉 Viewer 自己那一支，禁止走到公共祖先**：`outgoingViewerInteractionRoot()` 从 `hosted.view` 往上爬，遇到第一个 `containsRegisteredGrid(in:)` 为真的祖先**立刻停**——那说明再往上就是 Viewer + Grid 的公共祖先（window / 转场根），禁用它等于把网格一起禁掉。实测层级很短：`_UIHostingView<PhotoViewerView>` → `UITransitionView` → window，`containsGrid=false`，网格是 `UITransitionView` 的**兄弟**而不是子孙，所以关掉 `UITransitionView` 是正确的：命中测试会跳过它落到网格。禁用必须在 `finishDismissal` 里**无条件恢复**（`restoreViewerInteraction()`），否则会留下永久 `isUserInteractionEnabled = false` 的视图。
- 🔴 **禁止 Timer / 重试轮询**：曾经的 `interactionReassertTimer`（0.08s × 10 次反复把容器压回 disabled）已删除——和 UIKit 转场抢控制权，而且动画长一点就会在计时器停掉后把触摸重新吞回去。曾经的 `schedulePresentRetry()`（主队列反复 `flushPendingRequest`）也已删除。现在的排队打开请求是**事件驱动**的：`sync` 在 `dismissalPhase != .idle` 且请求 id 不同时只 `pendingRequest = request`，由 dismiss completion → `finishDismissal` → `flushPendingRequest()` 拉起来；`presentedRequestID` 直到 `finishDismissal` 才清空，所以"旧会话还在退"这件事天然可判。
- 🔴 **`viewWillDisappear` ≠ 提交**：交互式下拉在**拖动开始**就触发它（取消时再触发 `viewWillAppear` 回来），所以它只能标记 `.interactive`，绝不能当 commit。唤醒网格触发的 SwiftUI 更新会让 dismissing 会话自己的请求再次流经 `sync`——超替分支必须按 `request.id != presentedRequestID` 过滤，否则同一个查看器会在退出后又弹回来。`dismissIfNeeded` 开头 `guard dismissalPhase == .idle`，否则 SwiftUI 每次重渲染带来的 `sync(nil)` 都会再发一次 `dismiss`。
- 🔴 **XCUITest 无法在动画中途注入手势**：`tap()`/`swipeUp()` 前会等 App 回到 idle，实测上滑要等退出动画结束 **407ms 之后**才落到网格。所以"动画期间能不能操作"不能靠 UI 测试断言，必须用 App 内探针：`dismiss_probe`（commit 时刻）与 `dismiss_probe_mid_transition`（`coordinator.animate(alongsideTransition:)` 里，转场动画进行中）用真实 `window.hitTest(grid 中心)` 回答"这一下会不会打到网格"，输出形如 `grid=reached:true hit=UICollectionView enabled=true`。日志在 `Library/Caches/PhotoVaultDiagnostics.log`。UI 测试负责的是另一件事：退出后整个视口都可命中（`cell.isHittable`，跨 0/5/15 取样，能抓到只盖住一部分的残留遮罩），以及退出后单击必达且打开的是被点的那张（`viewer-counter` 断言 "3 / N"，而不是"又有查看器出现"）。注意 `swipeUp()` 也**不能**用来证明滚动：实测同一次上滑只让 offset 走了 77pt，cell 不会离屏，"photo-cell-0 消失了"这种断言会假失败。
- 缩放转场选项：`interactiveDismissShouldBegin` 里查 `interactiveDismissVeto`（`isZooming || isPaging` 时拒绝，把单指拖动还给图片平移和 pager）；`alignmentRectProvider` 返回照片 aspect-fit 实际矩形（letterbox 除外），让缩放 morph 对准照片本体而不是全屏容器。
- 🔴 查看器静止背景必须不透明：`dimmingColor` 只覆盖转场进行中/交互中，呈现完成后的静止态没有暗化层——hosting 背景若为 clear，letterbox 会透出底层网格（连"图库"标题栏都看得见）。`hosting.view.backgroundColor = .black` 且不要再改回 clear。
- 🔴 不要试图替换分页器内部 scrollView 的 pan delegate：`UIScrollView` 强制内置 pan 的 delegate 是它自己，`setDelegate:` 直接 SIGABRT（`'UIScrollView's built-in pan gesture recognizer must have its scroll view as its delegate'`）。真机触摸下系统下拉与 pager 手势仲裁本来就通，无需（也不要）用 `require(toFail:)` 给 pager pan 加等待。
- 查看器退出路径的回归用 UI 测试跑：`xcodebuild test -project PhotoVault.xcodeproj -scheme PhotoVault -destination 'platform=iOS Simulator,id=<id>' -only-testing:PhotoVaultUITests`。覆盖：关闭退出、下拉退出、短拉取消连续、翻页后关闭、未整理查看器下拉退出——每个场景都断言"退出后网格仍可交互"（再现 P0 死屏的最直接探针）。**模拟器的输入自动化必须用 XCUITest**：macOS 侧 CGEvent 合成事件会被桌面窗墙吃掉，到不了模拟器窗口。
- 详情展示期间要让底层相册网格进入 inactive 状态，暂停其交互和图片请求；确认退出后可立即恢复底层滚动交互，视觉转场仍由详情页完成，`onDismiss` 只做最终清理，避免用户退出后还要等待才能滑动。
- 详情返回时不要因为 `isActive` 恢复就无条件对相册网格调用 `reloadData()`；这会清掉已经显示的缩略图并重新显示 loading，和全屏退出动画叠加成闪屏。未变化的数据应保留可见 cell，只恢复取消的请求；数据源变化时才整体刷新。
- `NativePhotoPager` 销毁时先解除 `UIPageViewController` 的 delegate/dataSource；未整理详情的分页元数据请求必须用代次校验，页面消失后丢弃旧回调。

## 文件夹相册（局域网/本地/U 盘文件夹）

- “文件夹相册”的实体是用户通过文件 App 选中的文件夹：`LANFolderLibrary` 保存安全作用域书签（`PhotoVault.lanFolders.v1`），跨启动靠 `URL(resolvingBookmarkData:)` 恢复访问；书签失效（共享断开、U 盘拔出）时提示重新添加，不做静默失败。来源不限（SMB/NAS 共享、本机“我的 iPhone”、外接 U 盘），文件 App 能到的文件夹都能加。同一物理文件夹只保留一个条目：`add(from:)` 用解析路径比对去重（书签字节每次生成不同，不能按字节比对），重复添加沿用现有条目并顺带剪掉历史重复行；匹配与剪枝有 provider 往返，必须在后台线程跑（防死共享挂住选择器回调），且**匹配到 pick 路径的既有条目必须保留**——那是被沿用的条目，剪掉的只能是后面同路径的重复行。
- 文件夹相册是首页侧栏里唯一做二级 push 的 detail 页（LAN 主页里 `NavigationLink` 进文件夹网格）。compact 宽度下这个 push 绝不能落在 NavigationSplitView 自己的内部栈上——pop 回来会把 split view 的详情展示状态搞乱：一次返回直接跳回侧栏、之后侧栏所有行都点不进去（selection 绑定仍在更新、行保持选中态，但详情列不再展示，主线程并不卡）。因此 `.lan` 分支的 detail 内容必须包一层专属 `NavigationStack`（见 `ContentView.detailView`），让文件夹网格的 push/pop 收在这层栈里；改首页 detail 结构时不得去掉这层栈。
- 图片枚举递归全文件夹、按修改时间倒序，走 `FileManager.enumerator`（后台线程）；图片解码必须走 ImageIO 降采样（`CGImageSourceCreateThumbnailAtIndex` + `ThumbnailMaxPixelSize`，缩略图 512、查看 2048），禁止 `UIImage(data:)` 全尺寸解码进网格——50MP 文件全解码是主线程杀手。
- 安全作用域由 `LANFolderScopeManager` 会话期内持有（幂等激活，不随页面退出释放），反复启停 scope 会触发 SMB provider 往返、表现为相册卡死。`activate` 必须返回 `startAccessingSecurityScopedResource` 的结果：**拿到作用域失败 + 枚举 0 张 = 授权失效，不要阻塞重试，立即报错并自动弹出文件夹选择器重新授权**（选择器经 `directoryURL` 直接打开在目标文件夹父目录，用户选中该文件夹点"打开"即完成刷新并自动重新枚举；每次进入只自动弹一次）。**重复选择同一文件夹时 `add(from:)` 会用新书签刷新既有条目（重新选择=重新授权）**，这是失效文件夹的治疗路径。**冷启动后授权恢复有约 6~13 秒的概率性失败期（书签本身有效）**——靠进入文件夹列表时的后台预热（`warmScopes`，单次触碰唤醒 provider 守护进程，用户无感）来规避，入口流程本身不做阻塞重试。stale 书签只能在作用域真正拿到的前提下刷新（`refreshBookmarkIfStale` 已内置该前提）——拿着未授权的 URL 生成的新书签不含凭据，覆盖存储书签后文件夹会在每次重启后永久损坏、重试无效。图片加载一律走 `LANFolderImageLoaderQueue`：同 URL 请求必须合并（in-flight 去重），信号量限 3 并发且等待带超时（毒槽不放大队列），禁止每个 cell 直接 detached 任务做同步网络文件解码——SMB 读是网络往返，几十个并发阻塞任务会榨干 Swift 协作线程池，整个 App 冻结。文件夹解析/激活/枚举整链必须经 `LANFolderTimeout` 跑在 GCD 线程上并限时 20 秒，超时明确报错而不是无限转圈。诊断日志走 `LANFolderDiagnostics`（OSLog + 沙盒 `Library/Caches/PhotoVault/lan-folder.log`，devicectl 可拉取）。
- `LANFolderTimeout` 必须用 GCD 竞速（ResultBox + 信号量，先完成者胜出），禁止用任务组等待全部子任务——阻塞遍历不响应取消，等败者等于没有超时（曾导致二次进入相册必然卡死）。枚举结果存 `LANFolderSessionCache`，会话内再次进入同一文件夹直接回放缓存，禁止重复触发 SMB 全量遍历。
- 大相册（成千上万张、单张几十 MB）的性能红线：缩略图必须落盘缓存（`LANFolderThumbnailDiskCache`，Caches 下按相册 ID 分目录，键 = 相对路径 + mtime + 尺寸，删除相册时同步清理），枚举时顺手把已查到的 mtime 记进 `knownModificationDates`，避免为同一文件重复 `resourceValues`；内存缓存必须按用途分开并各带 `totalCostLimit`（缩略图 64MB / 全尺寸 72MB 且最多 6 张，见 `LANFolderImageCache`，`isFullSize` 以 1024pt 为界），NSCache 会随内存压力自动驱逐；解码槽必须感知取消——等待者用 `LANFolderLoadWaiter`（幂等 `resume`、取消时脱离并 resume nil），无等待者时直接跳过闸门，离屏 cell 不得占用限流槽位，也不得让已取消的请求白跑一遍 SMB 解码。
- LAN 图片视图（`LANFolderImageView`）必须保持"上报尺寸 = 提案尺寸"：`Image.resizable().scaledToFill()` 会把溢出尺寸（如 810×810）上报给父布局，弹性 `.frame(maxWidth:.infinity)` 不截断它，ZStack 采纳后会把关闭按钮、计数器等兄弟控件排到屏幕外——表现为照片铺满全屏、无任何可点控件、无法退出。因此图片一律包在 `Color.clear.overlay { … }.clipped()` 里（网格 cell 早已如此）；查看器的下拉退出手势必须挂在全屏点击分区那一层（它盖在图片上方，挂在图片上的手势收不到触摸）。
- 查看器/幻灯片两个 `fullScreenCover` 的内容绝不能用 `if let folderURL` 做条件：会话内二次进入文件夹走 `LANFolderSessionCache` 回放、不解析书签，`folderURL` 保持 nil，会呈现一个没有任何控件的空封面把用户困住。`rootURL` 传 `folderURL ?? URL(fileURLWithPath: "/")` 即可——磁盘缩略图缓存对不匹配的 root 会回退用绝对路径做键。
- 枚举对 provider 瞬断必须有韧性：文件提供方（网盘/SMB/iCloud）断连或重连瞬间，目录列表可能照常返回但逐文件属性查询全部失败——扩展名命中的文件在 `resourceValues` 查询失败时不得丢弃（否则整个文件夹枚举成 0 张、显示"没有图片"）；空枚举结果不得写入 `LANFolderSessionCache`（否则整个会话被钉死在空列表），空状态提供"重试"按钮重新枚举。书签被标记 stale 时在持有 scope 期间刷新持久化书签（`LANFolderLibrary.refreshBookmarkIfStale`），枚举链路带 DEBUG OSLog 诊断（subsystem `com.misswell.PhotoVault`，category `LANFolder`）。
- 文件夹的看图与幻灯片必须和相册同款体验（`LANFolderPager` + 重写后的 `LANFolderSlideshowScreen`）：查看器用 URL 版 `UIPageViewController` 分页器（左右连续滑动翻页、保当前页±邻页、程序化跳转带 pending 保护、下拉退出用手势仲裁 `require(toFail:)`），不要回退成点区域翻页；图片内容模式用 fit（整张显示，和相册一致），只有网格缩略图用 fill。幻灯片镜像相册 `SlideshowView`：单可见页 + `.task(id:)` 推进器（后台暂停、provider 交付不阻塞推进）、间隔/随机/循环控制、设置里的过渡样式（fade/slide/zoom/dissolve）、邻页预读走共享的 `LANFolderImageLoaderQueue`、播放时禁休眠。`LANFolderImageView` 必须保持"上报尺寸 = 提案尺寸"（`Color.clear.overlay { … }.clipped()`），`scaledToFill` 的溢出尺寸会把兄弟控件挤出屏幕。
- 文件夹访问（`startAccessingSecurityScopedResource`）必须与 `stopAccessing` 成对出现；图片加载按文件各自包裹即可。

## 幻灯片和预读

- 幻灯片不要通过动态重建的三页 `TabView` 自动播放，否则容易在前两张之间来回切换。
- 当前实现使用单个可见页面，索引由播放控制器单向推进；当前照片前后邻居在切换前预取，优先请求实际显示尺寸的 iCloud 图片，避免切换后才出现长时间模糊帧。
- 图片下载是否完成不能决定播放索引是否推进；加载失败要显示错误或重试，而不是把播放任务挂在 loading 状态。
- 幻灯片切换样式要统一使用设置中的样式，不能让图片加载回调额外触发另一种淡入效果。
- 页面退出、进入后台、暂停播放时取消幻灯片预取和低优先级请求；重新进入时从当前索引建立新的邻居窗口。

## 诊断日志

- Debug 构建中的 `PagerDiagnostics` 同时写 `OSLog` 和 App 沙盒的 `Library/Caches/PhotoVault/PagerDiagnostics.log`，文件限制约 512 KB。
- 排查滑动问题时至少记录：详情进入、当前/目标索引、分页 data source before/after、动画完成/取消、缩放开始/结束、图片 ready 回调和图片内部 drag。
- 诊断结论必须以日志链路为依据：如果只有 `image drag began/ended` 而没有分页 data source 或 transition 回调，优先修复手势命中，而不是继续改 iCloud 加载。
- 取真机日志可使用：

  ```bash
  xcrun devicectl device copy from \
    --device <device-id> \
    --domain-type appDataContainer \
    --domain-identifier com.misswell.PhotoVault \
    --source Library/Caches/PhotoVault/PagerDiagnostics.log \
    --destination /tmp/PhotoVault-PagerDiagnostics.log
  ```

- 读取日志前先 `wc -l`，再分段查看；不要把大日志一次性输出到对话中。

## 构建、真机和发布验证

- 应用图标有三套：主 `AppIcon`（含亮/暗外观变体，跟随系统自动切换）和备用 `AppIconLight` / `AppIconDark`（固定亮/暗）。备用图标靠 `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` 编译进包，手动切换走 `UIApplication.setAlternateIconName`（设置面板“应用图标”，`AppIconPreference.storageKey` 持久化用户选择；“跟随系统”传 nil 恢复主图标）。新增图标时必须同时建 appiconset、更新该编译设置；切换会触发系统确认弹窗，属正常行为。

- TestFlight 上传使用 **App Store Connect API 密钥**（Xcode 的 Apple ID 会话几天就过期，"Failed to Use Accounts" 即此原因；API 密钥无有效期）：
  - 本工作区直接用全局脚本：`~/.appstoreconnect/upload-testflight.sh build/PhotoVault-NN.xcarchive`（所有项目、所有 AI 工具通用；详见 `~/.appstoreconnect/README.md` 与 `~/.codex/AGENTS.md`）。
  - 密钥：`photovault-cli`，Key ID `248D8U8C36`，Issuer ID `102e47ab-8e2a-4204-b82b-200d5287f267`，.p8 位于 `~/.appstoreconnect/private_keys/`（私有凭据，严禁提交进仓库或外发）；环境变量已配入 `~/.zshenv`。
  - 本机分发证书：`Apple Distribution: Guofeng Liu (U8U443D7ZL)`（2026-09-06 经开发者门户 CSR 流程创建，私钥在登录钥匙串）。
  - 也可直接调用命令（递增 build → archive 后）：
    ```bash
    xcodebuild -exportArchive -archivePath build/PhotoVault-NN.xcarchive \
      -exportOptionsPlist build/ExportOptions-manual.plist \
      -exportPath build/tf-export-NN \
      -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_248D8U8C36.p8 \
      -authenticationKeyID 248D8U8C36 \
      -authenticationKeyIssuerID 102e47ab-8e2a-4204-b82b-200d5287f267
    ```
  - `build/ExportOptions-manual.plist` 用 **manual 签名**（显式 signingCertificate + 描述文件 "PhotoVault AppStore 17"）。API 密钥不能用 Xcode 的云端签名（"Cloud signing permission error"），账户会话过期时云端签名也不可用——所以之前"上午能传下午不能"。描述文件过期/失效时在开发者门户（浏览器登录 idmsa）重新生成一份包含该证书的 App Store 描述文件，安装到 `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` 即可。

- “推送到手机”指本地真机 build、install、launch，不等于只生成 `.app`。
- 先检查 `xcrun devicectl list devices`。设备显示 paired 但 `unavailable` 时，通常是开发隧道断开；解锁手机、重新插拔数据线或恢复无线连接后再安装。
- 真机安装完成后要用 `xcrun devicectl device process launch` 启动，并用 `device info processes` 确认进程存在。
- 最少验证路径：普通相册第 1 -> 2 -> 3 张、返回滑动、退出详情再进入；未整理相册重复同样路径；再测试双指缩放后分页、底部缩略图跳转和 iCloud 尚未下载的邻页。
- 构建示例：

  ```bash
  xcodebuild -project PhotoVault.xcodeproj \
    -scheme PhotoVault \
    -configuration Debug \
    -destination 'generic/platform=iOS' \
    -derivedDataPath build/DerivedDataPhotoVault \
    build
  ```

- 真机安装必须确认输出包含 `App installed`；启动必须确认输出包含 `Launched application`。模拟器 build/install/launch 通过不代表真机分页交互已经验收。
- ⚠️ **真机上跑 XCUITest 需要 Xcode 的 SDK 覆盖设备系统版本**（2026-09-14 实测）：本机 Xcode 26.3 只带 **iOS 26.2** SDK，而 BENG 是 **iOS 27.0**，`/Applications/Xcode.app/.../iPhoneOS.platform/DeviceSupport` 里没有 27 → `xcodebuild test -destination 'platform=iOS,id=00008130-000E782A26B8001C'` 会以 `Error locating DeviceSupport directory using Optional("arm64") or Optional("arm64e"): nilError` + `PhotoVaultUITests-Runner encountered an error (Early unexpected exit, operation never finished bootstrapping ... exited with code 74 before establishing connection)` 失败；设备锁屏时报的是另一句 `Xcode cannot launch PhotoVaultUITests on BENG because the device is locked.`。**这不影响 `devicectl install` / `process launch`**（走的是另一条通路，App 能正常装能正常起）——所以"真机能装能跑"不等于"真机能跑 UI 测试"。要跑真机 UI 测试得升到支持 iOS 27 的 Xcode；在那之前，真机交互只能人工验收。
- TestFlight 与手机本地安装是两条流程。上传 TestFlight 前必须递增 `CURRENT_PROJECT_VERSION`，并以命令行上传成功标志为准；不要因为本地安装成功就宣称 TestFlight 已上传。
