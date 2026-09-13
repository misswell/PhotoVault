# PhotoVault 性能排查与优化报告

目标：**能缓存则缓存，快速加载快速显示**。本报告记录这一轮对 10 万张量级图库、
iCloud、局域网文件夹相册三条主链路的排查结论与已落地的优化。

所有改动均已通过构建验证（模拟器 Debug、真机 Debug、真机 Release 三种配置，
**零 error、零 warning**）。

---

## 0. 验证结果

| 配置 | 命令目标 | 结果 |
|---|---|---|
| 模拟器 Debug | `generic/platform=iOS Simulator` | `** BUILD SUCCEEDED **`，0 warning |
| 真机 Debug | `generic/platform=iOS` | `** BUILD SUCCEEDED **`，0 warning |
| 真机 Release | `generic/platform=iOS`，Release | `** BUILD SUCCEEDED **`，0 warning |

排查过程中顺手清掉了 15 条 Swift 6 并发警告（`PhotoIndexStore` 的回调跨队列）、
1 条 `PhotoImageManager` 的非 Sendable 捕获警告。这些警告在 Swift 6 语言模式下会变成
error，属于必须偿还的技术债。

改动范围：13 个源文件，+1343 / −325 行。后续的冷启动专项（第 0.5 节）再改 3 个源文件，
+364 / −102 行。

---

## 0.5 冷启动耗时专项（真机实测）

用户反馈「打开后进图库，有时不到 1 秒，有时要转三五秒」。这一节是那一条的实测复盘，
结论和上面的常规优化不同：**瓶颈不在缓存命中率，而在启动期 PhotoKit 请求的排队方式**。

### 测量方法

`PhotoVaultLaunchClock` 给出进程内毫秒偏移，`photoVaultTraceLaunch` 把启动阶段写入
独立文件 `Library/Caches/PhotoVaultLaunch.log`（每次进程追加一个用 PID 标记的区块，
不受主诊断日志 512 KB 滚动影响）。拉取：

```bash
xcrun devicectl device copy from --device <id> \
  --domain-type appDataContainer --domain-identifier com.misswell.PhotoVault \
  --source Library/Caches/PhotoVaultLaunch.log --destination /tmp/PhotoVaultLaunch.log
```

真机（iPhone 15 Pro，图库 104,458 张）实测时间线，修改前后各取一次：

| 阶段 | 修改前 | 修改后（典型） |
|---|---|---|
| `.task` 进入 `store.start()` | +156ms | +111~144ms |
| 启动窗口 fetch 完成（网格首帧） | **+2890ms** | **+407~1105ms** |
| 完整图库（104k）发布 | +3437ms，且与相册元数据一起发布，实际等到 **+6057ms** | **+778~1559ms** |
| 相册元数据（163 个） | +6057ms | +10572ms（已不阻塞网格） |

### 三个真实缺陷

1. **首帧被同步 XPC 挡住。** `authorizationStatus` 的属性初始化式直接调
   `PHPhotoLibrary.authorizationStatus(for:)`，在 SwiftUI 第一次求值 body 时同步执行。
   改为从 `UserDefaults` 取上次结果做种子，`start()` 里再读真值纠正，首帧不再等 PhotoKit。

2. **一个很小的请求排在两个大请求后面。** 原实现把「512 条本地标识符的启动窗口」
   和「整库排序 fetch + 163 个相册元数据」同时打给 `photolibraryd`。实测启动窗口
   被拖到 2.9s，而它本身只是几百条数据。改成：**启动窗口独占，解析完成后才发起**
   整库 fetch、相册扫描和变更观察者注册。

3. **完整结果发布被相册枚举拖住。** 原来 `allPhotos` 和 `albums` 在同一个主线程回调里
   赋值，所以 104k 张的网格要等 163 个相册查完。现在整库结果一物化就单独发布，
   相册元数据随后补上（侧栏用上次快照先撑着）。

另外把启动窗口的实现从「持久化 512 个 local identifier，再逐个回查」改成
**同一个查询加 `fetchLimit`**。两者在冷守护进程下都受同一次唤醒开销支配，但按标识符
逐个回查在库还没打开时可能返回空集，会让网格一直停在转圈；有限范围扫描不会。

### 一个改不掉的部分

真机冷启动第一次 PhotoKit 调用本身要 **2.9~4.4s**，这是 `photolibraryd` 冷启动的固定
开销，与查询形态无关（换两种查询都一样）。同一次测量里，紧随其后的整库排序 + 物化
104k 只要 1.0~1.4s，说明守护进程一旦热起来就很快。实测守护进程至少能保持 120 秒不冷：

| 场景 | 首次调用耗时 |
|---|---|
| 装完新包后的第一次启动 | 4445ms |
| 之后立刻重启进程 | 1105ms / 538ms / 407ms |
| 空闲 120 秒后重启进程 | **429ms** |

所以「每次打开都快」的剩余部分是**环境相关的**：只有守护进程真被回收时才会付那 3~4s。
要在这条路径上也做到「瞬开」，只能完全不依赖 PhotoKit 画首屏（落盘缩略图 + 持久化
标识符快照先渲染一屏、再用真数据替换）。这是产品取舍，未在本轮实施。

---

## 1. 图片加载与缓存（收益最大的一环）

### 1.1 网格缩略图缓存（`gridThumbnailCache`）

**问题**：`UICollectionView` 回收 cell 时，`PhotoGridCell.configure` 会先清空图片、
显示 loading、再发一次 PhotoKit 请求。用户来回滚动时，**刚看过的缩略图也要重新请求**，
表现为滚动时满屏转圈。

**修复**：新增独立的 `NSCache`（与查看器缓存分离，避免 10 万张缩略图挤掉全屏大图）：

- `PhotoImageCacheScope.gridThumbnail`，网格 cell 与详情页胶片条都走它
- cell 复用时**先同步探测缓存**，命中就立刻显示、不显示 loading
- 回调里用 `representedIdentifier` **和** `representedTargetSize` 双重校验，
  且绝不用 nil 覆盖已显示的缩略图（防止晚到的旧回调把画面打回空白）

容量按物理内存分档（`countLimit` / `totalCostLimit`）：24MB/600、36MB/900、48MB/1200。

### 1.2 解码分道（`PhotoDecodeLanes`）

**问题**：`preparingForDisplay()` 预解码原本在一条串行队列上跑。预解码是重活
（一张 2048px 图约 10–30ms），多张图排队时，先到的图会被后面的图堵住，
手指已经滑到下一张、上一张还在解码队列里等。

**修复**：2–4 条串行解码队列（按 CPU 核数），**按缓存 key 哈希分道**：

- 同一个「资产 + 目标尺寸」永远落在同一条道 → `degraded` 低清帧一定先于全清帧写入缓存，
  顺序不会被打乱
- 不同资产并行解码 → 总吞吐提升到接近核数倍

### 1.3 缓存窗口的归属

按项目红线，PhotoKit 的 `startCaching` / `stopCaching` 只由预取数据源管，
cell 里不再逐个调用。这一轮补齐了 `IndexedPhotoGridView` 的预取代理实现：

- `prefetchItemsAt` / `cancelPrefetchingForItemsAt` 落地
- `updateCachingWindow(in:)` 取 **预取索引 ∪ 可见索引** 的并集作为缓存窗口
- 翻页淘汰、`dismantle`、数据源变更时同步收缩窗口

### 1.4 后台释放策略（纠正一处越界）

之前把 `gridThumbnailCache` 也划进了「后台保留」的集合。网格缓存可达 24–48MB，
后台常驻有被 jetsam 杀掉的风险，且与项目红线（后台只保留 16MB 的
`albumThumbnailCache`）不符。已改回：**后台只保留相册缩略图缓存**
（并把三档容量统一到 16MB，回到红线规定的上限），网格与查看器缓存全部释放。

---

## 2. 数据层与索引

### 2.1 库变更通知的合并（H1 / H2）

**问题**：`photoLibraryDidChange` 每收到一次通知就跑一遍「全量资产抓取 → 相册元数据重扫 →
索引同步」。启动时 iCloud 同步、批量导入、连续截图会产生**成串**的通知，
后一个把前一个正在跑的最贵任务取消重来，启动窗口内反复空转。

**修复**：

- 「合并窗口」：资产增量（`PHChange`）立即应用，昂贵的相册元数据重扫推迟 0.4s，
  窗口内的多次通知只跑最后一轮
- 「脏位」：全量刷新进行中再收到通知，只置 `pendingRefreshAfterFetch`，
  当前这轮跑完后再补一轮，不再中途重启

### 2.2 相册缓存编码移出主线程（H3）

`saveAlbumCache` 原本在主线程上把整个相册/文件夹树 JSON 编码后写 `UserDefaults`，
而这正好发生在变更热路径上。已改为纯值函数 `Self.encodeAlbumCache(...)`，
在后台队列编码，主线程只做 `UserDefaults.set`。

### 2.3 文件夹子集合只抓一次（M5）

`fetchAlbums()` 里每个文件夹的子集合被 `PHCollection.fetchCollections(in:)` **抓了两遍**
（一遍识别子文件夹、一遍构造相册）。带文件夹的库上这直接把 PhotoKit 往返翻倍。
已改为抓一次存入 `childrenByFolderID` 复用。

### 2.4 主线程视图投影的缓存（H-首页）

- `topLevelAlbums` 每次访问都重建一遍「所有嵌套文件夹 ID」的 Set。
  已改为 `albumFolders` 赋值时算一次存进 `nestedAlbumIDs`
- `recycleBinIDs` 同样加了 `recycleBinIDSet`，`isInRecycleBin` 保持 O(1)
- 新增 `albumStructureRevision`（`albums` / `albumFolders` 赋值时自增），
  让视图能凭一个廉价 token 缓存派生结果

### 2.5 索引库（`PhotoIndexStore`）

| 项 | 问题 | 修复 |
|---|---|---|
| 启动预览查询 | `readRecentAssetIdentifiers` 的 `ORDER BY creation_date` 无索引支撑，执行计划是 `SCAN + USE TEMP B-TREE FOR ORDER BY`（全表 + 临时 B 树排序） | 新增 `asset_index_creation(creation_date DESC, asset_id DESC)`，直接服务该 ORDER BY |
| 成员枚举排序 | `makeMediaOptions()` 带 `creationDate DESC` 排序，而枚举只用来插 ID——PhotoKit 为一次纯插入把整个相册（智能相册就是全库）排了一遍 | 去掉 sort descriptor |
| 每次启动全文件扫描 | `PRAGMA quick_check` 在**每次打开**索引库时扫描整个文件 | 只在**上次进程非正常退出**（`-wal` 残留非空）时做完整性检查；DDL 阶段报错时再兜底修复一次，所以损坏仍能自愈 |
| 读连接无 busy timeout | 写入端 checkpoint 期间读连接拿到 `SQLITE_BUSY` 就失败，被迫走更慢的写连接兜底 | `sqlite3_busy_timeout(handle, 2000)`（读写两条连接都加） |

---

## 3. 详情页与幻灯片

### 3.1 每次滑动重建三个全屏页（H）

**问题**：`refreshPages` 无条件给当前页 ±1 重新赋 `rootView`。给 `UIHostingController`
换 `rootView` 等于把整棵 SwiftUI 树丢掉重建；胶片条 scrub 时每一帧都要重建三个全屏页。
更糟的是 scrub 分支在 `displayedIndex` 更新后**又调了一次** `refreshPages`
（与本次 update 开头那次完全重复），使每帧重建量翻倍。

**修复**：

- 给每个页面记录「内容身份」（资产 ID + 目标尺寸 + contentMode），
  **身份未变就不重建**
- 删掉 scrub 分支里重复的那次 `refreshPages`
- 淘汰 `pages` 时按键逐个移除，不再用 `filter` 重建整个字典

### 3.2 优先级翻转导致的请求重发

`AssetImageView` 的 `.task(id:)` 里带了 `requestPriority.rawValue`。详情页每次切页
都会把一张图从「邻页」提升为「当前页」（或反向），优先级一变 task id 就变，
于是**取消一个正在进行的全尺寸 PhotoKit 请求、再发一个完全一样的**。

已把 `requestPriority` 从 task identity 中移除：优先级只影响请求发出时的排队位置，
后续变化不再触发重发。

### 3.3 幻灯片分页器的迟到回调

`IndexedSlideshowAssetPager.loadPage` 的完成回调没有「页面是否还在」的校验。
幻灯片退出后落地的回调仍会执行 `updatePrefetch()`，**启动一批新的、允许联网的全尺寸请求**
——而这些请求再也没人取消。

已加 `isVisible` + `loadGeneration` 双重校验，`onDisappear` 里先失效再拆预取窗口。
同时把逐条写 `assetsByIndex` 改为整批赋值：一页 60 条原本触发 60 次父视图 `@State` 写入。

### 3.4 空转的 PhotoKit 缓存调用

两个幻灯片分页器的 `stopCaching` 用的是 `prefetchTargetSize`，
但预取实际用的是 `fullPrefetchTargetSize`，尺寸对不上 → **从来没匹配到任何缓存窗口**，
纯属每次切页都空跑一次 PhotoKit 调用 + 两次字典分配。已删除这套死代码
（连同只被它读取的 `cachedNeighbors`）。

### 3.5 索引进度不再拖累整树

**问题**：`indexProgress` 是每秒最多 4 次的 `@Published`。它和 `albums` 挂在同一个
`ObservableObject` 上，于是**只要扫描在跑，首页、网格、设置面板每秒重建 4 次**，
哪怕它们根本不显示进度。

**修复**：进度搬到独立的 `PhotoIndexProgressReporter: ObservableObject`。
只有真正显示进度的两处（未整理页的工具栏标题、DEBUG 性能面板）单独观察它，
其余视图不再被扫描进度唤醒。`PhotoLibraryStore.indexProgress` 保留为只读转发。

---

## 4. 首页侧栏

### 4.1 派生投影的重复计算

侧栏在一次 `body` 求值里会读 `visibleAlbums` / `visibleRegularAlbums` /
`visibleSharedAlbums`，每个都独立跑一遍**带 locale 感知的 `localizedCaseInsensitiveContains`
全量过滤**——一次 body 就是 5 遍。而双指缩放时 `@GestureState` 让整个 body 每帧重算一次。

已引入 `SidebarDerivationMemo`（存 `@State` 的引用类型，写入不触发 SwiftUI 刷新）：

- 相册匹配结果按 `albumStructureRevision + 搜索词` 缓存
- 文件夹扁平化结果按 `albumStructureRevision + 列表/平铺 + 展开集合` 缓存
- 一次 body 求值只算一遍

### 4.2 变更通知里的视图脏写

- `refresh()` 里有一句 `if albums.isEmpty && albumFolders.isEmpty { albums = []; albumFolders = [] }`
  —— 赋的是同样的空数组，纯属连发两次 `objectWillChange`。已删
- `persistChangeToken` 每次都往 `UserDefaults` 写一遍 library signature，
  而这份签名索引自己存在 `meta` 表里，**从来没被读回来过**。已删

---

## 5. 随机整理（Organizer）

- **欢迎页大图每次出现都换一张**：`.onAppear` 和每次 `recycleBinIDs` 变化都调
  `choosePreviewAsset()` 随机抽一张全库照片，并以 `.viewer` 优先级请求**全屏尺寸**的 iCloud 图。
  已改为：**选择是稳定的**（当前资产仍有效就不换），只有回收站真的把当前大图收走时才重选；
  一轮整理结束时（用户主动触发）才强制换一张
- **优先级降级**：装饰性大图从 `.viewer` 改为 `.photoGrid`，不再抢占真正的详情页请求

---

## 6. 局域网文件夹相册

### 6.1 诊断日志的写放大（严重）

`LANFolderDiagnostics.appendToFile` 原本**每写一行日志就读入整个文件（最多 256KB）
再原子重写**，而且持锁。日志可能从主线程调用，等于主线程上做 256KB 读 + 256KB 写。

已改为持有 `FileHandle` 追加写，只在跨过容量上限时裁剪一次（保留尾部），
单行成本降到一次 `write`。

### 6.2 取消语义（`LANFolderLoadWaiter`）

原来的 `LANFolderCancellationFlag` 每个请求一个取消标志，被取消的请求仍要走完
信号量闸门再判断，等于白占一个并发槽位（槽位只有 3 个，SMB 读是网络往返）。

已改为 `LANFolderLoadWaiter`：幂等 `resume`，取消时**直接脱离等待并 resume nil**；
`process` 在完全没有等待者时跳过闸门，且拿到槽位后再复核一次。

### 6.3 内存缓存按用途拆分

原 `LANFolderImageCache` 是单一缓存。网格缩略图和查看器全尺寸图混在一起，
后者会把前者挤出去。已拆成：

- `thumbnailCache`：64MB / 400 条
- `fullSizeCache`：72MB / **6 条**（以 1024pt 为界判断是否全尺寸）

### 6.4 其他

- 枚举时顺手把已经查到的 mtime 记进 `knownModificationDates`，
  避免落盘缓存命中前为同一文件再查一次 `resourceValues`
- 落盘缓存命中后补 `preparingForDisplay()`
- `LANFolderSessionCache` 改为存 `rootURL` + `files`，
  二次进入直接回放（不解析书签），并修正了 `rootURL` 回退值
  （原来回退成 `fileURL`，导致磁盘缓存 key 全部塌缩成 `MD5("")`）
- `LANFolderScopeManager.activate` 不再持锁跨 `startAccessingSecurityScopedResource()`
- 网格 `ForEach` 改用 `files.indices`，不再 `Array(files.enumerated())` 全量物化
- 后台时清空 `LANFolderImageCache`

### 6.5 诊断桩的开销（Release 也中）

`PagerDiagnostics.log` / `LANFolderDiagnostics.log` 的 Release 版本是空函数，
但**调用点的字符串插值照样执行**——详情页 scrub 每帧都在拼字符串然后丢掉。
已改为 `@autoclosure`，Release 下不构造字符串；DEBUG 下的 `logURL` 也从
每次调用查 `FileManager` 改为 `static let` 只解析一次。

---

## 7. 排查后判定为「不是问题」的项

诚实记录，避免后续重复排查：

- **胶片段用 `UICollectionViewFlowLayout` 承载 10 万个 item**：Flow Layout 只为可见矩形
  计算 attributes，是惰性的；`contentSize` 用 `CGFloat` 表示 510 万点没有问题。
  这是系统相册同款做法，**不需要改成手写布局**。
- **`usesPhotoKitCaching: false` 出现在相册行缩略图**：与 `AGENTS.md` 明文规定一致
  （「相册行缩略图统一走 `albumThumbnailCache`（… `usesPhotoKitCaching: false`）」），
  不是违规。
- **`readStats()` 的两次 `COUNT(*)`**：覆盖索引扫描，10 万条约 3ms，只在写入结束时调用，
  不在热路径上。收益不足以承担改计数器的风险。
- **分页 `OFFSET`**（10 万条 offset 约 3ms）：桌面实测可接受，改成 keyset 分页需要动所有调用方，
  本轮不做，列在下面的「后续可做」。
- **`LANFolderThumbnailDiskCache` 的 `directory(for:)` 每次建目录**、**磁盘缓存 LRU 上限**、
  **局域网详情页/幻灯片 `Task.detached` 预取在退出时未取消**：都是真实问题但收益较小，
  且改动面在已经稳定的 LAN 链路上，本轮未动。

---

## 8. 后续可做（按收益排序）

1. **分页改 keyset**：`unsortedIdentifiers` 的 `OFFSET` 换成 `(creation_date, asset_id)` 游标，
   深翻页从 O(offset) 降到 O(log n)。
2. **`readStats` 增量计数**：把 `assetCount` / `unsortedCount` 维护在 `meta` 表里随事务更新。
3. **局域网查看器/幻灯片的预取取消**：`onDisappear` 里 cancel 掉 `Task.detached` 的预读。
4. **局域网缩略图磁盘缓存加 LRU + 容量上限**：目前只有「删除相册时同步清理」。
5. **相册选择器/搜索结果页的投影也走 `SidebarDerivationMemo`**：目前只有侧栏做了。
6. **`AlbumGrid` 的 `.id("album-grid-columns-…")` 重建**：双指缩放跨越列数边界时
   会重建整个 `LazyVGrid`。当前已把每帧 body 成本压下来，且缩略图命中缓存后有同步兜底，
   所以留作后续；若要彻底解决需把捏合手势状态搬进 `AlbumGrid`（会改变手势的实时反馈范围，
   属于交互改动，不适合在没有真机手感验证的情况下改）。

---

## 9. 涉及文件

- `PhotoVault/PhotoImageManager.swift` — 网格缓存、解码分道、后台释放策略、
  启动时钟与 `PhotoVaultLaunch.log`
- `PhotoVault/PhotoGridView.swift` — cell 缓存优先、预取代理、缓存窗口
- `PhotoVault/PhotoViewerViews.swift` — 页面身份复用、优先级、幻灯片可见性守卫、诊断桩
- `PhotoVault/AssetImageView.swift` — task identity 去掉优先级
- `PhotoVault/PhotoLibraryStore.swift` — 变更合并/脏位、编码移出主线程、投影缓存、进度拆对象、
  启动窗口独占与整库结果提前发布、授权状态落盘做种子
- `PhotoVault/PhotoIndexStore.swift` — 新索引、去排序、完整性检查门控、busy timeout、回调装箱
- `PhotoVault/ContentView.swift` — 侧栏投影缓存、进度独立观察
- `PhotoVault/PhotoGridScreen.swift` — 进度独立观察
- `PhotoVault/RandomPhotoOrganizerView.swift` — 稳定欢迎图、优先级降级
- `PhotoVault/LANFolderAlbum.swift` — 日志追加写、等待者取消、缓存拆分、mtime 复用
- `PhotoVault/LANAlbumViews.swift` — 会话缓存回放、ForEach 优化、rootURL 修正
- `PhotoVault/PhotoVaultApp.swift` — 后台清理 LAN 内存缓存
- `PhotoVault/Models.swift` — 文件夹模型辅助
- `AGENTS.md` — 同步更新局域网缓存/取消的实现约定
