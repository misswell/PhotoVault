# PhotoVault 项目协作约定与踩坑记录

这份文档记录 PhotoVault 在大图库、iCloud、详情分页、手势和真机验证中遇到的问题。后续修改本项目时，先遵守这里的约定，再考虑视觉或结构调整。

## 项目边界

- 这是原生 SwiftUI + PhotoKit 的 iOS / iPadOS 相册，部署目标为 iOS/iPadOS 26.0。
- 优先使用系统组件和系统交互，不为已经有系统能力的地方重复实现复杂自绘控件。
- 只修改 PhotoVault 项目目录，父级工作区里的其他项目和未相关改动必须保留。
- 不要用 `git reset --hard`、`git checkout --` 或清理工作树来解决本项目问题。

## 10 万张照片和 iCloud 性能

- 大图库必须保留为 `PHFetchResult<PHAsset>`，不要转换成 `[PHAsset]` 或一次性创建 10 万个 SwiftUI 行。
- 普通图库用懒加载/可回收的 `UICollectionView` 和 `PHCachingImageManager`；只缓存可见范围及附近范围。
- “未整理”照片不要在主线程遍历整个图库。使用后台 SQLite 索引和资产 ID 集合，详情页按页读取（当前实现的元数据页为 60 条）。
- 胶片缩略图也必须回收，按可见范围和元数据页加载；不能为了底部缩略图重新物化完整结果集。
- 图片请求必须区分查看器、幻灯片、可见网格和远端预取优先级。进入新页面、退出页面、切换相册或场景进入后台时取消不再需要的请求。
- 每次异步请求都要带 request key / 资产 ID 校验，旧请求回调不能覆盖新页面的状态。
- iCloud 的低清/降级图片仍是可以显示的有效帧；不能把“还没拿到原图”当成空白页或阻塞分页。
- 加载状态不能通过插入或移除大块 UI 改变布局，否则会导致页面跳动和点击错位。进度应放在不占布局的位置。

## 首页相册结构和布局

- 相册数据按“文件夹 -> 相册”建模，不能把文件夹内的相册平铺到根级。
- 普通相册、共享相册和文件夹必须有一致的行/卡片视觉系统：图标槽位固定宽度、图标与文字间距固定、预览统一为正方形。
- 普通相册和共享相册都支持折叠；箭头向右表示收起，箭头向下表示展开，必须和文件夹使用同一逻辑。
- 文件夹本身始终以列表行展示；列表/平铺切换只改变相册内容，不把文件夹行变成平铺卡片。
- 列表模式下文件夹内相册保留层级缩进；平铺模式下文件夹内相册的左右宽度、上下间距要与普通/共享相册一致，不得因为嵌套容器产生更窄卡片。
- 列表/平铺切换按钮是整个相册区域的统一按钮，应放在标题同一行的右上角，不能单独占一行。
- 平铺列数必须由实际可用宽度计算，不能只依赖会保留旧行高的自适应布局。切换列数后要同步更新行高/网格身份，避免出现“有高度但内容空白”或顶部大面积空白。
- 双指张开应增加列数/放大，双指捏合应减少列数/缩小；平铺卡片的点击必须等手势判定结束后再触发，不能放大后误进入相册。
- 列数是用户设置，要用持久化值保存；进入相册时不能重置为默认列数。普通、共享和文件夹内容的切换规则要保持一致。
- 更新列表时只显示轻量状态，不插入会改变滚动位置的 loading 区域。

## 详情页分页：必须保持连续可滑动

- 不要用动态变化的绝对索引 `TabView` 页面窗口来实现详情分页。页面集合变化后，SwiftUI 的 `TabView`/内部 `UIPageViewController` 可能与 selection 失步，典型症状是第一次能滑、第二次卡住。
- 当前系统滑动样式使用 `NativePhotoPager` + UIKit `UIPageViewController`。分页控制器保留当前页及前后邻页，使用 delegate 的 `didFinishAnimating` 唯一地更新 `currentIndex`，不要在动画中立即把 selection 归中。
- 外部胶片点击跳转也必须经过同一个 UIKit 分页控制器；要有重复 programmatic transition 保护，不能在图片下载导致的多次 SwiftUI 更新中重启动画。
- `viewControllerBefore`/`viewControllerAfter` 在边界返回 `nil`；不能创建负索引或超范围页面。
- 未整理详情页仍按元数据页懒加载，缺少资产时显示占位页；资产到达后只更新对应页面，不重置分页控制器。
- 系统样式不要再叠加自定义水平 `DragGesture`。自定义淡入、推入、缩放样式可以使用单独的自定义 pager，但要保证一次手势只推进一次索引。
- 图片自身的单指拖拽不能在 1 倍缩放时注册为有效手势，否则会抢走详情分页。当前规则是 1 倍时把单指滑动交给分页，只有缩放大于约 1.01 倍后才允许图片平移。
- 双指缩放、放大后的平移和单指分页必须互斥；切页或页面消失时必须清除 `isZooming`，不能让旧页的缩放状态阻塞新页。
- `AssetImageView` 不要给每张图片单独加 opacity 淡入。详情页的切换动画由 pager 统一负责，否则会出现一张滑动、一张淡入的割裂效果，尤其是 iCloud 图片返回时更明显。
- 详情页底部操作栏保持单行旧样式，只调整 spacing/padding；不要用覆盖整块画布的毛玻璃容器或额外手势层影响分页命中区域。
- 图片可以延伸到全屏，但关闭、信息、全屏等控制必须在安全区域内，不能被状态栏、灵动岛、Home Indicator 或底部黑边遮挡。
- 下拉退出必须是幂等操作：退出开始后锁住关闭按钮、分页和控制层，关闭 `fullScreenCover` 自带的交互式下拉，避免自定义退出与 UIKit 转场同时运行。
- `fullScreenCover` 的 `onDisappear` 可能在系统退出转场刚开始时触发；不能在那里把下拉偏移、缩放或其他视觉状态瞬间复位，否则系统转场会出现闪屏。退出期间保留最后一帧，下一次进入时再初始化状态。
- 详情展示期间要让底层相册网格进入 inactive 状态，暂停其交互和图片请求；确认退出后可立即恢复底层滚动交互，视觉转场仍由详情页完成，`onDismiss` 只做最终清理，避免用户退出后还要等待才能滑动。
- 详情返回时不要因为 `isActive` 恢复就无条件对相册网格调用 `reloadData()`；这会清掉已经显示的缩略图并重新显示 loading，和全屏退出动画叠加成闪屏。未变化的数据应保留可见 cell，只恢复取消的请求；数据源变化时才整体刷新。
- `NativePhotoPager` 销毁时先解除 `UIPageViewController` 的 delegate/dataSource；未整理详情的分页元数据请求必须用代次校验，页面消失后丢弃旧回调。

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
- TestFlight 与手机本地安装是两条流程。上传 TestFlight 前必须递增 `CURRENT_PROJECT_VERSION`，并以命令行上传成功标志为准；不要因为本地安装成功就宣称 TestFlight 已上传。
