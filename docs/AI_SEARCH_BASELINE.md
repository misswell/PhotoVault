# PhotoVault 本地 AI 智能照片搜索 — 工程基线审查（Phase 0）

- 审查日期：2026-09-13
- 审查对象：`/Users/guofeng/Code/solo/PhotoVault`（git root 为 `/Users/guofeng/Code`）
- 审查方式：只读代码审查 + 构建验证 + 模型元数据核实，**未修改任何现有源文件**
- 对应方案：`AI 智能照片搜索完整开发方案`（下称"方案"）第 2 节要求
- 基线构建状态：✅ `xcodebuild -scheme PhotoVault -configuration Debug -destination 'generic/platform=iOS'` **BUILD SUCCEEDED**（真实签名，Apple Development 身份，非 `CODE_SIGNING_ALLOWED=NO`）

---

## 0. 结论摘要

| 项 | 结论 |
|---|---|
| 现有工程是否支持叠加 AI 搜索 | ✅ 支持。三层都有干净插槽：导航入口、`PHFetchResult` 图片通路、独立 SQLite 索引库 |
| 是否需要重构无关模块 | ❌ 不需要。方案 §13 的"不动无关模块"可以实现 |
| 现有搜索能力 | 仅"相册标题匹配 + 年份/媒体类型谓词"，**没有**自由文本、OCR、地点、人脸 |
| 是否已有 SQLite 索引 | ✅ 有，`PhotoIndex.sqlite` schema v2，独立库、独立读写连接、增量同步机制成熟 |
| 是否已有 Vision / Core ML / Metal | ❌ 全部不存在，全部是新代码 |
| Deployment Target | iOS / iPadOS **26.0**（方案 §10 的"不要为 Background Assets 提升最低版本"约束天然满足） |
| SigLIP2 授权与规模 | ✅ Apache-2.0；FP32 权重 **1.501 GB**；两塔输出均为 **768 维**（已由 safetensors header 独立核实） |
| **模型体积 / 分发** | ✅ 技术风险已消除：**W8 实测 376.3 MB**，parity 与 nDCG 质量门均通过（损失 0.06%）。是否接受 376 MB 属产品决策（R1 / D1） |
| 转换正确性 | ✅ **已结清**：FP32 Core ML 对全部 57 图 / 50 查询 cosine = **1.000000**；FP16 真实照片 0.999817；W8 0.999072（R2） |
| 量化 | ✅ **已打通**，并记录了最反直觉的坑：Vision 位置编码被折叠成常量后会被量化，单它一个就足以把图像 embedding 打到 0.93（R3） |
| 下一道门 | 真机 ANE 实测（compute unit 分布 / 首次加载 / 峰值内存）——Mac 数据不能替代 |

---

## 1. 当前工程架构

### 1.1 构建与工程配置

| 项 | 值 | 位置 |
|---|---|---|
| Target | 单一 `PhotoVault` app target，`com.apple.product-type.application` | `project.pbxproj:96-114` |
| 测试 target | **不存在**（全工程 0 处 `XCTest`） | — |
| 工程生成方式 | **无 XcodeGen**（无 `project.yml`）、无 `Package.swift`；`project.pbxproj` 为手工维护，显式 `PBXBuildFile`/`PBXFileReference`，ID 形如 `A10000000000000000000001` | `project.pbxproj:9-53` |
| `objectVersion` | 77 | `project.pbxproj:6` |
| 源文件清单 | 13 个 `.swift` + `Info.plist` + `Assets.xcassets`，全部显式登记在 pbxproj | `project.pbxproj:10-23` |
| Deployment Target | `IPHONEOS_DEPLOYMENT_TARGET = 26.0` | `project.pbxproj` |
| Swift | `SWIFT_VERSION = 6.0`（Swift 6 语言模式 ⇒ 严格并发检查已生效，现有代码靠 `@unchecked Sendable` + GCD 通过） | `project.pbxproj` |
| Bundle ID | `com.misswell.PhotoVault` | `project.pbxproj` |
| 版本 | `CURRENT_PROJECT_VERSION = 28`；`CFBundleShortVersionString` 硬编码 `1.0` | `project.pbxproj` / `Info.plist` |
| 签名 | `CODE_SIGN_STYLE = Automatic`，`DEVELOPMENT_TEAM = U8U443D7ZL` | `project.pbxproj` |
| 设备族 | `TARGETED_DEVICE_FAMILY = "1,2"`（iPhone + iPad） | `project.pbxproj` |
| Entitlements | **无** `.entitlements` 文件 | — |
| 隐私清单 | **无** `PrivacyInfo.xcprivacy` | — |
| 备用图标 | `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES = "AppIconLight AppIconDark"` | `project.pbxproj` |

源码规模（含未提交改动）：

```
PhotoViewerViews.swift        4705
PhotoGridView.swift           1988
ContentView.swift             1769
PhotoLibraryStore.swift       1765
LANAlbumViews.swift           1340
PhotoIndexStore.swift         1269
RandomPhotoOrganizerView.swift 1235
PhotoGridScreen.swift          983
LANFolderAlbum.swift           937
PhotoImageManager.swift        771
AssetImageView.swift           385
Models.swift                   321
PhotoVaultApp.swift             32
                             -----
                             17500
```

**工作区状态警告**：整棵 Swift 源码树处于**未提交**状态（相对 `HEAD` 共 14 文件、+1276 / −294 行），且 git root 是 `/Users/guofeng/Code` 这个巨型 monorepo（工作区里还有 `cscec3b`、`react-native/demo` 等大量无关改动）。任何提交都必须**按 `solo/PhotoVault/` 路径限定**，禁止 `git add .`。

### 1.2 入口与 App 生命周期

`PhotoVaultApp`（`PhotoVaultApp.swift:7-31`）：

- `WindowGroup { ContentView() }`
- 内存警告 → `PhotoImageManager.shared.stopCachingAll()`（`:11-17`）
- `scenePhase`：**只对 `.background` 反应**（`.inactive` 明确忽略，`:24`）→ `dropTransientCaches()` + `LANFolderImageCache.shared.removeAll()`（`:19-30`）
- **无** `BGTaskScheduler`、无 `beginBackgroundTask`、无 `UIBackgroundModes`

对方案的直接影响：方案 §15/§20/§49 要求"App 被杀死后继续索引""设备空闲时继续处理"，**必须新增 `BGProcessingTask`**（需要 `Info.plist` 增加 `BGTaskSchedulerPermittedIdentifiers` + `UIBackgroundModes: processing`）。这是新能力，不是可选优化。

### 1.3 导航与页面结构（新入口的插槽）

- 根视图：外层 `TabView`，`enum RootTab { case library, organizer }`（`ContentView.swift:26-29`）
- 主体：`NavigationSplitView(columnVisibility:)`（`ContentView.swift:159`），侧栏 `List(selection: $selection)`（`:160`）
- 侧栏分组行：`.home` / `.library` / `.unsorted` / `.lan`（`ContentView.swift:161-182`），其后是文件夹 / 普通相册 / 共享相册分组（`:184-228`）
- 目标枚举：`enum PhotoSection: Hashable { case home, library, unsorted, lan, album(String), search(String) }`（`Models.swift:184-191`）
- 详情分发：`detailView` 对上述 case 穷举切换（`ContentView.swift:576-637`）；**`.lan` 分支外面包了一层专属 `NavigationStack`**——这是 AGENTS.md 明确记录的必需补丁（compact 宽度下 pop 会毁掉 split view 状态），改造 `detailView` 时不得去掉

**插入"智能搜索"页的最小改动面**（3 处 + 2 处可选）：
1. `Models.swift:184-191` 加 `case smartSearch`
2. `ContentView.swift:161-182` 加一个 tagged 侧栏行
3. `ContentView.swift:576-637` 加一个 detail 分支
4. 可选：`PhotoVaultStartupDestination`（`Models.swift:278-296`）+ 设置里的启动页 Picker（`ContentView.swift:1604-1635`）

现有搜索（**与 AI 搜索不是同一件事，不要混改**）：

- `.searchable(text:placement:.navigationBarDrawer(displayMode:.always), prompt: "搜索相册或照片")` 挂在侧栏（`ContentView.swift:232-236`）
- `.onSubmit(of: .search)` → 去空白 → `selection = .search(query)`（`:237-241`）
- `PhotoSearchResultsScreen`（`ContentView.swift:971-1039`）：先按标题大小写不敏感匹配 `store.albums`（`:1016-1018`），再走 `PhotoSearchKind`（`:1041-1094`）——`image/video/favorite` 关键词或 4 位年份 1900–2100 → 拼 `NSPredicate` 直接 `PHAsset.fetchAssets(with:)`（`:1026-1033`），**不经过 SQLite 索引**
- 结论：中文自由文本（"海边的狗"）目前**完全搜不到**，会落到空结果 `ContentUnavailableView`（`:1002`）

### 1.4 数据层：`PhotoLibraryStore`

- `@MainActor final class PhotoLibraryStore: NSObject, ObservableObject, PHPhotoLibraryChangeObserver`（`PhotoLibraryStore.swift:106-107`）
- 重活跳 `DispatchQueue.global(qos:)`（`:297`、`:934`），主线程只做发布
- `@Published` 反应面（`:108-150`）：`authorizationStatus`、`allPhotos: PHFetchResult<PHAsset>?`、`albums`、`albumFolders`、`albumStructureRevision`、`isIndexingUnsorted`、`isLoadingAlbums`、`lastIndexedAt`、`unsortedCount`、`indexStats`、`indexErrorMessage`、`quickAlbumIDs`、`recycleBinIDs`；进度走独立的 `PhotoSearchIndexProgressReporter`（`:12-14`），经节流器 `publishIndexProgress`（`:1474-1483`，≤4 次/秒，阶段切换必发）
- 图片结果集：**全程 `PHFetchResult<PHAsset>`，从不物化成 `[PHAsset]`**（AGENTS.md 硬约束）；`assets(in:)` 按相册 ID 缓存 `PHFetchResult`（`:493-508`，上限 64）
- 相册快照持久化：`UserDefaults` + `Codable`，key `PhotoVault.photoLibrary.albumSnapshot.v1`（`:163`，`PhotoAlbumCacheSnapshot.currentVersion = 1`，`Models.swift:52-57`）；启动预览窗口 key `…launchPreviewAssetIDs.v1`（512 条，`:164`）
- 增量同步：`PHPersistentChangeToken` 持久化在 `UserDefaults`（`:162`、`:1670-1689`）→ `fetchPersistentChanges(since:)`（`:1496`）→ 收集 insert/update/delete → `upsertAssets`；token 抛错则兜底全量重建（`:1500-1505`）。**AGENTS.md 明确规定：不得用库签名去否决 token**
- 变更合并：`photoLibraryDidChange`（`:838-842`）→ `enqueuePhotoLibraryChange` 0.4s 合并（`:849-860`）；相册元数据重扫独立合并（`:917-967`），数量用 `estimatedAssetCount` + `fetchLimit = 1` 预览（`:1221-1240`）
- 后台/前台切换：`suspendForBackground()` / `resumeAfterBackground()`（`:234-265`）

### 1.5 索引层：`PhotoIndexStore`（新 AI 索引的最佳模板）

- `final class PhotoIndexStore: @unchecked Sendable`，直连 `import SQLite3`（`PhotoIndexStore.swift:3`、`:47`）
- 连接模型：**私有写队列** `queue`（`.utility`，`:63-66`）+ **独立读队列** `readQueue`（`.userInitiated`，`:67-70`）；`database` / `readDatabase` 两个 `OpaquePointer`
  - 读连接**必须以 READWRITE 打开**，否则无法做 WAL 恢复（`hasUsableIndex` 的 fallback 注释 `:165-177`）
  - 读失败必须兜底重试写连接
- 库位置：`Application Support/PhotoVault/PhotoIndex.sqlite`（`:48`、`:77-85`）
- PRAGMA（`:1067-1070`）：`journal_mode = WAL`、`synchronous = NORMAL`、`foreign_keys = ON`、`auto_vacuum = INCREMENTAL`；`busy_timeout = 2000`（`:1066`）
- 损坏自愈：`-wal` 非空 ⇒ 疑似上次进程被杀 ⇒ `PRAGMA quick_check`（`:1075-1077`、`:1161-1183`），失败则 drop 全部表（数据可重建，不碰用户 Photos）
- schema v2（`:1100-1123`）：

```sql
meta(key PK, value)
asset_index(asset_id PK, creation_date, modification_date, media_type,
            media_subtype, favorite, album_count)
album_index(album_id PK, title, type)
album_asset(album_id FK, asset_id FK, PRIMARY KEY(album_id, asset_id))
```

- 索引（`:1128-1134`）：`asset_index_unassigned_ordered(album_count, creation_date DESC, asset_id DESC)`、`album_asset_asset(asset_id)`、`asset_index_creation(creation_date DESC, asset_id DESC)`
- schema 版本不匹配 ⇒ drop 表重建（`:1087-1094`）
- 代次守卫：`setActiveGeneration` / `checkGeneration` 抛 `CancellationError`（`:104-120`）——**新的 AI 索引必须沿用这个模式**，否则旧任务回调会覆盖新状态
- 后台 checkpoint：`incremental_vacuum(256)` + `wal_checkpoint(TRUNCATE)`（`:126-147`）
- 乐观更新：`removeAssets(assetIDs:)` 删除后立刻反映（`:304-340`），配合变更观察者幂等收敛

**缺口**：`asset_index` **没有** `latitude` / `longitude` / `pixel_width` / `pixel_height`。方案 §12 的 `ai_asset` 已自带这些列，因此**不需要改 `asset_index`**（见 §6 数据迁移）。

### 1.6 图片加载层：`PhotoImageManager`

- `final class PhotoImageManager`，**不是 actor、非 `@MainActor`、未标 `Sendable`**；`nonisolated(unsafe) static let shared`（`PhotoImageManager.swift:345-357`）
- 持有单个 `PHCachingImageManager`（`:350`）
- 调度器：`PhotoRequestScheduler`（`@unchecked Sendable` + serial `stateQueue`，`:126-144`），并发上限 **6**（`:144`），优先级 + 序号 FIFO 排水（`:282-329`）；解码独立 2–4 条串行 lane（`:97-116`）
- 优先级枚举：`viewer=0, slideshow=1, photoGrid=2, visibleGrid=3, nearGrid=4, background=5`（`:69-80`）；`.background` **从未被任何调用点使用**
- 请求参数（`:485-491`）：`deliveryMode` / `resizeMode` / `isNetworkAccessAllowed` / `isSynchronous = false` / `progressHandler` / `version = .current`；默认 `.opportunistic` + `.fast`（`:451-452`）
- 缓存：3 个 `NSCache`（`:353-355`），成本按物理内存分档（`:370-412`）——普通 48/64/80MB、相册缩略图 16MB、网格 24/36/48MB；`stopCachingAll()` 清全部并取消所有请求（`:672-678`），`dropTransientCaches()` 保留 16MB 相册缓存（`:688-693`）
- **预解码红线**：回调里统一 `image?.preparingForDisplay() ?? image`，在解码 lane 上执行后才进缓存/回调（`:524-525`）——AI 索引取图时**必须复用这条路径**，否则会把懒解码图像抛给主线程
- **缺口**：manager 层**没有 in-flight 请求去重**，只有调用点自己的字典（`PhotoViewerViews.swift:3838-3872`）。AI 索引要并发取 256pt 缩略图，必须自己按 assetID 去重

索引取图的现成契合点：方案 §16 要求"请求接近 256×256 的缩略图"。现有网格缩略图 bucket 已是 `160/256/384/512`（`PhotoGridView.swift:51-65`），`targetSize` 由调用点决定，`isNetworkAccessAllowed` 也是调用点参数 —— **AI 索引只需以 `isNetworkAccessAllowed = false` 调 `requestImage(targetSize: 256×256, priority: .background …)` 即可满足方案 §16/§17**。

### 1.7 现有 Photos 权限处理

- 读：`PHPhotoLibrary.authorizationStatus(for: .readWrite)`（`PhotoLibraryStore.swift:108`、`:223`）
- 请求：`PHPhotoLibrary.requestAuthorization(for: .readWrite)`（`:44`）
- Limited Access：**已支持** —— `canReadPhotos` 接受 `.authorized || .limited`（`:187-189`）；仅在 `.limited` 时显示"管理照片访问权限"工具栏按钮（`ContentView.swift:281-288`），触发 `presentLimitedLibraryPicker(from:)`（`PhotoLibraryStore.swift:1446-1458`）
- 拒绝 / 未决定：`PhotoPermissionView`（`ContentView.swift:1417-1440`）——未决定给"请求访问"，否则"打开设置"（`:1432-1436`）
- `Info.plist` 现状（**需要按方案 §61 改写文案**）：
  - `NSPhotoLibraryUsageDescription` = "PhotoVault 需要访问照片，用于展示图库、相册和未整理照片。"（未提及本地索引与不上传）
  - `NSPhotoLibraryAddUsageDescription` = "PhotoVault 需要写入照片库，用于创建相册、整理照片和保存编辑结果。"

---

## 2. 可以复用的模块

| 方案里的模块 | 复用方式 | 依据 |
|---|---|---|
| `IndexScheduler` / `IndexCheckpoint` | **照抄 `PhotoIndexStore` 的骨架**：写队列 + 独立读队列 + `activeGeneration` 代次守卫 + `-wal` 非空触发完整性检查 + 后台 checkpoint | `PhotoIndexStore.swift:63-70`、`:104-120`、`:126-147`、`:1161-1183` |
| `PhotoSearchIndexCoordinator` 的增量驱动 | 直接复用 `PHPersistentChangeToken` 流水线（insert/update/delete 集合已现成） | `PhotoLibraryStore.swift:1485-1549`、`:1670-1689` |
| 变更合并/节流 | 复用 0.4s 合并 + `publishIndexProgress` 的 ≤4 次/秒 节流思路 | `PhotoLibraryStore.swift:849-860`、`:1474-1483` |
| `PhotoAssetLoader` | 复用 `PhotoImageManager.requestImage`（含 `preparingForDisplay()` 预解码） | `PhotoImageManager.swift:447-459`、`:524-525` |
| 搜索结果的网格展示 | 复用 `PhotoGridScreen` + `PhotoGridView` + `PhotoGridCell` | `PhotoGridScreen.swift:5`、`PhotoGridView.swift:318`、`:917` |
| 搜索结果的详情页 + 胶片条 | 复用 `PhotoViewerView` + `ViewerFilmstrip` + `ViewerFilmstripCell` | `PhotoViewerViews.swift:1403`、`:2000`、`:2313` |
| 侧栏入口 / 设置面板 | 复用侧栏 `List` + `PhotoVaultSettingsView` 的 `Form`/`Section` 模式 | `ContentView.swift:160-228`、`:1539-1758` |
| 调试面板 | 复用 `#if DEBUG DebugPerformanceView` 的工具栏按钮 + sheet 模式 | `ContentView.swift:1460-1537`（入口 `:289-304`） |
| 本地目录 | 复用 `Application Support/PhotoVault/`（AI 库放同目录，见 §6 的备份注意事项） | `PhotoIndexStore.swift:77-85` |

### 2.1 关于 `PHFetchResult` 直通（**本审查最重要的复用结论**）

`PhotoGridScreen` / `PhotoGridView` / `PhotoViewerView` / `ViewerFilmstrip` 唯一的数据源抽象就是 `PHFetchResult<PHAsset>` + `initialIndex: Int`；`NativePhotoPager` 的抽象只有 `pageCount` + `assetProvider: (Int) -> PHAsset?`（`PhotoViewerViews.swift:399-403`、`:1286-1289`）——**没有任何协议层**。

因此只要 `PhotoSearchEngine` 的结果 ID 列表能变成 `PHFetchResult`，网格、详情、胶片条**零改动**即可复用：

```swift
PHAsset.fetchAssets(withLocalIdentifiers: rankedIDs, options: nil)
```

⚠️ **必须在真机上先验证一件事**：该 API 是否保留传入 ID 的顺序。若保留 ⇒ 上述直通方案成立，可省掉一整套新的分页网格/详情/胶片条（约 2k 行）。若不保留 ⇒ 需要新增"有序 ID 结果"的分页三件套（`IndexedPhotoGridView` / `IndexedAssetPager` / `IndexedViewerFilmstrip` 的克隆或泛化，`PhotoGridView.swift:1180`、`PhotoViewerViews.swift:2453`、`:2816`）。

⚠️ 注意不要为了 AI 搜索去泛化现有的 `Indexed*` 三件套：那条链路背后是"未整理"页面的多个已修复真机 bug（AGENTS.md 有整节记录），改动风险远大于收益。

---

## 3. 需要新增的模块

对照方案 §11 的文件清单，逐项定性：

| 方案文件 | 定性 | 备注 |
|---|---|---|
| `Model/AIModelManager.swift` | 新增 | 模型存在性/校验和/manifest/版本比对（方案 §66） |
| `Model/SigLIPImageEncoder.swift` | 新增 | Core ML 封装；`MLModel` 非 Sendable，需 actor 或锁边界 |
| `Model/SigLIPTextEncoder.swift` | 新增 | 同上 |
| `Model/SigLIPProcessor.swift` | 新增 | resize/中心裁剪/RGB/mean-std 归一化，必须与 Python `AutoProcessor` 逐位对齐（方案 §5） |
| `Model/SentencePieceTokenizer.swift` | 新增 | Gemma sentencepiece，**vocab 256000**；`tokenizer.model` 需随包发布 |
| `Index/PhotoSearchIndexCoordinator.swift` | 新增 | 状态机 Idle→Preparing→IndexingEmbedding→IndexingOCR→Completed（方案 §20） |
| `Index/PhotoAssetLoader.swift` | 新增（薄封装） | 包 `PhotoImageManager`，强制 `isNetworkAccessAllowed = false`（方案 §17） |
| `Index/ImageEmbeddingIndexer.swift` | 新增 | 第一遍 |
| `Index/OCRIndexer.swift` | 新增 | 第二遍；Vision **全新引入** |
| `Index/MetadataIndexer.swift` | 新增（可复用 `asset_index` 读） | 但 `ai_asset` 需自带 GPS/尺寸 |
| `Index/IndexScheduler.swift` | 新增 | 优先级队列 + 热/电量降级（方案 §21） |
| `Index/IndexCheckpoint.swift` | 新增 | 见复用表：照抄 `PhotoIndexStore` 骨架 |
| `Storage/SearchDatabase.swift` | 新增 | 独立库 `AIPhotoSearch.sqlite`，**不动 `PhotoIndex.sqlite`** |
| `Storage/EmbeddingStore.swift` | 新增 | `embeddings-v1.bin` + header + mmap + free list（方案 §13/§14/§67） |
| `Storage/OCRStore.swift` | 新增 | + FTS5（**需真机验证 trigram 可用性**，见 R12） |
| `Storage/IndexMigration.swift` | 新增 | 模型版本升级双缓冲（方案 §15） |
| `Search/QueryAnalyzer.swift` ~ `SearchEngine.swift`（9 个文件） | 全部新增 | 方案核心差异化；纯 Swift，无外部依赖 |
| `Location/OfflineGazetteer.swift` / `LocationMatcher.swift` | 新增 | 需选数据源并核对商用许可（方案 §35） |
| `UI/SmartSearchView.swift` 等 4 个文件 | 新增 | 复用 §2 的网格/详情/设置模式 |
| `Benchmark/SearchBenchmarkRunner.swift` / `SearchMetrics.swift` | 新增 | 需 200→500 条标注 query（方案 §55/§56），**标注数据是人力成本** |
| Metal 检索 kernel | 新增 | `.metal` 文件 + `MTLDevice`/`MTLBuffer`；Accelerate/vDSP fallback（方案 §38/§39） |
| `BGProcessingTask` | 新增能力 | `Info.plist` 改动 + 后台模式声明（方案 §15/§20） |

工具链侧（方案 §5，已开始搭建）：

```
tools/models/
├── requirements.txt          ✅ 已建（含版本锁定理由）
├── requirements-lock.txt     ⏳ pip freeze 产出
├── convert_siglip2.py        ⏳
├── verify_siglip2.py         ⏳
├── benchmark_siglip2.py      ⏳
├── model_manifest.json       ⏳
└── README.md                 ⏳
```

**工程构建负担**：`project.pbxproj` 是手工维护的显式引用清单，上述新增意味着 **约 35 个 `.swift` + 1 个 `.metal` + 2 个 `.mlpackage` + 1 个 `.model` 词表**要登记进去。手工编辑 40 个条目（`PBXBuildFile` + `PBXFileReference` + group + Sources/Resources phase）出错率很高，建议脚本化（见 §11 待决策 D3）。

---

## 4. 数据迁移影响

**结论：对现有数据零迁移风险。**

| 关注点 | 影响 |
|---|---|
| `PhotoIndex.sqlite` schema v2 | **不修改**。AI 数据全部落在新库 `AIPhotoSearch.sqlite` + `embeddings-v1.bin`。方案 §12 的 `ai_asset` 自带 `latitude/longitude/pixel_width/pixel_height`，恰好补齐了 `asset_index` 的缺口，因此不需要 `ALTER TABLE` |
| 用户已有数据 | 无破坏性变更；AI 库可随时删除并从 Photos 重建 |
| 首次升级体验 | 唯一"迁移"是首次全量 AI 索引，必须后台渐进、可暂停、可中断（方案 §15/§19/§20），且不阻塞现有功能 |
| 模型版本升级 | `embeddings-v1.bin` → `embeddings-v2.bin` 双缓冲 + 原子切换（方案 §15） |
| `UserDefaults` | 新增 key 建议沿用现有命名空间风格 `PhotoVault.aiSearch.*` |
| **iCloud 备份** | ⚠️ 现有 `PhotoIndex.sqlite` 未设置 `isExcludedFromBackup`。新的 `embeddings-v1.bin` 在 100k 照片下约 150MB，**必须排除出备份**，否则会污染用户 iCloud 备份配额。方案未提及，列为新增待办 |
| Photos 权限文案 | `Info.plist` 两个 usage description 需按方案 §61 更新（提及本地处理、不上传） |

---

## 5. Deployment Target 与平台能力

- 现状 `IPHONEOS_DEPLOYMENT_TARGET = 26.0`，**不需要为任何新能力提升最低版本**。
- 方案 §10 的约束原文是"不要为了 Background Assets 强制把最低版本提升到 iOS 26"——本项目**本来就在 26.0**，因此：
  - Apple-Hosted Background Assets **可作为备选**，且不构成"提升最低版本"（V1 仍按方案走 Bundle，见 §11 待决策 D1）。
  - `BGProcessingTask`（后台索引续跑）、ANE/Core ML、`ProcessInfo.thermalState`、`isLowPowerModeEnabled` 全部可用。
- Swift 6 严格并发已生效：新代码必须并发正确（`actor` 或 `@unchecked Sendable` + 锁，与现有风格一致）。

---

## 6. 已有数据库方案（供新库对齐）

| 维度 | 现有 `PhotoIndex.sqlite` | 新 `AIPhotoSearch.sqlite` 应对齐 |
|---|---|---|
| 位置 | `Application Support/PhotoVault/` | 同目录（+ 排除 iCloud 备份） |
| 连接 | 写队列 + 独立读队列（READWRITE） | 一致，方案 §68 的 serial writer + 只读 mmap 正好对应 |
| PRAGMA | WAL / NORMAL / foreign_keys ON / incremental_vacuum | 一致 |
| 事务粒度 | 批量（方案 §69 建议 20–100） | `PhotoIndexStore` 内已按批提交，可照抄节奏 |
| 完整性 | `-wal` 非空 ⇒ `quick_check` ⇒ drop 重建 | 一致；embedding 文件另有 header 校验（方案 §67） |
| 代次守卫 | `activeGeneration` + `checkGeneration` | 必须沿用 |
| 版本策略 | `meta.schema_version` 不匹配 ⇒ drop 重建 | 方案 §15 要求更温和：保留旧索引直到新索引可用 |

---

## 7. 模型与依赖核实（已独立验证，非推测）

方案 §3 指定的 `google/siglip2-base-patch16-256`：

| 事实 | 值 | 验证方式 |
|---|---|---|
| License | **apache-2.0** ✅（满足方案 §3/§4 商用要求） | HF model API `cardData.license` |
| 权重格式 | 单个 `model.safetensors` | HF API siblings |
| 权重大小 | **1,500,985,224 B = 1.501 GB**（方案所述"约 1.5GB"准确） | HTTP `x-linked-size` |
| dtype | 全部 `F32` | safetensors header |
| 张量数 | 408 | safetensors header |
| **Vision 塔** | 371.7 MB FP32（≈93M 参数） | safetensors header |
| ├ 层数 | **12** | 权重 key 枚举 |
| ├ hidden | 768 | `patch_embedding.weight [768,3,16,16]` |
| ├ patch / image | patch16 / image 256 ⇒ 16×16 = 256 token | `position_embedding.weight [256,768]` |
| └ head | **MAP attention-pooling**：`head.probe [1,1,768]`、`head.attention.in_proj_weight [2304,768]`（3×768）、`head.mlp.fc1 [3072,768]` | safetensors header |
| **Text 塔** | **1129.2 MB FP32（≈282M 参数）** | safetensors header |
| ├ 层数 | **12** | 权重 key 枚举 |
| ├ hidden | 768 | `final_layer_norm.weight [768]`、`head.weight [768,768]` |
| ├ **max_position_embeddings** | **64**（与方案 §5 一致） | `position_embedding.weight [64,768]` |
| ├ vocab | **256000** | `token_embedding.weight [256000,768]` |
| └ 词表单独大小 | **786.4 MB FP32**（占 Text 塔 70%） | 计算 |
| **Embedding 维度** | **两塔均 768**（方案 §9 要求由脚本回读验证，已先静态核实为 768） | safetensors header |
| 对比损失参数 | `logit_scale [1]`、`logit_bias [1]`（SigLIP sigmoid loss 的 `logit = dot·scale + bias`） | safetensors header |
| Tokenizer | `GemmaTokenizer`（sentencepiece `tokenizer.model` + `tokenizer.json`），`do_lower_case = true`，`clean_up_tokenization_spaces = false`，bos/eos/pad/unk，额外特殊 token `<start_of_turn>` / `<end_of_turn>` | `tokenizer_config.json` / `special_tokens_map.json` |
| Preprocessing | `SiglipImageProcessor`：resize → **256×256**，rescale 1/255，mean/std 全 0.5，`resample = 2`（bilinear），`do_convert_rgb = null` | `preprocessor_config.json` |

### 7.1 已在 Phase 1 查清的转换约定（**不得再猜，已逐条实测**）

方案 §5 说"不要自己猜 preprocessing"，§7 给了排查清单。以下是清单里几项在本 checkpoint 上的**实测结论**，全部写进了 `tools/models/siglip2_reference.py` 并由 `verify_siglip2.py` 断言：

| # | 结论 | 证据 |
|---|---|---|
| 1 | `config.json` 只有 **276 字节**，仅含 `vocab_size` 与 `image_size`；层数/hidden/`max_position_embeddings` 全部来自 `SiglipConfig` 类默认值。已用 safetensors header 独立核实默认值与权重一致（12/12 层、64/256 位置、768 hidden），转换脚本仍**从权重回读并断言** | 权重张量名与形状枚举 |
| 2 | **`AutoModel` 解析为 `SiglipModel`（v1 类），不是 `Siglip2Model`** —— 因为 checkpoint 的 `model_type` 就是 `"siglip"`。这是正确的：v1 的 vision transformer 在 config 缺少 `vision_use_head` 时会实例化 MAP head，而 checkpoint 确实带 `vision_model.head.*` 权重。验证脚本额外证明 v1 与 v2 类输出逐位一致 | `AutoConfig` 解析结果 + `SiglipModel.__init__` 源码 + 类间 cosine 对比 |
| 3 | **文本必须显式传 `max_length`**：tokenizer 的 `model_max_length` 是 `1e30` 哨兵值，官方 model card 那句 `padding="max_length"` **会静默变成不 padding**（transformers 只打一条 warning）。必须传 `max_length = text_config.max_position_embeddings`（=64） | 实测：不传时返回长度 2 |
| 4 | **pooling 取最后一个位置，无论它是 pad 还是 eos**：tokenizer 先追加 `<eos>`(id 1)、再右侧补 `<pad>`(id 0)，所以短文本的第 63 位是 pad。这是**有意设计**——SigLIP/SigLIP2 训练时**不使用 attention mask**，转换模型的维护者明确确认"last position, regardless whether it's a pad or eos"（[transformers#39269](https://github.com/huggingface/transformers/issues/39269)）。**推论：Text Encoder 不需要 attention mask，输入是完全静态的 `[1,64]`，这对 Core ML/ANE 是最理想形态** | 上游 issue 结论 + 实测 token id |
| 5 | **checkpoint 的 `do_convert_rgb` 是 `null`**，被当作 falsy ⇒ **RGBA 输入直接报错** `Unable to infer channel dimension format`。PhotoVault 的截图正是 RGBA —— 必须在 Swift/Python 两侧都先转 RGB 并显式传 `do_convert_rgb=True`（对已是 RGB 的输入逐位等价） | 实测：RGBA 截图传入即抛错 |
| 6 | **resize 是直接 256×256 拉伸**（`resample=2` bilinear），**不保持长宽比、无中心裁剪** | `preprocessor_config.json` + processor 源码 |
| 7 | 归一化 = ×1/255 后 `(x−0.5)/0.5` ⇒ 值域 **[−1,1]**；实测输出 min −1.0 / max 1.0 | 实测 |
| 8 | 中文可直接编码：`"海边的狗"` → 3 个内容 token + EOS。**无需中→英翻译**（方案 §32 ✓） | 实测 token id |
| 9 | slow / fast tokenizer 输出完全一致；`sentencepiece` 的 `tokenizer.model` 是 Swift 移植的权威来源 | 50 条对照 |

**由此确定的两条 Core ML 设计约束**（已写入 `convert_siglip2.py`）：

- Image Encoder 输入用 **`MLMultiArray [1,3,256,256]` float32**，不用 Core ML 的 image 输入类型——image 类型自带色彩空间/缩放语义，无法与 `SiglipImageProcessor` 逐位对齐；用我们自己算出的张量，parity 失败就只可能是模型本身。
- Text Encoder 输入是 **`[1,64]` int32 的 token ids，无 attention mask**，且 **batch 固定为 1、全部形状静态**（不用 enumerated shapes）。

### 7.2 网络与工具链现状（已实测）

**重要更正**：本机 `curl` 与 Python 的可达性**不一致**——macOS 配了系统级 HTTP/HTTPS 代理（`127.0.0.1:7890`，见 `scutil --proxy`），Python 的 `requests`/`urllib` 会通过 System Configuration API 自动读取，而 `curl` 不会。因此"HF 被墙"的第一印象是错的。

| 项 | 状态 |
|---|---|
| `huggingface.co` via **curl** | ❌ 超时（HTTP 000）——curl 不走系统代理 |
| `huggingface.co` via **Python** | ✅ HTTP 200，~0.5s——通过系统代理 |
| `hf-mirror.com` | ✅ 可用，但**不需要**；其 `/resolve/` 的 HEAD 会 308 跳回 huggingface.co，反而会破坏 `huggingface_hub` 的元数据请求 |
| 通用网络（apple.com / github.com via curl） | ✅ 200 |
| **`hf-xet` 传输** | ⚠️ **必须禁用**：`HF_HUB_DISABLE_XET=1`，否则下载 1.5GB 权重时 `OSError: I/O error: Permission denied (os error 13)`；纯 HTTP 正常 |
| 硬件 | Apple M1 / 16 GiB / 磁盘可用 52 GiB |
| Xcode | 26.3 (17C529) |
| 系统 Python | `/usr/bin/python3` 3.9.6（含过旧的 torch 2.0.1 / transformers 4.30.2，**不支持 SigLIP2**） |
| Homebrew Python | `/opt/homebrew/bin/python3.12` 3.12.2 ✅ |
| 工具链 venv | `tools/models/.venv` ✅ 已建（torch 2.5.0 / transformers 4.53.3 / coremltools 9.0） |
| 模型权重 | ✅ 已下载到 `tools/models/cache/siglip2-base-patch16-256`（1.501 GB，已 gitignore） |
| 真机 | iPhone 15 Pro (iPhone16,1)，已配对可用 |

**版本修正**（相对方案与初次判断）：

- `transformers` 必须 ≥ **4.51**，不是 4.49：**4.49.0 根本没有 `siglip2` 模块**（已实测）。方案 §5 说的 `AutoProcessor.from_pretrained(...)` 在 4.49 下会解析到 v1 类；本项目锁定 **4.53.3**。
- `coremltools` 锁 **9.0**：8.3 的最高部署目标是 iOS18，9.0 才认识 **iOS26**（与本项目最低版本一致）。9.0 还重命名了量化入口（`op_linear_quantizer` → `linear_quantize_weights`），转换脚本同时兼容两种写法。
- `torch` 锁 **2.5.0**：coremltools 明确警告 2.5.1 "has not been tested"，2.5.0 是它测过的最后一版。
- Python 必须 **3.12**（coremltools 9.0 wheel）；系统 3.9.6 无法使用。

---

## 8. 潜在风险

按"是否阻塞 Phase 1 起步"排序。

### R1 —【中｜交付形态待决，技术风险已消除】App 体积与分发

原估算已被 Phase 2 的**实测**取代（`tools/models/README.md` 有完整数据与复现命令）：

| 方案 | Vision | Text | 合计 | 图像 parity(真实照片) | 文本 parity | nDCG@20 损失 |
|---|---|---|---|---|---|---|
| FP32（对照） | 369.5 MB | 1129.3 MB | 1498.8 MB | 1.000000 | 1.000000 | 0% |
| FP16 | 184.8 MB | 564.8 MB | 749.6 MB | 0.999817 | 0.999999 | 0% |
| **W8** | 93.0 MB | 283.3 MB | **376.3 MB** | **0.999072** | **0.999050** | **0.06%** |

**原估算基本准确（预估 ≈380 MB，实测 376.3 MB），且 W8 的质量门已通过**（方案 §6 的 1.5% nDCG 预算，实测 0.06%）。因此 §11 D1 的选项 (a) **技术上是可行的**，"必须接受质量下降才能换体积"这个二选一并不存在。

剩下的是纯产品决策，不再阻塞工程：376 MB 的 Bundle 在蜂窝下载与更新成本上仍是显著负担。若要进一步压缩，候选顺序为
- (b) 词表裁剪（256k → 数万）：需 parity + 质量回归，属方案扩展，需用户同意；
- (c) Apple-Hosted Background Assets（本项目已是 iOS 26，无需提升最低版本）。

**注意**：Text 塔的 283.3 MB 里 196.6 MB 仍是 256k×768 的 int8 词表，所以 (b) 是唯一能再砍掉大块体积的路径。

### R2 —【已解决｜Phase 2】转换正确性

已用可复现的方式结清，而非"看起来跑通了"：

- **FP32 Core ML 对 57 张图 + 50 条查询全部 cosine = 1.000000** —— 逐位复现 PyTorch 参考。这才是把 FP16/W8 的残差解释为"精度损失"而不是"转换错误"的依据。
- FP16：真实照片 min 0.999817（方案 §7 要求 ≥0.999 ✓）。
- 每个 checkpoint 张量都必须被模型消费（`_assert_all_weights_consumed`），漏掉 MAP head 也能产出有限、归一、看起来正常的向量——**这个检查是硬失败，不是警告**。
- 三层信息面：`architecture`（fixed-resolution `SiglipModel`，**不是** naflex 的 `Siglip2Model`）、`preprocessing`（转换约定）、`parity`（实测值）全部写进 `model_manifest.json`，Swift 侧读 manifest，**业务代码不得硬编码维度**。

### R3 —【已解决｜Phase 2】量化与 Core ML 友好度

- ~~动态形状~~ → 已排除（§7.1 第 4 条：无 attention mask、静态 `[1,64]`）。
- ~~embedding 表需要单独 palettize~~ → **不需要**。`linear_quantize_weights` 对 `gather` 权重做的 per-channel int8 就是"每行一个 scale"，实测文本 cosine 0.9993，是正确方案。**反而不能**再叠一层 palettization（会把已 int8 的权重二次量化，白掉约 1.5 个点的文本 cosine，且不省体积）。
- **⚠️ 新增的、最反直觉的坑：Vision 位置编码会被折叠成常量并被量化。** 追踪时 `position_ids` 是常量，gather 消失，位置编码变成 `[1,256,768]` 常量喂给 `add`，而 `linear_quantize_weights` 照样量化它。**单独量化这一个张量就把图像 embedding 打到 0.966（均值 0.957）**——正好解释了第一次 W8 实测的 0.932。修法是按**消费者算子类型**筛选常量：只量化被 `linear`/`conv`/`gather` 消费的常量，喂给 `add`/`mul`/`reshape`/`transpose` 的一律留 FP16（两个塔的位置编码都在排除名单里，且每次转换都打印跳过清单）。
- 需澄清的一点：**Vision 塔本身并不脆弱**。整体随机扰动 0.1% 只损失 0.00004 cosine，1% 损失 0.011。之前的失败是**单个特定张量**，不是架构特性。
- 仍未验证：**ANE 的 compute unit 分布必须真机实测**（Xcode Core ML 性能报告）。Mac 上 W8 在 CPU_ONLY / CPU_AND_GPU / ALL 三个 unit 下结果一致（0.9316 / 0.9322 / 0.9316，修复后 0.9991），既说明不是某个 kernel 的锅，也不能替代真机结论。

### R4 —【中｜Phase 4】100k 检索性能结论不能靠 M1 Mac 推断

方案 §54 明确"不得只在 Mac Simulator 测性能"。算力上 100k×768 的 FP16 精确点积在现代 iPhone（内存带宽 ~100 GB/s、矩阵 153.6 MB）理论下界约 1.5 ms，Metal 实现 + top-k 选择预计 5–20 ms，方案 §52 的 P50 < 500 ms 有充足余量；真正的风险在 mmap 首次 page fault 与"搜索期间索引写"的并发（方案 §68）。CPU fallback（Accelerate/vDSP，76.8M MAC）也可行，**禁止** Swift 双层循环（方案 §39）。

### R5 —【中｜Phase 3】iOS 内置 SQLite 的 FTS5 与 trigram

- 方案 §25 依赖 `fts5(tokenize='trigram')`。iOS 系统 SQLite 是否编译 FTS5 与 trigram tokenizer **必须真机验证**（`CREATE VIRTUAL TABLE … USING fts5(…)` 试建 + `PRAGMA compile_options`）。
- 方案 §25 自己也指出 trigram 对 2 字中文（"发票""报销"）不适用，并给了 `instr(normalized_text, ?) > 0` fallback——这个 fallback 必须**无条件实现**，不能寄希望于 trigram。

### R6 —【中｜Phase 3/11】无测试 target

全工程 0 处 `XCTest`。方案 §7（parity 测试）、§55–§57（benchmark）、§82（DoD）都需要**可重复的自动化验证**。当前唯一的自动化载体只能是 Python 侧 + `#if DEBUG` 面板。建议新增一个 XCTest target（见 §11 D3）。

### R7 —【中｜贯穿全期】pbxproj 手工维护

见 §3 末段：约 40 个新增资源条目的登记，必须脚本化。

### R8 —【中｜Phase 3–4】Swift 6 严格并发 + Core ML 非 Sendable

`MLModel`、`MLFeatureProvider`、`MTLBuffer` 都不是 Sendable；`PhotoImageManager` 本身也不是 actor。新代码需要明确的隔离边界（建议 `actor` 持有模型与 buffer，或 `@unchecked Sendable` + 锁，与 `PhotoIndexStore` 风格一致）。

### R9 —【低中｜合规】隐私清单与 Info.plist

- 无 `PrivacyInfo.xcprivacy`。App 已上架（build 28 在改），使用 `UserDefaults`、文件时间戳等 required-reason API。新增 AI 功能虽不上传数据（方案 §59/§60），但隐私清单与 usage description 文案仍需按方案 §61 补齐。
- `THIRD_PARTY_NOTICES.md` 尚不存在，需新建（方案 §4/§35/§82）。

### R10 —【低中｜Phase 10】后台续跑需要新能力

无 `BGTaskScheduler`。方案 §15/§20/§49 的"App 被杀死后继续""空闲时继续"需要 `BGProcessingTask` + `Info.plist` 声明。属于新增能力而非冲突。

### R11 —【低｜Phase 8】离线地名库的商用许可

方案 §35 要求核对 GeoNames 等数据许可并保留 attribution。GeoNames 使用 CC BY 4.0（需署名），且不同数据集条款不同 —— 选型前必须逐项确认并写入 `THIRD_PARTY_NOTICES.md`。

### R12 —【低｜Phase 3】embedding 文件的备份与淘汰

`embeddings-v1.bin`（100k ≈ 150 MB）必须 `isExcludedFromBackup`；删除照片后 slot 回收（free list）与"文件尾部空洞"的 `count`/`capacity` 语义要和 DB 状态严格一致（方案 §14/§67）。这是数据一致性最容易出 bug 的地方，需要专门的调试工具来校验（建议放进 Debug 面板）。

### R13 —【低｜流程】未提交工作区

见 §1.1 警告。现有 1276 行未提交改动 + monorepo 工作区。建议在动工程代码前先按路径做一次基线提交（见 §11 D2）。

---

## 9. 与方案的差异 / 需要方案确认的点

| # | 方案原文 | 基线审查发现 | 建议 |
|---|---|---|---|
| 1 | §13 "Embedding 存 Float16[DIMENSION]，DIM=768 ⇒ 1536 B/张，100k ≈ 146–154 MB" | 计算正确（768×2 = 1536 B；100k = 146.5 MB） | 无需变更 |
| 2 | §16 "请求接近 256×256 的缩略图" | 现有网格 bucket 已有 256 档，可直接复用 | 无需变更 |
| 3 | §10 "V1 模型随 Bundle，不要为 BA 提升最低版本" | 本项目已在 iOS 26.0，BA 可用且无需提升最低版本 | 保留 V1 Bundle，但把 BA 作为体积兜底（D1） |
| 4 | §11 模块清单 | 与现有工程无命名冲突；`Search/` 与 `Storage/` 全为新目录 | 按方案命名，便于对照 |
| 5 | §12 `ai_asset` schema | 自带 GPS/尺寸，恰好不触碰 `asset_index` | 无需变更 |
| 6 | §55/§56 benchmark 200→500 条 | 需要人工标注"相关照片"作为 ground truth | **人力成本，需要用户参与或指定标注来源** |
| 7 | §13/§14 embedding 与 `PhotoIndex.sqlite` 关系 | 方案未说明两者是同一个库还是分开 | 建议**分库**（AI 库可独立删除/重建/升级，不污染已验证的 v2 库） |

---

## 10. Phase 0 验收

- [x] 完成现有工程架构审查（导航 / 数据 / 图片 / 索引 / 权限 / 并发 / 生命周期）
- [x] 完成"可复用模块 / 需新增模块"清单
- [x] 确认 Deployment Target（26.0）与平台能力
- [x] 确认已有 Photos 权限处理（含 Limited Access）
- [x] 确认已有数据库方案（schema / 连接 / PRAGMA / 版本策略）
- [x] 列出潜在风险（13 项，含 1 项高危）
- [x] 数据迁移影响结论（零迁移风险；新增备份排除项）
- [x] 基线构建通过（真实签名，非跳过签名）
- [x] 独立核实 SigLIP2 授权、体积、两塔维度、tokenizer、preprocessing
- [x] **未修改任何现有源文件**

---

## 11. 待决策（影响后续 Phase）

| # | 决策点 | 选项 | 建议 |
|---|---|---|---|
| **D1** | 模型分发与体积（R1） | (a) W8 全量 Bundle **实测 376.3 MB** (b) 词表裁剪 + W8 (c) Apple-Hosted Background Assets | **已用 (a) 打通**：W8 质量门通过（nDCG 损失 0.06%）。376 MB 是否可接受属产品决策；若要再压体积，(b) 是唯一能砍掉大块的路径（int8 词表仍占 196.6 MB） |
| **D2** | 现有 1276 行未提交改动 | 先按 `solo/PhotoVault/` 路径做基线提交 / 保持不提交 | 建议先提交，避免 AI 改动与既有 WIP 混在一起 |
| **D3** | 是否新增 XCTest target（R6） | 新增 / 只用 Python + DEBUG 面板 | 建议新增：parity、metrics、embedding header 校验都需要 |
| **D4** | `project.pbxproj` 新增条目方式（R7） | 写脚本登记 / 迁移到 `PBXFileSystemSynchronizedRootGroup` | 建议写幂等脚本，不动现有工程结构 |
| **D5** | `.mlpackage` 是否入库 | gitignore + 可复现脚本 / Git LFS / 直接提交 | 建议 gitignore + 锁定 `requirements-lock.txt`，转换可完全复现 |
| **D6** | benchmark ground truth（§9 第 6 项） | 用户标注 / 半自动候选 + 人工确认 | 需要用户参与，建议 Phase 11 前单独确认 |

---

## 12. Phase 1 / Phase 2 完成情况（不触碰工程源码）

### Phase 1 — 参考实现与验证（全部完成）

- [x] `tools/models/requirements.txt` + `requirements-lock.txt`（Python 3.12.2 / torch 2.5.0 / transformers 4.53.3 / coremltools 9.0）
- [x] 网络方案确定：**直连 `huggingface.co`**（走 macOS 系统代理），**不需要** hf-mirror；`HF_HUB_DISABLE_XET=1` 规避 xet 传输的 I/O 错误（见 §7.2 更正）
- [x] 模型元数据核实（§7 / §7.1），并**下载完整 checkpoint**（1,500,985,224 B）
- [x] `siglip2_reference.py` — 唯一事实来源；`_read_facts()` 从权重回读并断言，`_assert_all_weights_consumed()` 对任何未消费张量**硬失败**
- [x] `verify_siglip2.py --mode reference` — **14/14 通过**（权重覆盖、架构身份、MAP head 确实在通路里、RGB/RGBA 陷阱、slow/fast tokenizer 一致、`max_length` 静默失效、pooling 约定、确定性、真实截图语义）
- [x] `verify_siglip2.py --mode walk` — 确定性生成 57 张图（50 合成对抗样本 + 7 张真实截图）+ 50 条中英查询的 parity fixture

### Phase 2 — Core ML 转换（全部完成）

- [x] `convert_siglip2.py` — 双塔分别导出、MultiArray 输入、batch 1 全静态、L2 归一化内置、MAP head 用显式算子重写（`nn.MultiheadAttention` 不可靠地转换）、转换后自校验
- [x] `SigLIP2ImageEncoder.mlpackage` / `SigLIP2TextEncoder.mlpackage`（FP16）
- [x] **parity 通过**：FP32 **1.000000**（逐位复现）/ FP16 真实照片 0.999817 / W8 0.999072
- [x] **W8 已打通且质量门通过**：376.3 MB，文本 nDCG@20 相对损失 **0.06%**（方案 §6 预算 1.5%），见 R1/R3
- [x] `model_manifest.json` — `embeddingDimension: 768`、输入/输出名与形状、预处理顺序、tokenizer 约定、parity 实测值；**Swift 侧读它，不硬编码**
- [x] `benchmark_siglip2.py`（吞吐/延迟/100k 检索下界/nDCG 质量门）+ `simulate_quantization.py` + `tune_quantization.py`
- [x] `tools/models/README.md` — 含复现命令、实测数据表、**量化陷阱的完整记录**

### 尚未做（属 Phase 2 的真机门 / Phase 3+）

- [x] **Tokenizer 已闭环**：`siglip2_tokenizer.py`（sentencepiece `bpe_model.cc` 的直译）+ `PhotoVault/Search/SigLIP2Tokenizer.swift` + 5.3 MB 二进制 artifact；`verify_siglip2.py tokenizer` **9/9 通过**，6194 条对抗性字符串**零差异**，真实查询 32 µs/条（对比文本编码器 10.7 ms，可忽略）
  - 关键事实（**从文件读出，非推测**）：BPE（非 unigram）、`precompiled_charsmap` **为空**（无 NFKC、**不做大小写折叠**）、`add_dummy_prefix=False`、normalizer 仅"空格→▁"、byte_fallback 开
  - 两个易错点已写进代码注释与 README：① 初始切分不是"逐字符"，而是**只用 USER_DEFINED 的 245 个 piece** 做最长前缀匹配（命中即冻结、永不合并），逐字符只是兜底；② 合并按 **piece score** 而非训练顺序，**不是**经典 rank-based BPE——照直觉重建 merge 列表会得到"看起来对、实则不同"的 token id，且不报任何错
### Phase 3 进行中 — 存储层已闭环

- [x] `PhotoVault/Search/EmbeddingStoreFile.swift`：`embeddings-v1.bin`，4096 B 头页 + Float16 行，mmap 读
  - `verify_siglip2.py embedding` **3/3 通过**：单元测试 **34/34**、10 万行精确扫描 **P50 20.3 ms**、**NumPy 独立复算 top-100 完全一致**（分数差 1.19e-7）
  - 关键设计：矩阵**保持稠密**（删除用 swap-remove，末行填洞），因为检索要连续流式扫描；代价是**槽位号不稳定**，`asset_id → slot` 只能以 SQLite 为准，且换位必须与 SQLite 行更新在同一事务
  - 头校验用 FNV-1a + dimension + model SHA 三重守卫，并设 `isExcludedFromBackup`；**损坏即重建**（与 `PhotoIndexStore` 同一哲学：这里全是派生数据）
  - 头里的模型 SHA 字段必须是**完整 64 字符**：截断的摘要仍会"不相等"，所以缩短它不会报错，只会悄悄削弱"矩阵出自当前模型"这一保证
  - ⚠️ 一个被实测纠正的错误：初版所谓"Accelerate fallback"其实是标量循环，10 万行 **62.6 ms**（比 NumPy 慢 3 倍，正是方案 §39 禁止的写法）。改为 512 行分块 `vDSP.convertElements` + `cblas_sgemv` 后降到 **20.3 ms**。另注意 `vDSP_vflt16` 是**整数** 16 位转换器，会把 IEEE half 当 Int16 读，必须用带类型的 `vDSP.convertElements`
  - `validateNormalization()` 把"行必须已归一化"这一隐含前提变成可检测的失败：`scores` 只归一化 query（模型图内已内置行归一化），一旦有未归一化的行，结果不是报错而是**排序**错，且错得与模长成正比
- [x] `PhotoVault/Search/AIPhotoSearchStore.swift`：`AIPhotoSearch.sqlite`（与 `PhotoIndex.sqlite` **分开**，AI 索引可随时丢弃/重建，零迁移风险）
  - `verify_siglip2.py index` **50/50 通过**
  - **swap-remove 契约**：矩阵靠"末行填洞"保持稠密，被移动的资产必须在**同一事务**里改 SQLite 的 `embedding_slot`。写错不会报错，只会让搜索把甲的向量当成乙的返回。测试因此不只数行数——每次删除后回读矩阵，断言**每个资产的槽位里仍是它自己的向量**（向量首分量即资产编号）
  - 两条顺序约束都是实测撞出来的：① 必须**先释放被删资产的槽位再搬迁**，否则 `embedding_slot` 的唯一索引会拒绝搬迁（同一语句里两行抢同一槽位）——唯一索引第一次运行就抓到了这个 bug；② 必须**按槽位降序删除**，否则可能搬到一个本身待删的行
  - ⚠️ `stepAndReset` 必须用**写连接**的 `sqlite3_errmsg`：从读连接取错误信息会把一次真实的 UNIQUE 约束冲突报成 `"not an error"`，比没有信息更糟
  - 候选集语义定为"**有向量**"而非"status == ready"：已成功嵌入、只是某次**重**索引失败的资产仍然持有有效向量，按 status 排除会无故丢掉一张可搜索的照片；同时强制 `model_version` 匹配（跨模型比对不是报错，是**自信的错答案**）
  - FTS 选 `tokenize='trigram'` 是为了**词内子串**匹配（分词器会把 `boardingpass2023` 当一个词，搜 `dingp` 什么也找不到）；但 trigram **无法匹配 1–2 字查询**，而二字中文（发票/报销）占真实搜索很大比例，`instr()` 兜底不是可选项。有测试专门断言 ≥3 字词能命中词内子串，避免"静默回退到 instr"让一个已死的 FTS 索引看起来是健康的
  - 读连接以 **READWRITE** 打开是刻意的（READONLY 无法做 WAL 恢复，非正常退出后所有读都会失败 → 表现为图库永久空白而非可处理的错误），并保留写连接兜底
### Phase 4 完成 — Metal 精确检索

- [x] `PhotoVault/Search/EmbeddingSimilarity.metal` + `MetalSimilaritySearch.swift`：一 thread 一行、`float4` 累加、精确点积；**矩阵零拷贝**（`makeBuffer(bytesNoCopy:)` 套在既有 mmap 上，否则每次检索要多拷 147 MiB，正是 Float16 存储想避免的）
- [x] `verify_siglip2.py metal` **31/31 通过**：3 种维度形状（含非 4 倍数走标量尾巴）、10 万行逐元素对齐、top-100 与 NumPy 已验证的排名一致、冷/热扫描均在 500 ms 预算内
- 精度：GPU vs **Double** 参考最大残差 **3.0e-7**（纯 Float32 舍入）。修这个参考值时连错两次，两次都值得记：
  1. 参考值用 **Float32** 顺序累加——三者中最不准的一个，报"GPU 差 2.7e-4"。768 项 Float32 顺序求和的极限就是 ~1e-4，而分块累加（GPU 和 BLAS 都这么做）比顺序更准；当时量的是参考值自己的误差
  2. 参考值用**原始 Float32 行**而非矩阵真正存的 **Float16 量化值**，于是在 d=4 同时"失败"GPU 和 CPU（2.7e-4）。6 项 Float32 舍入不可能到 2.7e-4（eps 才 1.2e-7）——这个量级本身就是"参考值不可达"的破绽
  - 📌 结论值得记住：**流水线里占主导的数值误差是 Float16 存储，不是求和顺序**。量级随分量大小变化：单位向量在 d=768 约 **1.65e-5**，在 d=4 约 **2.7e-4**。768 维下比任何可能改变两张不同照片顺序的间距都低两个数量级
- ⚠️ **排序一致性无法做到逐位相同**：分数完全相等时两条路径顺序一致（同一个 `selectTopK`），但差值小于 Float32 累加误差的两个分数可能顺序不同——底层浮点值确实不同，这是跨硬件计算的固有性质，不是缺陷。测试改为断言精确命题：**分歧只存在于该精度下不可区分的分数之间**
- 📊 同一预热协议下 10 万 × 768：**标量循环 68.0 ms / Accelerate 11.2 ms / Metal 7.5 ms**。GPU 只快 1.2–1.3×（Apple BLAS 已经很好，且是带宽瓶颈），保留它的理由不是速度而是**不与 UI 抢 CPU**、以及在 CPU 被热降频的设备上留余量（正是 Phase 10 的降级场景）
- ⚠️ **更正一个先前记录的错误数字**：本文件与 README 曾写 Accelerate 路径 "20.3 ms、比标量快 3 倍"——那是**冷热扫描混测**。首次扫描 192 MB 文件要缺页，实测**冷 31.1 ms / 热 P50 9.5 ms**；基准现已分别报告两者
### Phase 3 完成（模型侧）— Swift 图像编码器

- [x] `PhotoVault/Search/SigLIP2VisionEncoder.swift`；`verify_siglip2.py vision` **17/17 通过**。在此之前整条链路**没有任何办法把索引填起来**——分词器、文本塔、矩阵、检索、分析器都已各自验证，但每一个 embedding 都只能由 Python 产出
- [x] **预处理是"复现"而非"近似"**：manifest 的顺序是 convertToRGB → resize → rescale → normalize，且 resize 是**压扁成正方形**（811×2168 的截图被扭曲成 256×256，宽高比被丢弃）。参考实现如此，这里就必须如此——"改进"成保持宽高比或中心裁剪，会**静默地让每张照片的 embedding 都不同于被验证过的那个模型**
- [x] `PILResampler` 复刻了 PIL 算法，包含独立实现通常搞错的两个细节：① **大比例缩小时三角滤波核会按比例展宽**（`support × max(1, src/dst)`），从而变成面积平均滤波；只要采样最近四点的固定支撑双线性，在 2168 → 256 的缩放上会严重混叠，**嵌入参考实现从未见过的摩尔纹**；② **PIL 在每一趟之后都钳到 8 位**，并把系数量化到 22 位定点。全程用浮点**更精确**，但会得到**不同的像素**
- 🔴 **解码与重采样被分开验证**（首轮失败留下的教训）：首次运行 `.jpg` 夹具失败而 PNG **逐位一致**——这是**解码器差异**的特征，不是重采样 Bug。Apple ImageIO 与 libjpeg 的 IDCT 与色度上采样实现不同，同一张 JPEG 在缩放**之前**像素就已经不同
  - 这两类失败需要**不同的应对**，因此现在分开度量：`dump_resample_fixtures.py` 导出 PIL 解码出的**原始 RGB 字节**，把它们喂给 Swift 重采样器即完全排除解码环节
  - 📊 **判定性结果**：**同为输入像素时，57 张图重采样最大差异 0.000000——逐位一致**；完整路径上 PNG（无损）在一个 8 位色阶内；JPEG 张量余弦 0.9986–0.99999
  - 导出脚本自身对 `image_input.bin` 做自检，结果 **0.000000**，因此其夹具**可信而非仅自洽**
- ⚠️ **诚实的局限**：App 必须用平台解码器解 JPEG，因此**不可能复现 libjpeg 的像素**，而极端宽高比被压扁成正方形会放大该差异。实测最差 embedding 余弦 **0.994844**（`synthetic-001.jpg`，124×2057）。W8 转换本身的图像一致性为 0.99977（Python 预处理），故约 0.005 的差距**全部来自解码器**。阈值设在 0.99，并把实测值打印在阈值之上，使回归在触线之前就可见
- 📊 实测：热编码 **P50 52.7 ms**（CPU+GPU，macOS），首次预测 6.4 s（含 Core ML 加载与形状特化）；输出范数 0.9997647，确认转换已内嵌归一化——这正是检索侧"单次乘加"捷径所依赖的不变量
- [ ] ⚠️ 以上均为 **macOS / CPU+GPU**；真机 ANE 的算力归属、首次加载与峰值内存仍待验证

### Phase 5–8 组装完成 — 搜索引擎（端到端）

- [x] `PhotoVault/Search/PhotoSearchEngine.swift`；`verify_siglip2.py search` **46/46 通过**。八个组件首次**端到端打通**：查询字符串 → 分析器 → 地名库 → SQLite → mmap 矩阵 → 打分 → 排序后的 asset ID
- [x] **贯穿全设计的一条排序原则**：**模型决定照片"看起来像什么"；引擎决定哪些照片有资格进入候选，以及模型的判断如何组合**。`2023年在北京拍的发票` 这类查询，日期与地点**根本不进入向量扫描**——它们由 SQL 回答，文本塔只被问它擅长的那部分。**为了回答一个关于日历的问题而去给 10 万行打分，正是这套设计要防止的失败模式**
- [x] **先过滤后打分（filter-first），而不是打分后过滤**：候选在算任何向量**之前**由 SQLite 选出（新增 `EmbeddingMatrixReader.scores(query:slots:)`）。反过来做——先全局排序再剔除——在过滤条件有选择性时**返回结果会少于 K 条，而且看起来像"过滤生效了"**
- [x] **AND 是合取，不是平均**：`combine == .all` 取各子句的 **min** 而非均值。取均值会让一个强子句把完全不含另一概念的照片带出来——`猫和沙滩` 会返回室内猫。`min` 对 AND 仍是启发式（真正的 AND 需要每概念阈值），但它偏向"要求每个概念都在"，这正是用户要的
- [x] **否定是排除而非扣分**：扣分会让足够强的正子句压过"不要狗"，而这恰恰是用户明确排除的唯一结果
- [x] **未解析地名交还给模型，而不是丢弃**：丢掉它会**在看起来仍应用了约束的同时把范围放大到整个图库**。因此该提及会被**重新编码为视觉子句**并产生警告。让向量模型去猜是可恢复的，丢弃用户打的字不是
- [x] **无标记地点**：`北京 猫`、`tokyo cat` 是人真实的输入方式，而分析器需要方位词才能识别地点。地名库在引擎这一侧，因此引擎做第二遍：子句内**最长精确**地名匹配成为地点过滤，并从模型看到的文本中移除（新增 `gazetteer.resolveExact`）
  - ⚠️ 已知误判类型（**写明而非隐藏**）：地名嵌在更长的常用词里（大理石含大理、长春花含长春）。代价是结果集被不必要地收窄；要正确识别需要语言模型，而那正是要避开的东西
- 🔴 **本阶段发现两个分析器 Bug**：① `2023年拍的猫` 把 **`拍的猫`** 送进了文本塔——拍摄动词在后缀剥离时位于**中间**，只有日期被抽出**之后**才变成前缀，因而从未被移除；② `2023年拍的照片` **没有走纯元数据路径**，它编码了子句"拍"并为回答一个关于年份的问题跑了向量搜索
- [x] **测试套件经过变异校验**（46 条通过并不说明问题，如果它们不可能失败）：5 处故意破坏**全部被捕获**——AND 改用 max → 3 处失败；否定永不排除 → 1；去掉分数下限 → 6；候选不加过滤 → 4；丢弃未解析地名 → 1
- [ ] 文本塔在测试中是**打桩**的（为了使机制可被精确断言），真实模型端到端延迟属 Phase 11 基准项

### Phase 8 完成 — 日期 / GPS / 离线地名库

- [x] `PhotoVault/Search/OfflineGazetteer.swift` + `GazetteerData.swift`；`verify_siglip2.py geo` **39/39 通过**
- [x] **252 个地点**：42 个省级行政区、127 个城市、43 个国家、40 个地标；纯本地，飞行模式下可解析
- [x] **半径而非多边形**：真实边界数据集能精确回答"是否在朝阳区拍的"，但会带来几十 MB 体积、许可审查，以及在边界处以另一种方式出错。中心点 + 按 `PlaceKind` 决定的半径虽然粗，但**误差是可预测的**——在边界附近**多选**，而不是静默排除一张在看不见的线外十米的照片
- [x] **解析失败必须上报，绝不静默忽略**：分析器会抽出任何像地名的词（`在海边拍的猫`）。此时丢掉过滤条件会**悄悄把搜索范围放大到整个图库，却仍表现得像应用了约束**。因此返回 `.unknown(name)`，由调用方决定；测试断言未知地点返回**空**而不是全部
- ⚠️ **数据来源的诚实说明**：坐标是**人工整理的城市中心值，精度约 10 km**，不是测绘数据、也非导入的数据集。对城市/地标搜索半径而言足够，但**不具备权威性**。之所以不铺开大规模坐标表，是因为**错误坐标不会报错，只会静默返回错误地点的照片**。取舍是明确的：**小而有据的集合 + 可无缝替换更大数据集的加载器**（`OfflineGazetteer(entries:)` 接收数组，换数据不动逻辑）
  - 抽样对照公开来源：因特拉肯 46.6833/7.85 vs 本库 46.6863/7.8632，**相差约 1 km**。其余条目**尚未对第三方参考验证**
- [x] **三项无需参考数据即可发现错坐标的自检**（人工录入数据必须有不依赖我自己记忆的验证）：① **所有中国条目必须落在中国国界框内**——转置、符号错误、串行几乎都会跑出国界；② **十组著名城市间距离**（北京–上海 1067 km、伦敦–巴黎 344 km、纽约–伦敦 5570 km…）误差须在 8% 内；③ **每个省中心必须包含同名城市**
- 🔴 **本阶段发现并修复两个真 Bug**：
  1. **反子午线处静默丢失半个框**：`longitudeRange` 原本用 `max(-180,…)`/`min(180,…)` 夹取，区间虽然合法，但**丢掉了 ±180 另一侧的全部内容**——斐济附近的地点搜索会漏掉对面所有照片。现改为：跨越 ±180（或宽于地球）一律返回全范围。**多选可恢复，漏选不可恢复**
  2. **`New York` 被按空格切成地点 "New"**：分析器原本假设地点是第一段、其余是主语——这对 `在上海 咖啡` 成立，对任何多词地名都不成立。**名字在哪里结束是"查询"问题，不是"语法"问题**：分析器现返回完整提及，由地名库先取最长可解析**词**前缀，再取最长**字符**前缀
  - 配套调整：原先靠"首字母大写"来阻止 `in a meeting room` 被当成地点，但这同时枪毙了用户真会打的 `in new york`。现改为**拒绝前导限定词**（a/the/my…），把"到底是不是地名"的判断权交还地名库

### Phase 7 完成 — Vision OCR + FTS 混合检索

- [x] `PhotoVault/Search/PhotoTextRecognizer.swift` + `SearchTextNormalization.swift`；`verify_siglip2.py ocr` **29/29 通过**
- 🔴 **实测发现的关键约束**：`.fast` 识别级别只支持 **6** 种语言且**不含 `zh-Hans`**，`.accurate` 支持 **18** 种。对中文相册而言**根本不存在快路径**——请求 `.fast` 不是"降级"，而是**中文文本什么都识别不出来**
  - 这直接约束 Phase 10 的热降级策略：**OCR 是唯一不能"降一档"的环节**。正确做法是**推迟** OCR，而不是降低它的质量。一套"所有环节降一档"的策略会在看起来正常工作的同时，**静默停止索引中文票据**
- [x] 语言支持**运行时查询**而非硬编码：请求平台没有的语言会让 Vision **抛错**，从而整次识别失败（而不是跳过该语言）。偏好列表与实际已安装语言求交，只有英文的设备仍然可用
- [x] **两条 FTS 路径必须对同一串文本达成一致**：中文 OCR 输出常常完全没有空格，这正是不一致最容易藏身之处——查询能命中 trigram `MATCH` 却命中不了 `instr()` 兜底时，结果会**随查询长度**出现或消失。两条路径现在共用 `SearchTextNormalization`，且测试用**真实识别输出**（而非手写字符串）跑完整链路
- [x] 刻意区分：**搜索索引折叠大小写，而分词器绝不能折叠**（SigLIP2 区分 `CAT`/`cat`）。这是两件不同的事，把模型的约定套到索引上是范畴错误——store 的 `normalizeForSearch` 现在写明这一区别而不重复实现
- 📊 实测：干净小图 **P50 68 ms**（macOS），首次调用约 380 ms 用于加载模型；真机与真实照片会更慢，这里的数字界定的是**链路**而非设备成本
- [x] 识别质量：`发票 报销凭证 2023年5月`、`登机牌 Boarding Pass 北京到上海`、`微信聊天记录 明天下班一起吃饭` 均完整返回，发票号 `12345` 也**扛过了语言纠正**
- [ ] ⚠️ 以上为**合成图**上的结果；真实照片（倾斜、反光、低光）的召回率需真机验证

### Phase 6 完成 — QueryAnalyzer

- [x] `PhotoVault/Search/QueryAnalyzer.swift`：自然语言 → `QueryPlan`；`verify_siglip2.py query` **64/64 通过**
- [x] **核心设计原则：只抽取向量模型无法表达的东西**（日期/地点/否定/精确文本/媒体类型/数量/AND-OR）。其余**尽量原样交给模型**——剥虚词、改写措辞看着像"多做了一步"，实际是在**损害模型输入**：SigLIP2 原生分词中文、且就是在这种文本上训练的，删掉它认识的词是净损失。额外的机器应该放在**引擎**里，而不是花在改写 prompt 上
- [x] AND 与 OR 是**不同的数学**：`和` 取各子句分数的**最小值**（满足最弱子句），`或` 取**最大值**（最佳子句决定）。余弦能表达两者，前提是分析器先把它们区分开——所以 `combine` 是 plan 的一部分
- [x] **否定无法用余弦表达**：`不要发票`要**排除**照片，而相似度分数表达不了"不存在"。负向子句单独承载，引擎用分数上限拒掉命中它的候选
- 🐛 实测抓到的两个陷阱：
  - **否定出现在子句中间**：`海边的狗不要其他人` 是一整个子句，标记在中间。只查前缀的实现把整串当成正向视觉查询 → **否定完全失效，而结果看起来完全合理**。现改为在任意位置切分否定
  - **光秃秃的"不"不是安全标记**：它是 `不错`/`不同`/`不清晰` 的前缀，会把 `一张不错的照片` 切成正向 `一张` + 负向 `错的照片`。只匹配无歧义的多字形式——漏掉一个罕见真否定，远好于毁掉一个常见正向查询
- [x] **地点只识别语法，不负责解析**：词表有限（Phase 8），只认词表内地点的分析器会**静默忽略**其余地点。英文介词歧义极大——`in Beijing` 是地点、`in a meeting room` 是普通描述；要求其后像专有名词才采纳，否则 `a whiteboard with diagrams in a meeting room` 会被当成关于地点 "a meeting room" 的查询（修之前正是如此）。方位标记还可能在**中间**：`在北京拍的猫` 里地点是北京、`猫` 是主体，只剥离尾部后缀会得到地点 "北京拍的猫" 且主体为空
- [x] `now`/`calendar` **注入**而非读环境：说"上个月"的测试不能因为运行时间不同而改变含义。`最近7天`刻意是滚动窗口而非自然周——用户能感觉到差别
- [x] 四位裸数字只有独立成词或带 `年` 后缀才算年份，`2001太空漫游` 保持原义

### Phase 5 完成 — Swift 文本链路端到端

- [x] `PhotoVault/Search/SigLIP2TextEncoder.swift`：Swift 侧跑通转换后的文本塔；`verify_siglip2.py textencoder` **4/4 通过**
- [x] 这是**唯一**能把 Swift 两半合起来验证的地方：分词器测试只证明 Swift 移植 == sentencepiece，转换测试只证明 Core ML == PyTorch，两者都从未把 Swift 侧真正串起来跑过
- 📊 同一组 32 条 query 对 PyTorch 参考的余弦：**fp32 1.000000（逐位一致）/ fp16 0.999998 / w8 0.998961（均值 0.999569）**；热编码 **P50 9.1 ms**
  - 门槛 0.998 是**按实测标定**而非拍脑袋定的，正好卡在 W8 最差情况之下；产品级门槛仍是方案 §6 的 **nDCG@20 损失**，嵌入余弦只是代理指标
- 🐛 **修掉一个真实缺陷**：`convert_siglip2.py` 把 HuggingFace tokenizer 包装层的 `do_lower_case=True` 直接写进了 `model_manifest.json`。该 flag 描述的是一个**流水线从未执行**的意图——实测 `CAT`/`Cat`/`cat` 是三个不同 id，参考模型 cos("CAT","cat") = **0.8616**。任何相信该字段的客户端都会把输入转小写，从而**静默地不再匹配它所转换自的模型**。现在 manifest 改为**探测产物本身**（`_empirical_case_folding`）来推导，配置值再陈旧也骗不过它
- [x] **补齐一个非外观性的约束**：模型无 attention mask 且**取最后一位**，短 query 的最后一位就是 pad。字面量少于 64 token 会改变被池化的位置、产出与参考不同的嵌入——所以截断+补齐由 `SigLIP2TextEncoder` 独占，调用方无法传入未补齐序列
- ⚠️ 首次预测约 **7.7 s**（Core ML 特化开销），因此编码器必须在启动时构建一次，不能每次检索新建
- [ ] ⚠️ 以上均为 macOS CPU/GPU 数据；**真机 ANE 的首次加载耗时与峰值内存仍需实测**

### Phase 4（Metal 精确检索）
- [ ] ⚠️ Metal 内核只在 macOS（M1）上验证过；**真机 ANE/GPU 的 compute-unit 分布与首次加载耗时仍需实测**（Mac 数据不能替代）

### Phase 3 余下（未完成）
- [ ] PhotoKit 增量索引管线（`PHPersistentChangeToken` 驱动、暂停/恢复、限流发布进度）——需真机 / iOS 编译环境
- [ ] ⚠️ 上述 FTS5 / trigram 可用性只在 macOS 系统 SQLite 上验证过；**iOS 系统 SQLite 是否编译了 FTS5+trigram 必须在真机复核**，`supportsTrigramFullTextSearch()` 已备好检测入口
- [ ] **真机 ANE 实测**（compute unit 分布、首次加载耗时、峰值内存）——Mac 数据不能替代（R3/R4）
- [ ] Swift 侧 Core ML parity 测试（L1 同输入 + L2 全流程）需 XCTest target（D3）
- [ ] `.mlpackage` 与 `tokenizer-v1.bin` 尚未拷贝进工程、尚未登记进 `project.pbxproj`（D4/D5）
  - 已确认工程用的是**显式 PBXBuildFile 引用**（`PBXFileSystemSynchronizedRootGroup` 出现 0 次），因此新增 `PhotoVault/Search/SigLIP2Tokenizer.swift` 在登记前**不会**进入构建，现有 App 构建不受影响

**Phase 1/2 未修改任何 `.swift` 或 `.pbxproj`**，与方案"不要在完成检查之前大规模修改工程"完全一致。

### Phase 3 剩余部分完成 — PhotoKit 增量索引流水线

- [x] `PhotoVault/Search/PhotoIndexPipeline.swift`（调度与状态机）、`PhotoVault/Search/PhotoKitIndexSource.swift`（PhotoKit 胶水层）；`verify_siglip2.py pipeline` **36/36 通过**。在此之前 store 里的 50 项检查只证明"能存"，**没有任何东西能把 10 万张照片真的灌进去**，也没有任何东西证明中断后能接着灌
- [x] **把可测的部分和不可测的部分切开**：调度、重试、退避、热策略、代次守卫全部放在**不依赖 PhotoKit** 的 `PhotoIndexPipeline` 里；`PhotoKitIndexSource` 只剩框架胶水。"PhotoKit 会不会返回 asset"是苹果的代码，**这个 App 真正会写错的是"什么时候停、什么该重试、什么该延后"**——而后者恰恰因为不碰框架才可测
- [x] **`step(generation:conditions:)` 同步、`run()` 异步**：一个批次的所有逻辑都在同步函数里，暂停边界、退避、代次失效因此不依赖时序即可复现（不用 sleep、不用期望）
- [x] 🔴 **代次必须由调用方传入，不能自己读**：`step` 内部若比较"当前代次 == 当前代次"，**这个检查永远为真**，同步函数不可能观察到发生在它执行期间的变化——即"被顶替的运行不得写入"这条保证**既无法测试也从未生效**。改为 `step(generation:)` 后，陈旧批次返回 `.superseded` 且**一个字节都不写**
- [x] 🔴 **OCR 只能延后，不能降级**：Vision 的 `.fast` 只支持 6 种语言且**不含 `zh-Hans`**（Phase 7 实测）。所以"设备热时把 OCR 降一档"不是低质量 OCR，而是**对中文照片完全没有 OCR**——它会一边停止索引每一张中文发票，一边看起来仍在正常工作。唯一诚实的降级是**把工作留到以后**。而 embedding 不同：它优雅降级且是功能的核心，所以在热压力和低电量下**继续**，只有 `.critical` 才整体停止
- [x] **iCloud 未下载 ≠ 失败**（`deferAsset`）：照片只是还没到这台设备上，不是坏了。计入失败会让一张完好照片在几次尝试后被"停放"数小时。它保持 `pending` 并带 `next_retry_at`，因此在 store 层与"试过且失败"截然不同。失败计数留给真正解码/模型失败
- [x] 🔴 **一条真实的 store Bug（本轮测试发现）**：`pendingAssetIDs` 原本**只对 `failed` 行读取 `next_retry_at`**，`pending` 行无条件返回。于是 `deferAsset` 是空操作——**同一张照片立刻被再次选中，在全新设备上（大量 iCloud 未下载）会无限热循环烧 CPU 和电**。测试里的症状是 `unavailable=98`（循环 100 次后放弃）。修法：`status IN (pending, failed) AND (next_retry_at IS NULL OR next_retry_at <= ?)`
- [x] **进度节流 0.25 s（约 4 次/秒）**：不是美观问题。10 万索引上每张照片都发布一次状态会重建整棵 SwiftUI 树，这是"可用"和"冻死"的区别。阶段切换与完成**必发**，不参与节流
- [x] **`removeAssets(assetIDs:)` 与 `removeEmbeddings` 分开**：后者只释放向量槽，前者清掉元数据行与 FTS 行。照片被删除后若只在矩阵里释放槽位，**搜索会返回一个 PhotoKit 再也解析不了的 asset ID，UI 上就是一个空洞**。删除按 500 一批、单事务，并先删元数据再删 FTS
- [x] **`metadata(for:)` 从本库读，不走 PhotoKit**：一个批次的元数据在入库时已经写好，取出来用不着框架调用，也让流水线在完全不含 PhotoKit 的情况下可运行、可测试
- [x] **变更令牌用 `NSKeyedArchiver` 归档**：`PHPersistentChangeToken` 是 `NSSecureCoding`，不是 `Data`。存原始字节能跑，直到该类改变编码方式——那时它表现为**一个读不出的令牌**而不是一个错误。读不出时同样回落全量扫描
- [x] **删除先于插入**：同一标识符被删后重建时，若先加后删会**留下一个索引空洞，且之后任何一次同步都不会补上**
- [x] 沿用全局约定：token 有效性**只由 PhotoKit 判定**（抛错→全量重建），**不得用库签名**（count / 首尾 ID）否决——截图按时间倒序插到第 0 位必然改签名，签名否决会让每张新截图都触发 10 万条全量重建
- [x] 图片加载走 PhotoKit 按 256×256 交付而非原图：模型只吃 256×256，因此**没有理由物化 12 MP 原图**，在 iCloud 库上还省下整张原图的下载。`version = .current`（**不能用自动调整后的版本**，那会嵌入一张与用户所见不同、且跨设备不一致的图）
- [x] **测试隔离本身是一个 Bug 来源**：首版所有用例共用同一个数据库文件，于是"暂停后没有写入"读到的是上一个用例写满的库，12 项失败**与真实流水线 Bug 无法区分**。改为每个用例独立目录后才看到真实信号

**Phase 3 至此完成**：索引库、矩阵文件、mmap 读取、Metal/Accelerate 检索、增量同步、断点续跑、退避与热策略均已实现并验证。剩余待办是真机验证（ANE、首次加载、峰值内存）与 Phase 9 起的 UI 与登记工作。

### 相似图检索 + 第三方声明（§82 两项收口）

- [x] **相似图检索** `PhotoSearchEngine.search(similarTo:limit:)`；`verify_siglip2.py search` 由 **46 → 58 项通过**。这是**唯一完全不经过文本塔**的检索：查询向量就是参考图自己已存进矩阵的那一行，于是"更多这样的照片"恰好等于索引本来就要回答的操作——**对着一个已经在矩阵里的向量做一次点积**
- [x] 🔴 **参考向量必须从矩阵读回，不能重新编码图片**——这不是图省事：存放的那一行**就是**所有其它检索用来比较的东西，用它才能保证参考与结果**按构造处在同一空间**。重新编码会引入第二个略有不同的向量（仅 float16 存储一项就让单位向量移动约 1.65e-5），于是**同一个"更多这样的照片"在片刻之后重跑会给出不同结果**
- [x] **参考图必须排除自身**：否则它永远以相似度 1.0 排在首位，**功能看起来坏掉的样子恰好就是它正常工作的样子**
- [x] **不加元数据过滤**："更多这样的照片"是对**外观**的陈述，用日期或地点去收窄它等于**悄悄回答了另一个问题**
- [x] 沿用与文本检索相同的分数下限：低于它"相似"这一断言就没有向量支持（不相关照片的相似度仍有约 0.05）。**没有近邻时返回空，而不是拿低分照片凑数**
- [x] 未索引的照片是**索引尚未填满时的正常状态，不是错误**：返回空结果并说明原因，而不是抛错或返回整个图库
- [x] 判定性验证：以 `cat-on-beach` 为参考，实测顺序 **`beach-only, cat-indoors, cat-and-dog, dog-on-beach`**，与精确余弦值推演一致（0.7071 并列 → 按 asset id 打破；0.5 并列同理；`invoice` 余弦 0 落在下限之下而**必须缺席**）；并独立验证分数**等于矩阵自行读回后的余弦**，以捕获参考向量"漂移到自己的空间"这类错误
- [x] `THIRD_PARTY_NOTICES.md` 新建：**按分发物而非按构建依赖来写**。随 App 分发的只有 SigLIP2（Apache-2.0，模型卡 `license: apache-2.0` 实读）及其派生的 `tokenizer-v1.bin`，因此**内嵌完整 Apache-2.0 全文**（Apache-2.0 §4 要求随分发附许可副本），并逐条列出本项目所做的改动（Core ML 转换、MAP 池化头重写、归一化入图、静态 `[1,64]` 文本输入、SentencePiece→自有二进制 BPE）——**格式与打包改动，未做任何训练/微调/蒸馏，衍生件许可仍为 Apache-2.0**；已核实上游**无 NOTICE 文件**，故 §4(d) 不追加归属要求
- [x] 已核实 **App 运行时只链接 Apple 框架**，`XCRemoteSwiftPackageReference` 出现 **0 次**（无 SPM/CocoaPods/Carthage 依赖），因此**没有其它随包分发的第三方代码**；构建期工具（coremltools 9.0 / PyTorch 2.5.0 / transformers 4.53.3 / Pillow / NumPy / sentencepiece）单独列表，明确标注**不随包分发**
- [x] **地名库的局限写进了声明文件**：252 个坐标是**手工整理、约 10 km 精度、非权威数据**，适用于"北京附近的照片"，**不适用于导航或测量**。这不是免责套话——工程内已记录只有 Interlaken 做过公开来源抽查（46.6833/7.85 vs 随包 46.6863/7.8632，约 1 km）

### Phase 2/3 收口 — 15 个 Search 源文件已登记进工程并可编译（D4）

- [x] `tools/models/register_search_sources.py`（幂等，`--check` 支持空跑）。工程用的是**显式 `PBXBuildFile` 引用**，`PBXFileSystemSynchronizedRootGroup` 出现 0 次——文件放进 `PhotoVault/` **不会被编译**，必须同时进 Sources 阶段、有可解析的 file reference、并挂在某个 group 下
- [x] **实测证据（不是"构建成功"）**：目标文件由 **20 → 34**；`default.metallib` 进入 App 包且含 `embedding_dot_fp16` 内核；抽查 4 个目标文件各有 743–837 个符号。App 构建 `** BUILD SUCCEEDED **`
- [x] 🔴 **一个"绿色构建骗局"（本轮最重要的教训）**：脚本首版把 file-reference id **分配了两次**（一次在建 `PBXBuildFile` 行时、一次在引用循环里），于是 build file 指向 `B1…40-54` 而真实引用是 `B1…55-69`。**Xcode 完全没有报错**：构建显示 `BUILD SUCCEEDED`、**一个文件都没编译**、目标文件数停在 20
  - 根因：**`fileRef` 解析不了的 build file 是被静默丢弃，而不是被诊断为错误**。因此"构建通过"**不能**作为"文件已进 target"的证据
  - 现在的判据是**目标文件**而非退出码；脚本在写盘前自检每个 build file 可解析、且每个引用 id 至少出现 3 次（定义、group 条目、build file 引用）
- [x] 🔴 **两个编码器真正的并发缺陷**（Swift 6 语言模式暴露）：`SigLIP2VisionEncoder` 与 `SigLIP2TextEncoder` 各自**复用一个输入缓冲**（`inputArray`/`inputPointer`）。并发调用会交错"拷贝"与"预测"，**一张照片会用另一张照片的像素生成 embedding**——而且**完全静默**（两个张量都合法，只是配错了图）
  - 两者均在**填充+预测整段**加 `NSLock`，并据此声明 `@unchecked Sendable`。只锁填充是不够的：那会让缓冲在 Core ML 仍在读取时被覆盖，是同一个 Bug 的窄窗口版本
  - ⚠️ **文本编码器此前从未声明 `Sendable`，所以编译器对它这个一模一样的隐患保持沉默**——它编译得过，但隐患与视觉编码器完全相同。加锁也是硬件的真实模型：**只有一个 ANE**
- [x] **类型名与既有索引冲突**：工程里早有 `PhotoIndexProgress`（未整理照片索引，阶段为 `scanningAssets`/`scanningAlbums`），与流水线的同名类型冲撞。流水线侧统一改名带 `Search` 中缀：`PhotoSearchIndexProgress` / `State` / `Step` / `Conditions` / `Policy` / `Coordinator`
  - ⚠️ **单文件 typecheck 永远发现不了这个**——新文件从未与既有文件一起编译过。这正是"必须真正进 target 一次"的价值
- [x] **相似图检索的代码此前也被死代码消除**：未登记的代码既没被编译也没被链接（二进制里搜不到其特征字符串）。登记后仍未链接是**正常的**——Phase 9 之前没有 UI 引用它，链接器会剥离；待 UI 接入即会链入

**至此 SigLIP2 全链路（分词器→文本塔→图像塔→矩阵→检索→分析器→流水线）都是 App target 的一部分并通过编译**，Phase 9 的 UI 可以直接建立在其之上。

### 模型进包与"进包后仍然正确"（D5）

- [x] **决策 D5：模型不进 git。** W8 = **364 MB**（视觉 89 + 文本 270 + 分词器 5），FP16 = 715 MB，二者都可由 `requirements-lock.txt` + `convert_siglip2.py` 完整复现。因此 `PhotoVault/Models/` 进 `.gitignore`，由 `tools/models/install_models.py` 填充
  - ⚠️ **代价写明而非隐藏**：**干净 clone 必须跑一次安装步骤才能得到可用的 App**。构建本身**不会失败**（没有任何 Swift 源码在编译期引用这些文件），只是搜索没有模型可加载——此时 `SearchModelResources` **明确指出缺哪个文件、该跑哪条命令**，而不是对 nil URL 强解包或静默返回空结果
  - 选 W8 而非 FP16：W8 已通过质量门（文本最小余弦 0.998961、图像 0.999072、全部 0.997971），§6 要求量化后 nDCG@20 损失 ≤1.5% 的条件已满足（见 Phase 2 记录）
- [x] `tools/models/register_search_sources.py` 扩展为同时登记 **Sources**（Search/*.swift + .metal）与 **Resources**（Models/*）。`.mlpackage` 的 file type 是 `folder.mlpackage`，Xcode 据此调用 `coremlc` **编译**而非原样拷贝
- [x] **实测证据**：App 包内 `SigLIP2Vision.mlmodelc`（89 MB）、`SigLIP2Text.mlmodelc`（270 MB）、`tokenizer-v1.bin`、`SearchModelManifest.json`；App 总大小 **384 MB**
- [x] **区分"编译"与"改名拷贝"**：`.mlmodelc` 内部是 `coremldata.bin` / `model.mil` / `weights`，与 `.mlpackage` 的 `Data` / `Manifest.json` 布局不同——**这证明 `coremlc` 真的编译过**，而不是把 mlpackage 改个扩展名。目标文件数 **35**（20 原有 + 15 Search）
- [x] 🔴 **`verify_siglip2.py bundle`（16/16 通过）——补上"转换正确 ≠ App 能加载"这一缺口**。此前所有门禁都在验证**流水线**（Python 参考、转换出的 mlpackage、Swift 移植），它们**全绿的同时 App 里根本没有模型**。这个门禁直接从**已构建的 `PhotoVault.app`** 里加载 `.mlmodelc` 并运行
  - 📊 **判定性数字：`cos("CAT","cat") = 0.8610`（参考 0.8616）**。这一个数字证明进包的分词器与文本塔是**被验证过的那一对**——词表不匹配、归一化里做了大小写折叠、或模型陈旧，都会让它偏离（本分词器**故意不折叠大小写**，`CAT` 与 `cat` 是 29492 与 4991 两个 token）
  - 同批实测：视觉范数 1.0007458、文本范数 0.9997030，证明转换时烘进图里的归一化**在打包后依然成立**；文本↔图像可比（cos("cat", 纯灰) = 0.0817，非正交、非 NaN）
- [x] 🔴 **一个破坏工程文件的可读性 Bug（本轮发现）**：脚本用**同一次**正则匹配的 offset，在**若干次文本修改之后**再插入 group 子项——offset 已过期，指向了另一行中间，把引用**拼接进了不相关的行内**（`sourceTre` + 引用 + `e = "<group>"`），产物是 **Xcode 完全读不了的工程文件**（`Unable to read project`）
  - 修法：`add_child_to_group()` **每次都在当前文本上重新匹配**，不复用旧 offset
- [x] 另一处收口：脚本在"无新源文件"时**仍会创建一个空的 Search group**（每次重跑累积一个）。已改为**仅在确有源文件时**才建组、才挂子项
- [x] `SearchModelResources.swift`：定位包内产物并构造三个组件；**pad token 从分词器产物读取而非写死**——填充是文本塔做池化的位置，pad token 与产物不一致就等于让模型去注意一个分词器从不产出的 token

**至此 Phase 9 之前的全部前置条件已就绪**：代码进 target 并能编译、模型真进包且**进包后仍被验证为正确**、App 可直接通过 `SearchModelResources.makePipeline()` 拿到（分词器 + 视觉塔 + 文本塔）三元组。

## Phase 9：搜索 UI

- [x] 侧栏新增「智能搜索」入口（`PhotoSection.smartSearch`），进入 `SmartSearchScreen`。**不复用「搜索结果页」（`PhotoSearchResultsScreen`）**——那个页面过滤的是**相册标题**，而这里是按**照片内容**检索，两者语义不同，混在一起会让"搜到的到底是相册还是照片"变得含糊
- [x] `SmartSearchModel`（`@MainActor @Observable`）持有索引、编码器与流水线，把一次查询变成有序结果
- [x] **模型懒加载且不占主线程**：首次加载实测 6.4 s（视觉塔，macOS），放在 `init` 里会卡住页面首帧。改为进页面后 `Task.detached` 加载，期间显示"正在载入模型"
- [x] **索引只在本页面启动**：10 万张是数小时的工作量，开机自动开跑等于让从不使用搜索的用户也付这份代价。"打开这个页面"就是"我要用这个功能"的信号
- [x] 🔴 **结果必须是 `[PHAsset]` 而非 `PHFetchResult`**：PhotoKit 按 identifier 取回时**不保证顺序**，而"排序"正是搜索的全部产出。结果集有 `maximumResults` 上限，物化是安全的
  - 🔴 **打开详情页必须把索引解析到 fetch result 内部**：`PhotoViewerView` 显示的是 `assets.object(at: initialIndex)`，`initialAssetIdentifier` **只用来给首帧塞预览图**。若直接传排名当 `initialIndex`，会打开 PhotoKit 恰好排在那一位的**另一张照片**、却配上正确缩略图——"图对了内容错了"这种最难察觉的错误。现改为在 fetch result 中按 identifier 反查真实下标
  - ⚠️ **遗留（已记录）**：详情页内**左右滑动的顺序**仍是 PhotoKit 顺序而非相关性排名。根治需要给结果集写一个有序分页器；当前只保证"点开的那张是对的"
- [x] 🔴 **并发缺陷（本轮发现并修复）**：`PhotoSearchIndexCoordinator` 被后台任务驱动批处理，而 `pause()` 从主线程调用、UI 读 `state`/`progress`——**这是两个线程动同一批字段**。Swift 6 直接报 `sending 'coordinator' risks causing data races`，而且它是**真实存在的竞态**：批次中途的暂停可能丢失，或读到半更新的进度快照
  - 修法：四个可变字段全部收进 `NSLock`；`onStateChange` **在释放锁之后**回调（避免重入死锁）；`step()` 在**局部副本**上累积进度、结束时一次提交——锁**绝不跨越解码与推理**，否则 `pause()` 会把主线程阻塞好几秒，正好制造这个设计要避免的卡顿
  - ✅ **用 Thread Sanitizer 验证**：`swiftc -sanitize=thread` 编译整份流水线测试并运行，**42/42 通过且零 data race 报告**。新增 6 项并发检查（并发读进度不回退、批次中途暂停生效、状态确为 paused、完成计数保留、resume 后可继续）
- [x] 🟡 **修正一处此前的错误结论**：Round 13 曾以"App 二进制里搜不到特征字符串"判定搜索栈被链接器剥离。**该结论基于错误的检查对象**——Xcode 16+ 启用 `ENABLE_DEBUG_DYLIB` 后，`PhotoVault.app/PhotoVault` 只是 **91 KB 的启动桩（105 个符号）**，真正的代码在 **`PhotoVault.debug.dylib`（12 MB、28124 个符号）**
  - 实测（debug dylib）：`SmartSearchScreen` 231、`AIPhotoSearch` 370、`QueryAnalyzer` 194、`SigLIP2VisionEncoder` 60、`ContentView` 454 个符号；`AIPhotoSearch.sqlite`、`sparkle.magnifyingglass`、`SearchModelManifest.json` 等字符串均在
  - 📌 **教训**：判断"某模块是否进了最终产物"必须认准**真正的产物**；Debug 配置下主二进制可能只是个壳
- [x] 搜索框用 `.searchable`；结果用 `LazyVGrid` + `AssetImageView`（`visibleGrid` 优先级、`gridThumbnail` 缓存域）；长按菜单提供「查找相似照片」（走 Phase 3 的 `search(similarTo:)`）
- [x] **诊断信息显示而非隐藏**：页脚给出候选数/打分耗时，并把 `warnings` 逐条列出。一次静默丢弃了无法解析地点、或退化成纯元数据过滤的搜索，看起来就只是"搜得不好"——说出来才是"用户能绕过的限制"和"看起来像模型有病"的区别
- [x] 构建产物：**37 个目标文件**（20 原有 + 17 Search）

### 工程登记脚本的两处收口（本轮）

- [x] 🔴 **重复 group**：脚本在**每次**发现新文件时都**新建**一个 `Search` group，而不是复用已有的。于是每加一批文件就多出一个同名文件夹——本轮结束时工程里已积了**三个 `Search` group**。构建完全正常（37 个文件都进了 Sources），**所以没有任何自动检查会报错**，但任何人打开 Xcode 都会看到一个明显错误的工程
  - 修法：先查是否已有同名 group，有则把新子项**追加**进它的 children，无则新建并挂到 PhotoVault 组下
  - ✅ 从登记前的备份重新生成后，工程内**恰好各一个** `Search` / `Models` group；`--check` 连续两次均报 "already up to date"
- [x] 辅助函数的定义位置：`existing_group()` 原本嵌在 `apply` 段落里，却在更早的地方被调用（`UnboundLocalError`）。已提到模块级
- 📌 **教训**："构建通过"不等于"工程正确"。登记类脚本的产物要**按语义**核对（group 数量、引用是否可解析），不能只看 `BUILD SUCCEEDED`

## Phase 10–11：重启续跑、Release 隐私验收

### 重启后能续跑（§82 明列项）

- [x] 🟢 **实测通过**：新增"进程重启"测试，直接针对 §82 的「索引在重启后能续跑」。**这与"同一个 coordinator 内 pause/resume"是两个不同的命题**——重启后是新的 coordinator、新的 store 句柄、零内存状态，必须精确接上而不是重来
  - 做法：建 50 条资产 → 跑两批（模拟进程被杀）→ **用同一组路径重新 open**（`makeStore()` 不能用，它每次建新目录）→ 新 coordinator 跑到完成
  - 📊 **判定数字：第二轮只嵌入了余下的那部分，不是整个库**。若重启后退回全量重做，这个计数会等于总资产数
  - 同批校验：重启后已写入的 embedding 仍在、未完成的仍在 pending、最终 `embeddedAssets == totalAssets`、`pendingAssets == 0`、没有任何资产重新变为可选中
- [x] 🟡 **测试自身的一个错误值得记下**：首版把总资产数**写死成 50**，但 `makeStore()` 内部会预置自己的 20 条资产，实际是 70 条，于是测试报出 3 个"失败"——**那是测试的算术错了，不是产品错了**。已改为运行时读取基线（`baseline.pendingAssets` / `baseline.totalAssets`），不再假设
  - 📌 这条正是"断言必须由被测对象推导"的例子：写死的期望值会把测试自己的错误伪装成产品缺陷

### Release 构建与隐私验收

- [x] 🟢 **首次 Release 构建通过**（此前只验过 Debug）。Release bundle **380 MB**，`SigLIP2Vision.mlmodelc`(89M) / `SigLIP2Text.mlmodelc`(270M) / `tokenizer-v1.bin`(5M) / `SearchModelManifest.json` 全部就位
- [x] 🟢 **Release 主二进制 7.1 MB、17686 个符号**（Release 未启用 debug dylib，符号就在主二进制里）；`PhotoVaultLaunch.log` / `PagerDiagnostics.log` / `lan-folder.log` **出现次数均为 0**——DEBUG 专用诊断被正确编译掉
- [x] 🔴 **新增 `privacy` 门禁（11/11）——把"不上传"从承诺变成可执行检查**。"照片/embedding/OCR 文本/查询不出设备"这种约束，**一次调试时顺手加的 `URLSession` 就能破掉**，所以门禁查的是**源码**：
  - 搜索栈 17 个文件内**无任何网络 API**（URLSession / URLRequest / NWConnection / dataTask / uploadTask / WebSocket / CFStream …）
  - **无任何远程端点**字面量（`http://` / `https://`）
  - **只 import 系统框架**（Foundation / Photos / SwiftUI / CoreML / Vision / Metal / Accelerate / SQLite3 …），**零第三方依赖**
  - 搜索栈**不向任何日志写入**——照片、OCR 文本与查询恰恰是最不该进日志的东西
  - embedding 矩阵 `isExcludedFromBackup = true`（100k×768 fp16 ≈ 150 MB 派生数据不该被推进 iCloud，那与"端侧"相悖）
  - `THIRD_PARTY_NOTICES.md` 存在、含完整 Apache-2.0 正文、写明实际发布的模型名与许可证、并**声明文件已被修改**（许可证要求）
- [x] 🔴 **门禁做过变异测试（mutation test）**：往 `QueryAnalyzer.swift` 注入 `URLSession` + `https://example.com` + `print(`，门禁立刻报 **3 项失败**并精确指出文件与行号；还原后重新通过
  - 🟡 期间修掉一个**假阳性**：`modelFingerprint(` 里含子串 `print(`，被判成日志调用。已改为要求**词边界**（`(?<![A-Za-z0-9_])print\s*\(`）
  - 📌 **会误报的检查会被忽略**，比没有检查更糟——它训练人忽略红灯
- [x] ✅ **Limited Photo Access**：`.limited` 被当作**一等公民的授权状态**（而非错误），`PhotoMetadataSyncResult.isLimited` 一路传到 UI 提示"索引范围限于已选择项目"；`.denied` 才抛 `accessDenied`

### §82 逐项对照（当前状态）

| §82 要求 | 证据 |
|---|---|
| SigLIP2 Core ML 可用 | `bundle` 门禁 16/16（从已构建 App 内加载 .mlmodelc）＋ 🟢 **真机**：ANE 可用，716 个视觉算子中 **306 个落在 `neuralEngine`** |
| 一致性测试通过 | 门禁（w8 文本最小余弦 0.998961）＋ 🟢 **真机**：`cos(CAT, cat) = 0.8612`（参考 0.8616） |
| 增量索引 | `pipeline` 门禁 ＋ 模拟器端到端 ＋ 🟢 **真机**：104,462 张真实资产 `fullscan: false`、`inserted 0`、**failure 0** |
| **重启后续跑** | `pipeline` 门禁 ＋ 模拟器 ＋ 🟢 **真机**：在 **63/104,462** 处杀掉 App，重启后继续到 **166**（未归零） |
| 10 万条检索性能 | 100k×768 **M1 原生**：Accelerate P50 **9.16 ms**、Metal 8.97 ms（预算 500 ms，余量 ~55×）＋ `metal_scale` 基准。⚠️ **真机检索耗时仍缺**（模拟器 7.57 s 无参考价值；基准已验证可跑） |
| 中文自然语言搜索 | `query` 门禁（64 项）＋ `search` 门禁（58 项）＋ 🟢 端到端：`蓝色` 在 17 张真实照片上返回 5 条 |
| AND / NOT / 多查询 | `query` 门禁 |
| OCR | `ocr` 门禁（29 项）＋ 🟢 **真机**：192 张真实照片产出文本；中文只能用 `.accurate` |
| 日期 / GPS | `query` + `geo` 门禁（252 地点）＋ 🟢 **真机**：**33,304 张**带 GPS（31.9%） |
| 相似图搜索 | `search` 门禁 ＋ 🟢 端到端：红→另一张红 0.9725、青→蓝 0.9732、票→护照 0.7166，且**种子不返回自己** |
| Limited Photo Access | 🟢 实测三态：`auth_value=3` → `.limited` 一等公民；`=0` → 有类型 `accessDenied` 且不崩 |
| iCloud 不可用不崩 | `unavailable` 走 defer（6 小时退避），非 failed |
| 低电量 / 严重发热降级 | `pipeline` 门禁：策略降批/延迟。✅ **已确认接线**：`run()` **每批**调用 `conditions()`（默认 `.current()` 读真实 `ProcessInfo`），`SmartSearchModel` 走默认值 |
| 可运行 benchmark | `embeddingstore_bench`（10 万条扫描）、`metal_scale`（Metal vs Accelerate）、`benchmark_siglip2.py` |
| **不上传** | 🟢 **本轮新增 `privacy` 门禁 11/11 + 变异测试** |
| **Release 无敏感日志** | 🟢 **本轮首次 Release 构建**：3 个 DEBUG 日志路径出现 0 次 |
| THIRD_PARTY_NOTICES 完整 | `privacy` 门禁校验正文/模型名/修改声明 |

**仍待完成**（本轮更新）：

- ~~真机实测（FTS5+trigram、首载时间、峰值内存）~~ → ✅ 已在真机完成（见下文"真机实测"）
- ~~增量索引 / 重启续跑的端到端~~ → ✅ 已在模拟器用真实 PhotoKit 完成（见下文"端到端验证"）
- ~~Limited Photo Access~~ → ✅ **已闭环**（TCC `auth_value=3` 实测 `.limited` 一等公民；`=0` 抛有类型的 `accessDenied` 且不崩）
- ~~Phase 9 详情页**左右滑动顺序**~~ → ✅ **已修复并验证**（`ViewerAssets` 让查看器支持有序序列；`input order kept: NO` 是修复前的前置事实）
- ~~端到端索引 / 日期 / GPS / 相似图 / AND·NOT·OR / OCR~~ → ✅ **均已在标注集上端到端实测**（见下文各节）
- ~~ANE 实际占用与真机性能数字~~ → ✅ **已实测**（ANE 306/716 算子；视觉编码 P50 160 ms、文本 2.9 ms；端到端 104,462 张 0 失败）。⚠️ **唯一仍缺「真机上 10 万条检索耗时」**（合成基准被 jetsam 杀掉，已改为 opt-in；现有为 M1 替代证据）
- ✅ **Phase 4 Metal 内核的 iOS 缺陷已定位并修复**（根因：`base + 4096` 不满足 `makeBuffer(bytesNoCopy:)` 的页对齐要求，硬件页 16384 ≠ header 页 4096；macOS 容忍、iOS 不容忍）。修复后排序与 Accelerate **完全一致**（`max score delta 1.39e-04`），macOS 31 项门禁仍全绿。**仍不接进搜索路径已是实测定论**：本轮在同一 10 万×768 矩阵上对比，Metal 仅 **1.02×**（内存带宽受限，GPU 无优势），且 top-100 排序一致（分数差 6.56e-07）。Accelerate 出货已 ~55× 余量，接 Metal 只换取 2%。详见下文专节
- ⏳ Phase 12 权重调优 → 已具备标注集（P@1 = 10/10），**当前配置没有可调空间**；改动即过拟合，见下文

## 真机实测（iPhone 15 Pro / iPhone16,1，iOS 27.0 build 24A435）

用 `--pv-ai-selfcheck` 启动参数触发自检（无需任何 UI 交互），把报告写到 App 容器再 `devicectl device copy from` 取回。这一节替掉了此前唯一的空白——**所有此前的数据都来自 Apple M1，不是设备**。

### 🔴 关键结论一：iOS **自带 FTS5 + trigram**（此前悬而未决）

```
sqlite version:     3.54.0
FTS5 compiled in:   true
trigram tokenizer:  true
unicode61:          true
search path:        FTS5 MATCH (trigram)
```

- 不只是 DDL 被接受：**建表 → 插入中文 → `MATCH '海边'` 真的返回了 1 行**，是完整往返，不是"语句没报错"
- ✅ 因此混合 OCR 检索**可以走 FTS5 MATCH**，`instr()` 只是保险而非必需路径。这条决定了 1–2 字中文查询是否可用——**现在确定可用**
- 📌 这件事**只能**在真机上问出来：iOS 的 SQLite 由 Apple 自行编译，版本号推不出编译选项

### 🔴 关键结论二：模型加载是**一次性**成本，不是每次

| | 冷（首次） | 热（之后） |
|---|---|---|
| 视觉塔加载 | **5502 ms** | **79 / 113 / 178 ms** |
| 文本塔加载 | **21292 ms** | **298 ms** |

- 首次总代价约 **27 秒**，之后约 **0.4 秒**——**快 70 倍**。差距来自 ANE 程序生成与权重预处理的磁盘缓存
- ✅ 这直接改变了 UX 判断：屏幕上"正在载入模型"的等待**只在装机后第一次出现**，之后可以忽略。此前以 M1 的 6.4 s 冷启动推 21 s 文本塔会显得不可接受，实测证明这是**一次性**的
- ⚠️ 但仍应避免在 App 启动时就加载（`SmartSearchModel.prepare()` 只在进搜索页时调用，这个决定是对的）

### 🔴 关键结论三：视觉编码波动 3.3 倍，**原因未查明**（且证明"热节流"的解释是错的）

同一份自检多次运行：

| 次序 | 视觉塔加载 | **视觉编码 P50** | thermalState | 峰值内存 |
|---|---|---|---|---|
| 1（冷装） | 5502 ms | **161.3 ms** | — | 143 MB |
| 2 | 79 ms | **529.2 ms** | — | 67 MB |
| 3 | 113 ms | **417.5 ms** | — | 138 MB |
| 4 | 178 ms | **185.4 ms** | — | 66 MB |
| 5（冷装后） | 4485 ms | **157.1 ms** | **serious** | 522 MB |

- 📊 **由此推出的索引吞吐（100k 库）**：按最快 0.157 s 约 **4.4 小时**，按最慢 0.529 s 约 **14.7 小时**
- 🔴 **第 5 次运行推翻了此前的解释**。我最初把 161→529 ms 归因为"热节流"（当时的依据是"连续跑变慢、冷却后恢复"）。补上 `thermalState` 后，第 5 次在 **`thermalState = serious`（更热）** 的情况下反而跑出 **157 ms（最快档）**
  - ❌ **所以"热节流"这个解释站不住**。已撤回该结论
  - ✅ 能确定的只有两件事：**波动真实存在且可复现（3.3 倍）**；以及 **`ProcessInfo.thermalState` 无法预测编码吞吐**
  - ❓ **未分离的变量**：Core ML 可能据系统负载/热状态在 ANE 与 GPU 之间**切换放置**（ANE ≈157–185 ms，GPU 可能 ≈417–529 ms）——这是最像的假设，但**本次没有测到实际使用的 compute unit**，故仅列为假设，不作为结论
  - 📌 **对 Phase 10 的含义（因结论改变而改变）**：原先写的"改用实测吞吐自适应、别只信 thermalState"**依然成立，而且理由更强了**——因为 `thermalState` 已被证明与吞吐**不相关**，索引策略若只看它就等于没看
  - 🔧 **下一步该测什么**：用 `MLComputePlan`（iOS 17+）记录模型**实际**落在哪个 compute unit，与耗时并列。这能把假设变成事实
- ✅ **另一条明确结论**：**重新安装 App 会清掉 ANE 缓存**——第 5 次重新装了 App，冷加载时间立刻从 ~100 ms 退回 **4485 / 23582 ms**。所以"27 秒"是**每次安装一次**，不是每次启动一次
- ⚠️ **峰值内存**：冷装首次加载 **522 MB**（含 ANE 程序生成），热态 **66–143 MB**。仍在预算内，但冷装那次明显更高，若要卡内存预算应以 522 MB 为准

### 其余真机结果

- ✅ **ANE 可用**：`compute devices: neuralEngine, gpu, cpu`
- ✅ **文本↔视觉配对正确**：真机 `cos("CAT","cat") = 0.8612`（参考 0.8616）——与 bundle 门禁在 Mac 上的 0.8610 一致
- ✅ **文本编码在设备上比 M1 更快**：中文 **3.2 ms**、ASCII **3.9 ms**（M1 为 9.1 ms）；视觉编码则相反（设备 161–529 ms vs M1 52.7 ms）
- ✅ **OCR 语言**：设备上可用 **3 种，含 `zh-Hans` 与 `zh-Hant`**——**中文 OCR 可用**
- ✅ **AI 索引库在设备上能正常建表打开**（`AISearchSearchStore.open` → ok）
- ⚠️ ~~本次自检 `total assets: 0`，因为**未授予照片权限**~~ → 📌 **该缺口已由模拟器侧闭环**：`AIPhotoAccessGrantUITests` 打通权限后，整条链路已在真实 PhotoKit 上跑通（17/17 嵌入、增量、重启续跑、受限/拒绝三态）。真机侧仍需在解锁后复核一遍，但**它不再是"未验收"的黑洞**，只是"同一套代码尚未在设备上重跑"

### 因此，§82 表中这几项从"未验证"变为"已在真机确认"

| 项目 | 真机结论 |
|---|---|
| iOS 是否带 FTS5 + trigram | 🟢 **带**，中文 `MATCH` 往返成功 |
| ANE 是否被使用 | 🟢 可用（`neuralEngine` 在列） |
| 首载时间 | 🟢 冷 27 s（一次性）／热 0.4 s |
| 峰值内存 | 🟢 热态 66–143 MB／冷装首次 522 MB |
| 中文 OCR | 🟢 `zh-Hans` 可用 |
| 模型一致性 | 🟢 `cos(CAT,cat)=0.8612` |

**仍未完成**：仅 **ANE 实际占用与真机性能数字**，以及 Phase 12 权重调优（无可调空间，见下文）。~~索引端到端~~ 与 ~~详情页滑动顺序~~ 均已闭环。

## 🔴🔴 真机暴露的两个致命 Bug（本地的全部测试都通过）

这一节是整个项目里最重要的一次发现。**两个 Bug 都只在真机上出现，本地 13 个门禁、数百项检查全绿。**它们共同造成：**AI 搜索在装机后第一次能用，之后永久损坏。**

### Bug 1：`FileHandle.truncate` 在 iOS 上会移动写偏移

`EmbeddingMatrixWriter.createFile()` 原来这样写：

```swift
try handle.truncate(atOffset: UInt64(EmbeddingHeader.pageSize))   // 4096
let bytes = header.serialized()
try handle.write(contentsOf: bytes)        // 写"当前偏移"
```

- iOS 上 `truncate(atOffset:)` 把**写偏移留在新的文件末尾**（4096），于是表头被写到 4096 处，**前面留下一整页 0**
- **macOS 上偏移保持 0**，文件是对的
- 🔬 **确凿证据**：把设备上的文件拉下来 `xxd`
  ```
  文件大小: 8192   （应为 4096）
  offset 0x0000: 00 00 00 00 00 00 00 00 ...   ← 一整页零
  offset 0x1000: 50 56 45 4d 42 30 30 31 ...   ← "PVEMB001" 表头在这里
  ```
- 😈 **为什么是"第一次能用、之后永久坏"**：首次 `open` 时文件不存在，走 `createFile()`，而**表头对象还在内存里**，根本不回读文件 → 一切正常。**之后每次 `open` 都要解析磁盘上的文件** → magic 对不上 → `notAnEmbeddingFile`
- 修法：写入前 `try handle.seek(toOffset: 0)` 显式定位

### Bug 2：`createFile()` 写了一个校验和为 0 的表头

- 只有 `writeHeader()` 会先 `header.checksum = header.computedChecksum()`；`createFile()` 直接 `serialized()`，而 `EmbeddingHeader.init` 的 `checksum` 默认值是 **0**
- 于是新建矩阵落盘时校验和是 0，下次解析时算出的真值与 0 不符 → **`headerCorrupt`**
- 也就是说：**就算修好 Bug 1，第二次 `open` 仍会失败**，只是错误从 `notAnEmbeddingFile` 变成 `headerCorrupt`。两个都得修
- 修法：新增 `mutating func serializedWithValidChecksum()`，`writeHeader()` 与 `createFile()` **都只能通过它取字节**，从根上杜绝"某个调用点忘了算校验和"
  - ⚠️ 中途我尝试让 `serialized()` 自己算校验和，结果 **段错误**：`computedChecksum()` 正是基于 `serialized()` 实现的，构成无限递归。已改为单一 mutating 入口

### 为什么本地测试一个都没抓到

🔴 **本节原先给出的原因是错的，已更正。** 我当时写的是"iOS 与 macOS 的 Foundation 行为差异，本机生成的文件是对的"。**这是错的**——见下方实测证据。真实原因是另一个，而且这个 Bug 比我原先说的**更严重**：它不是平台差异，而是**所有平台都存在的潜伏损坏**。

#### 更正后的真相：macOS 上同样复现，字节级一致

把 `seek(toOffset: 0)` 临时去掉、在 **macOS** 上直接建一个空矩阵并读回：

```
size:        8192
magic@0:     "\0\0\0\0\0\0\0\0"
magic@4096:  "PVEMB001"
```

与真机上拉下来的文件**逐字节同一形态**（8192 字节、首字节全零、表头在 4096）。所以这**从来不是 iOS 特有行为**。

#### 那么本地测试当初为什么全过？——因为"写一行"会把损坏悄悄修好

同一个坏版本，只要 `append()` 一次，`grow()` 就会 `ftruncate` 撑开文件、并用 `writeHeader()` 的 **`pwrite(..., 0)`（显式偏移 0）** 把表头写回开头：

```
after ONE append -> size 528384, magic@0 "PVEMB001"
reload populated matrix: OK, count 1
```

于是：

- **`createFile()` 写坏的文件，会被第一次 `append()` 自动修复**
- 当时**每一个**既有测试都至少写过一行再去读，所以**全部通过**
- 唯一漏网的是"**建好矩阵但一行都没写**"——也就是自检（0 张照片、无权限）和**全新安装、首轮索引还没跑完**的状态

#### 这个更正让 Bug 更严重，不是更轻

- 它不是"真机才会遇到的怪癖"，而是**任何平台、任何新装**都可能留下一个 8192 字节的坏死矩阵
- 触发条件宽得多：**只要 App 在"建好矩阵"和"写入第一行"之间被杀掉**（首轮索引刚开始就被切后台、崩溃、用户强退），索引就永久损坏
- 换句话说：**我先前把它归因于平台差异，等于把一个普遍性缺陷缩小成了设备特例**

#### 教训

📌 我**没有验证**就写下了一个听起来很专业、也很有解释力的原因（"平台差异"），并把它写进了文档、报告给了用户。真正该做的是**把修复撤掉跑一次**——这个实验只花了不到一分钟。**"解释得通"不等于"验证过"**；一个错误的根因比没有根因更危险，因为它会让人停止追问。

#### 真正的防线是那条断言"磁盘字节布局"的新测试

它能挡住这个 Bug，靠的**不是**平台差异，而是它**建完矩阵后不写任何行就去读**——正好落在既有的盲区里。

### 新增回归测试

`embeddingstore_test` 增加 4 项（现 **38 项全过**），直接断言**磁盘字节布局**而不是"能不能重新打开"：

- 文件恰好 4096 字节
- offset 0 处就是 magic（不是零页之后）
- 第一页不是填充零
- **空矩阵能从磁盘重新载入**（这正是真机上失败的场景）

📌 断言布局而非行为，是这次能留下防线的原因：在 macOS 上"重新打开"对错两种情况都会通过。

### 同类缺陷排查

全项目扫过 `truncate` / `seek` / `ftruncate`：该模式**只出现在这一处**，其余都是"先 `seekToEnd` 再追加"（正确）或用 `pwrite` 显式偏移（正确）。**没有第二处**。

### ⚠️ 尚未完成：修复后的真机复验

- 修好后重新安装，设备上**仍报 `notAnEmbeddingFile`**——这是**正确的**：那份 8192 字节的坏文件还在容器里，"失败要响亮"的设计拒绝使用它
- 这暴露一个产品层面的缺口：**踩中该 Bug 的用户会永久卡死**，没有自愈路径。embedding 矩阵是派生数据，理论上应当"坏了就重建"，而不是永远失败
- 我已 uninstall + install 清空容器准备复验，但**设备随后被锁屏**（`device was not, or could not be, unlocked`），无法继续启动验证
- 🔜 **待办**：(a) 解锁设备后完成"连续两次启动都 open ok"的复验 —— **仍待办，设备连续两轮处于锁屏**

### ✅ 已修复：损坏的 embedding 矩阵现在会自愈重建

上一轮发现的缺口（"踩中 Bug 的用户永久卡死"）已补上。`EmbeddingStoreError` 新增 `isRebuildable`，`AIPhotoSearchStore.openIfNeeded` 在建 writer 失败且**属于损坏**时改走 `rebuildEmbeddingMatrix()`。

**重建必须同时重置行，这不是可选的**：slot 由矩阵分配，重建后的矩阵从空开始，任何还带着旧 `embedding_slot` 的行都会解析到错误向量（或解析不到）。所以重建会把 `embedding_slot` 清空、`status` 退回 `pending`，让下一轮索引重新嵌入。

#### ⚠️ 一个被我一度越过、又被测试挡回来的边界

我最初把 `dimensionMismatch` / `modelMismatch` 也划进"可重建"，理由是"派生数据，坏了就重建"。**`index` 门禁立刻以 3 项失败否掉了我**：

```
[FAIL] reopening the index with a different model is rejected
[FAIL] opening the index with a different dimension is rejected
[FAIL] there are assets to read — 0
```

这说明"维度/模型不符必须**拒绝**"是一条**有意为之且有测试保护**的契约（`EmbeddingMatrixWriter` 的注释也写着 "Fails loudly ... rather than silently mixing incompatible vectors"）。按我的改法，用户换个模型会**静默丢掉一个完好的索引**，而且会掩盖调用方传错参数的 Bug。

已收窄为**只重建真正的损坏**（`notAnEmbeddingFile` / `unsupportedVersion` / `headerCorrupt` / `shortRead`）；环境类失败（磁盘满、无权限）同样不重建——那些条件下重建会以同样方式失败，删掉一个还能读的矩阵只会让情况更糟。

📌 教训：这条边界不是靠推理定的，是**测试明确否决了一个看起来合理的"改进"**。差一点就以"更健壮"为名破坏了一条契约。

#### 新增回归测试（pipeline 门禁 50 → 56 项）

覆盖：先嵌入若干资产 → 把矩阵损坏成不足一页 → 用新句柄重开（模拟重启）→ **必须成功**、矩阵从空开始、所有资产退回 pending、且**能立刻写入**（从 slot 0 开始）。

## 🟠 同类隐患：换模型会把搜索永久锁死（已修复）

上一轮修完"损坏矩阵永久卡死"后，我沿同一类问题往下查，发现**换模型**会造成一模一样的下场。

### 问题

`SmartSearchModel.prepare()` 原本直接调 `store.open(dimension:sourceModelSHA256:)`。而指纹就是 manifest 的名字（`siglip2-base-patch16-256-w8`）：

```swift
return String(repeating: "0", count: max(0, 64 - manifest.name.count)) + manifest.name
```

**只要将来发一版新模型（换量化、换底座、换版本号），指纹就变**，`open` 抛 `modelMismatch`，`prepare()` 落到 `phase = .failed` —— 所有老用户的搜索页**从此永久打不开**，且没有任何自愈路径。这与上一轮那个 Bug 是同一个病：**一个永远出不来的状态**。

### 修法：把"策略"和"契约"分开

关键是不能改 `open` 的语义——"维度/模型不符必须拒绝"是有测试保护的契约（上一轮我刚被它挡回来）。所以新增一个**独立入口**：

```swift
func openRebuildingIfIncompatible(dimension:sourceModelSHA256:) throws
```

- `open` 保持严格拒绝（契约不变、测试不变）
- 应用层显式选择"不符就重建"策略，由 `SmartSearchModel` 调用
- 复用已经测过的 `rebuildEmbeddingMatrix()`，不写第二套重置逻辑

### ⚠️ 一个被测试挡回来的过度设计

我最初的重建是**把数据库和矩阵一起删掉**，测试立刻报：

```
[FAIL] while the asset itself is kept and re-queued — 0/0
```

对，但**过头了**。`ai_asset` 里存的不全是模型派生的东西——拍摄时间、GPS、OCR 文本都和 SigLIP2 无关。全删会把这些一并丢掉，并逼出一次**对 10 万张照片的 PhotoKit 全量重扫**。

真正需要丢的只有 embeddings（两个模型的向量不可比），而这正是 `rebuildEmbeddingMatrix()` 已经在做的事：清空 `embedding_slot`、把行退回 `pending`。**元数据留下，向量重embedding**。

📌 连续两轮，都是"看起来更彻底/更健壮的做法"被测试证伪。这已经不是巧合，而是这个项目里一个稳定的规律：**派生数据的边界比直觉窄**。

### 测试（index 门禁 69 → 77 项）

覆盖：老模型建好索引 → 新模型 `open` **仍然拒绝**（契约回归） → 新模型走重建入口**成功** → 旧向量清空、资产保留并退回 pending → 从 slot 0 可写 → 新模型下重启再开**仍成功**；维度变化同样能重建。

## 顺带修掉的一个自检工具陷阱

`AISearchSelfCheck`（DEBUG 工具）原来这样开真实的索引：

```swift
try store.open(dimension: 768, sourceModelSHA256: String(repeating: "0", count: 64))
```

两个问题：

1. **硬编码 768**，违反方案 §3"嵌入维度必须从转换元数据读取，不得硬编码"
2. 用**假指纹**打开**应用的同一个索引文件**。一旦应用真的建过索引，自检就会报 `modelMismatch`；更糟的是，若把它接到重建入口上，它会**每次运行都清空用户索引**

修法是消除重复来源：把指纹算法挪到 `SearchModelResources.modelFingerprint()`（紧挨它派生的 manifest），`SmartSearchModel` 与自检**共用同一份**；自检改用 `manifest.embeddingDimension` + 真实指纹，与应用完全一致。这样两者不可能再漂移。

## 模拟器：把"真机才能验"的项拉回本地（本轮新增）

模拟器跑的是 **iOS Foundation**，不是 macOS 的那套。iPhone 17 Pro / iOS 26.3 上跑 `--pv-ai-selfcheck`，得到三件事：

### 1. 🔴 存储 Bug 在模拟器上同样复现 → 该修复**不再依赖真机**

模拟器上连续两次启动自检：

```
run 1: open: ok
run 2: open: ok      ← 修复生效
```

配合前面"撤掉修复后 macOS 与真机字节级一致（8192 / 首字节全零 / 表头在 4096）"的实测，可以确定：

- 这个 Bug **与平台无关**，模拟器是**有效的验证载体**
- 因此"存储层修复"这一项**已经验证完毕**，不再挂在锁屏的真机上
- 回归防线就是 `embeddingstore_test` 里那条**建完矩阵不写行就读回**的断言（38/38）

📌 这也意味着：**此前把它记为"真机待验"是我把问题定性错了**——它不是设备特例。

### 2. ✅ `MLComputePlan` 探针工作正常

```
vision ops total:   716
vision placement:   cpu 306, unassigned 410
```

- 探针能跑通、能给出逐算子的 placement 统计——**在真机上它就会给出 ANE 与 GPU 的分布**，从而回答"视觉塔编码时间 3.3× 波动是否来自 ANE/GPU 切换"这个悬而未决的问题
- 模拟器没有 ANE（`compute devices: gpu, cpu`、`neural engine: NOT AVAILABLE`），所以这里显示 cpu/unassigned 是**正确**的，不是探针坏了
- 这同时验证了上一轮 `deviceUsage(for:)` 那套 API 用法是对的

### 3. ⚠️ 模拟器上拿不到照片权限（已尝试，未解决）

`PHPhotoLibrary.authorizationStatus` 始终返回 `notDetermined`，即使：

- `xcrun simctl privacy <dev> grant photos com.misswell.PhotoVault`（也试了 `grant all`）
- **TCC 库里确实写进去了**：`kTCCServicePhotos | com.misswell.PhotoVault | 2`（2 = allowed）
- `NSPhotoLibraryUsageDescription` 在 Info.plist 里存在
- 先正常启动一次、再带自检参数启动

TCC 说允许、PhotoKit 说未决定，说明模拟器上 PhotoKit 的授权状态没走 TCC、或有独立的守护进程状态。**没有再花时间钻**——这是工具链行为，不是本项目的问题。

**代价**：新加的 `identifier order` 探针在模拟器上被跳过了，所以"`fetchAssets(withLocalIdentifiers:)` 是否保持传入顺序"这个问题**仍未得到答案**。它会：

- 在真机解锁后自动给出答案（探针已就位）
- 决定 Phase 9 那条遗留（详情页左右滑动顺序）是"改一行"还是"需要有序分页器"

### 本轮结论：哪些"真机待办"其实不用等真机

| 项 | 状态 |
|---|---|
| 存储层修复（Bug 1/2） | ✅ **本地已闭环**（平台无关 + 回归测试） |
| `MLComputePlan` 探针可用性 | ✅ 模拟器已确认能跑 |
| ~~ANE/GPU 实际分布~~ | ✅ `neuralEngine 306`／716 视觉算子 |
| ~~Limited Photo Access / 端到端索引~~ | ✅ 已闭环（模拟器 + TCC 三态实测） |
| ~~详情页滑动顺序的前置事实~~ | ✅ 已作答且已修复：`input order kept: NO` |
| 真机性能数字 / ANE 占用 | ⏳ 仍需真机 |

## 🟢 真机之外的端到端验证：模拟器上跑通整条链路（本轮突破）

模拟器上把照片权限打通后，第一次可以**在真实 PHPhotoLibrary 上跑完整条流水线**，而不是拿合成数据分别测每一段。

### 打通权限为什么难（以及最后怎么解的）

- `xcrun simctl privacy <dev> grant photos` **不管用**：TCC 库里确实写进去了（`kTCCServicePhotos | auth_value 2 | auth_reason 4`），**PhotoKit 照样弹自己的弹窗**，App 卡在一个没人能点的模态上，自检永远写不出日志
- 截图确认了这一点：弹窗写着「PhotoVault 想完全访问你的照片图库」，17 Photos
- `simctl` 没有 tap/input 子命令；macOS 侧合成事件到不了模拟器窗口（项目既有结论）
- **所以走 XCUITest**——新增 `PhotoVaultUITests/AIPhotoAccessGrantUITests.swift`（**新文件，没有碰用户正在写的那份未跟踪测试文件**），pbxproj 用显式引用注册
- 实测 `passed (6.616 seconds)`——6.6s < 20s 超时，说明它**真的点到了**按钮，不是超时溜过去的

📌 副作用是正向的：`PhotoViewerDismissUITests` 需要"网格里有照片"，在没授权的干净模拟器上会以「图库网格应加载出照片」失败，**把权限问题伪装成 UI 回归**。这个 grant 测试让整套 UI 测试在干净模拟器上可跑。

### 端到端实测（iPhone 17 Pro 模拟器 / iOS 26.3 / 17 张真实照片）

**第一次（冷启动，无索引）**

```
metadata inserted:  17 updated: 0 deleted: 0
metadata fullscan:  true  limited: false
assets to index:    17
index run:          13.9 s
embedded:           17   pending: 0   failed: 0
with text:          5
search "a red square" -> 5 hits, candidates 17
search "蓝色"          -> 5 hits, candidates 17
search "green"        -> 5 hits, candidates 17
```

**第二次（重启进程后）**

```
metadata inserted:  0 updated: 0 deleted: 0
metadata fullscan:  false          ← 变更令牌生效，没有全量重扫
index run:          0.0 s          ← 一行都没有重嵌
embedded:           17   pending: 0
open:               ok
```

这一次性验证了 §82 的**三项**，而且是在真实 PhotoKit 上：

| §82 项 | 证据 |
|---|---|
| **增量索引** | 第二轮 `inserted 0`、`fullscan false`——靠 `PHPersistentChangeToken`，不是库签名 |
| **索引在重启后续跑** | 第二轮 `run 0.0 s`、`embedded 17` 保持不变，说明跨进程持久化正确 |
| 中文自然语言搜索 | `蓝色` 返回 5 条；英文 `green` 同样 |

同时顺带验证了：`PhotoKitMetadataSync` 全量首扫 → 增量、`PhotoKitImageLoader` 取图、`SigLIP2VisionEncoder` 嵌入（17/17 成功、0 失败）、`PhotoTextRecognizer` OCR（17 张里 5 张有文字）、`EmbeddingMatrixReader` 读取、`PhotoSearchEngine` 检索，**整条链路没有一段是假的**。

### 🔴 顺带用实测回答了 Phase 9 的悬案：PhotoKit **确实不保持**传入顺序

```
assets in library:  17
requested first:    AA91AB0D, F80027A9
returned first:     106E99A1, 99D53A1F
input order kept:   NO
returned count:     8 of 8
```

- 数量对（8/8），**顺序不对**。`fetchAssets(withLocalIdentifiers:)` 的返回顺序确实与传入顺序无关
- ✅ 所以详情页"左右滑动是 PhotoKit 顺序而非相关性排名"这条遗留**是真的**，不是臆测——此前只是写在注释里的推断，现在是测量结果
- ✅ 也反证了既有代码"必须按 identifier 反查真实下标"的决定是对的：直接把名次当 `initialIndex` 会打开**另一张**照片
- 🔜 要根治就得让查看器支持"有序序列"分页；`PhotoViewerView` 目前持有 `PHFetchResult`，改它要动约 20 处 `assets.count` / `assets.object(at:)`，而 `PhotoViewerViews.swift` / `PhotoViewerPresentationBridge.swift` 正是用户当前在改的文件，**本轮没有动**

### 新增的自检开关

| 开关 | 作用 |
|---|---|
| `--pv-ai-selfcheck` | 只读探查（默认，**绝不弹权限框**） |
| `--pv-ai-selfcheck-request-auth` | 额外**请求**照片权限（否则模拟器无法到达 `.authorized`） |
| `--pv-ai-selfcheck-index` | 额外**跑真实索引流水线并检索**（会写索引，CPU 模拟器上较慢） |

三者相互独立，默认行为（不弹窗、不写索引）保持不变。

## 🟢 §82 最后一项收口：Limited Photo Access（模拟器实测）

上一轮打通权限后，本轮把 §82 里**唯一还没有实测证据**的一项补上了。

### 怎么在模拟器上伪造"受限访问"

`simctl privacy` 只有 `grant`/`revoke`/`reset`，**没有 limited 档**。但 TCC 表里的 `auth_value` 就是权限档位：

| `auth_value` | 含义 |
|---|---|
| 0 | 拒绝 |
| 2 | 完全访问 |
| **3** | **受限（limited）** |

把 `kTCCServicePhotos` 改成 3，PhotoKit 立刻如实报告：

```
kTCCServicePhotos|3
photo access:       limited
```

### 受限访问下跑完整条流水线

```
== end-to-end index ==
metadata inserted:  0 updated: 0 deleted: 0
metadata fullscan:  false  limited: true      ← PhotoMetadataSyncResult.isLimited 正确上报
assets to index:    17
index run:          0.0 s
embedded:           17   pending: 0   failed: 0
with text:          5
search "a red square" -> 5 hits, candidates 17
search "蓝色"          -> 5 hits, candidates 17
search "green"        -> 5 hits, candidates 17
```

- ✅ `.limited` 被当作**一等状态**：`isLimited: true` 正确冒泡到同步结果，索引与检索照常工作，**不崩**
- ✅ 自检开头也如实报告 `photo access: limited`（不是把受限当成授权或拒绝）

### 顺带验证"拒绝访问"的健壮性

把 `auth_value` 改成 0：

```
photo access:       denied
identifier order:   skipped: no photo access (denied)
open:               ok
total assets:       17                      ← 既有索引仍可读
end-to-end FAILED:  accessDenied
app still running:  1                       ← 没有崩溃
```

- ✅ 拒绝时抛的是**有类型**的错误（`PhotoKitIndexSourceError.accessDenied`，`PhotoKitIndexSource.swift:89` 的授权守卫），不是野错误或崩溃
- ✅ **既有索引仍然可读**——权限被撤销不会连带把已建好的索引变成不可用
- ✅ 进程存活（`launchctl list` 仍能看到），符合 §82"不崩"的要求

### §82 现在的完整状态

| 类别 | 状态 |
|---|---|
| 模型 / 一致性 / 索引 / 检索 / 查询 / OCR / 日期 / GPS / 相似图 | ✅ 全部门禁 + 端到端 |
| 增量索引 / 重启续跑 / 中文搜索 | ✅ 真实 PhotoKit 端到端实测 |
| **Limited Photo Access** | ✅ **本轮补上**（受限 + 拒绝两种状态） |
| iCloud 不可用 / 低电量 / 严重发热 / benchmark / 不上传 / Release 无日志 / 第三方声明 | ✅ 既有证据 |
| ~~ANE 实际占用 / 真机性能数字~~ | ✅ 已实测：ANE 可用且在用；视觉 160 ms／文本 2.9 ms |

## 🟠 Phase 12 首次拿到"权重调优"的实测证据：0.02 这条下限其实不起作用

方案 §6/Phase 12 要求做**权重调优**。代码里 `PhotoSearchConfiguration.minimumScore = 0.02` 一直挂着一条注释，说它是"去掉长尾噪声的小正下限"，并且写着"Phase 12 会拿标注集调这个值"。**这个说法从来没有被测量过**，本轮补上了。

### 测量（17 张真实照片，走完整发布流水线）

```
search "a red square"     5 hits  [0.132 0.084 0.075 0.074 0.073]
search "蓝色"              5 hits  [0.096 0.087 0.079 0.079 0.078]
search "green"            5 hits  [0.136 0.096 0.078 0.074 0.072]
search "a photo of text"  5 hits  [0.087 0.084 0.079 0.079 0.075]
search "mountain waterfall" 5 hits [0.088 0.078 0.071 0.050 0.049]

floor probe "a red square"      17/17 通过 0.02，均值 0.060
floor probe "mountain waterfall" 16/17 通过 0.02，均值 0.044
```

### 结论：这条下限**一个都没挡掉**

- 「a red square」把**全库 17 张**都放行了；「mountain waterfall」放行 16/17
- 检索分数集中在 **0.05–0.14** 这条窄带里，而**长尾在 0.07–0.08**——**远高于 0.02 的下限**
- 所以注释里"小正下限能去掉长尾噪声"的说法**不成立**。0.02 在这些查询上等于没有过滤

### 但**没有**去改这个值——这是刻意的

- 真正起作用的区分在**排序**，不在阈值：「green」的最高分 0.136 对长尾约 0.072，区分明显
- 若把下限提到真能"咬到"的位置（约 0.08），就会**切进同一条带**，开始对困难查询返回**空结果**——而"搜不到"正是用户读作"功能坏了"的那一种失败
- 更重要：**拿 17 张照片（其中 6 张还是纯色合成图）去调这个常数就是过拟合**。这正是 D6 记录的那件事——真正的调优需要人工标注的 ground truth，不能自欺

### 留下的可执行结论

如果将来确实需要更强的过滤，机制必须是**相对的**（低于最高分一个 margin，或按查询做校准），因为**绝对下限无法把 0.088 的最高分和 0.078 的长尾分开而不连最高分一起丢掉**。

已把这段实测写进 `PhotoSearchEngine.swift` 的 `minimumScore` 注释，替换掉原先未经测量的说法。

### 仍未完成

- ~~标注集~~ → ✅ **已自建**（`make_eval_fixture.py` + `eval_retrieval.py`）。实测 **P@1 = 10/10、MRR = 1.0**，集合逻辑与日期/GPS/相似图也各自通过，所以"权重调优"**当前没有可调空间**——在一个 10 张图的合成集上继续调阈值只会过拟合，这正是 D6 原本要防的事
- ~~Phase 9 详情页左右滑动顺序~~ → ✅ 已修复（`ViewerAssets`）
- ⏳ 真机 ANE 占用与性能数字（唯一剩余项）

## 🟢 Phase 9 详情页滑动顺序：已修复并验证

上一轮实测确认了 `fetchAssets(withLocalIdentifiers:)` **不保持传入顺序**。本轮把这条遗留修掉了。

### 修法：让"顺序"成为查看器的一等概念

新增 `ViewerAssets`（`PhotoViewerViews.swift`）：

```swift
enum ViewerAssets {
    case fetch(PHFetchResult<PHAsset>)   // 普通图库/相册：仍是活数据
    case ordered([PHAsset])              // 搜索结果：相关性排名
    var count: Int { ... }
    func object(at index: Int) -> PHAsset { ... }
}
```

关键点：查看器**本来就只问两件事**——多少张、第 n 张是谁。把这两件事抽成一个类型后：

- ✅ **约 20 处 `assets.count` / `assets.object(at:)` 一行都不用改**
- ✅ 顺序由**类型**保证一致：分页器、胶片条、信息面板读的是同一个序列，索引不可能错位
- ✅ 普通图库路径仍然传 `PHFetchResult`（活的、懒加载的），**没有**为了搜索把 10 万张图变成数组

改动面：`PhotoViewerView` / `AssetPager` / `ViewerFilmstrip`(含 UIKit Coordinator) / `ViewerNeighborPrefetch.update` 的类型，加上 2 个构造点（`PhotoGridScreen` → `.fetch`，`SmartSearchScreen` → `.ordered`）。`IndexedPhotoViewerView` / `SlideshowView` / `IndexedAssetPager` 等**未整理**那条线完全没动。

`SmartSearchScreen.open(_:at:)` 现在把 fetch 结果**只当查表用**，再按排名重新发出：

```swift
let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
var byIdentifier: [String: PHAsset] = [:]
fetched.enumerateObjects { candidate, _, _ in byIdentifier[candidate.localIdentifier] = candidate }
let ranked = identifiers.compactMap { byIdentifier[$0] }   // 排名顺序
guard let resolved = ranked.firstIndex(where: { $0.localIdentifier == asset.localIdentifier })
```

已删除的资产自然掉队；被点的资产按 **identifier** 定位而不是信 `rank`，所以过期的命中不会打开错照片——原先"必须反查下标"的那个正确决定被保留了。

### 验证

自检里原来的 identifier-order 探针扩展成同时验证修法（真机/模拟器同款 API）：

```
input order kept:    NO        ← PhotoKit 确实不保持顺序
returned count:      8 of 8    ← 但一张都不少
fetch usable as map: YES       ← 可以当查表用
ranked rebuild order: kept     ← 重建后严格等于请求顺序
```

外加 `PhotoViewerDismissUITests` **6/6 全过**（关闭、下拉退出、短拉取消、翻页后关闭、未整理下拉退出、静止帧暂停），证明这次改类型**没有**碰坏查看器的既有行为。

📌 说明：6 个 UI 测试走的是 `.fetch` 分支；`.ordered` 分支由上面的探针证明其排序正确。

## 🟢 Phase 11 质量验收：首个端到端"检索质量"实测（带标注集）

此前所有检查测的都是**零件**：`textencoder` 拿转换后的文本塔和 Python 参考比，`search` 拿合成向量验融合规则，benchmark 测吞吐。**没有一个回答"我输入这句话，正确的那张会不会排第一"**——那需要一个内容已知的照片库。

本轮补上了：`tools/models/make_eval_fixture.py` 生成确定性标注集（纯色块 + 渲染文字），`simctl addmedia` 导入，App 自检输出每条的排名（带**原始文件名**），`tools/models/eval_retrieval.py` 做标注连接与打分。

### 结果（iPhone 17 Pro 模拟器 / iOS 26.3 / 20 张库）

```
query                  P@1    R@k     RR  top hit
a blue image          1.00   1.00   1.00  ok  photo2.jpg (0.1275)
a cyan image          1.00   1.00   1.00  ok  photo5.jpg (0.1445)
a green image         1.00   1.00   1.00  ok  photo1.jpg (0.1314)
a purple image        1.00   1.00   1.00  ok  photo4.jpg (0.1336)
a red image           1.00   1.00   1.00  ok  exiftest.jpg (0.1335)
a yellow image        1.00   1.00   1.00  ok  photo3.jpg (0.1332)
an invoice            1.00   1.00   1.00  ok  invoice.jpg (0.1632)
a passport            1.00   1.00   1.00  ok  passport.jpg (0.1578)
"INVOICE"             1.00   1.00   1.00  ok  invoice.jpg (1.0000)
"PASSPORT"            1.00   1.00   1.00  ok  passport.jpg (1.0000)

precision@1 10/10 = 1.0000    MRR 1.0000
```

### 这个基准**能失败**（否则毫无价值）

把 "a blue image" 的前两名对调，P@1 掉到 0.8750、MRR 掉到 0.9375、**退出码 1**。

📌 顺带发现：`--require-recall` **抓不到**这种回归——recall 与顺序无关，而"把正确答案从第 1 名压到第 6 名"恰是用户唯一能感觉到的失败。所以另加了 `--require-precision`。

### 🔴 更正一个我差点写错的结论：OCR 并非由"语义"触发

标注集里特意放了**带引号**的查询。实测：

```
evalplan|an invoice|candidates=20|ocr=      |clauses=1
evalplan|"INVOICE" |candidates=1 |ocr=INVOICE|clauses=0
```

- 带引号是方案里约定的**精确文本**请求，也是**唯一**会填充 `ocrTerms` 的写法
- 所以 `"INVOICE"` 由 Vision OCR 把 20 张过滤到 **1 张**；而不带引号的 `an invoice` **一个都没过滤**，它赢在**外观**（白底黑字看着就像文档）
- ⚠️ 把前者当成 OCR 的证据是**错的**。`evalplan|` 这行存在的意义就是让这个区别**可见**，而不是靠推测

### 标注集本身怎么标出来的（这段有坑）

- `simctl addmedia` **会丢弃 EXIF `DateTimeOriginal`**（实测：文件里写的是 2015-06-01，导入后库里是导入时刻），所以**不能**用拍摄时间当标签
- Photos 库的 `ZFILENAME` 会**改名**成 `IMG_nnnn.JPG`，且**导入顺序被打乱**——实测 `photo4.jpg` 拿到 `IMG_0012`。**按导入顺序猜标签会得到一整组错的地面真值**
- 真正可用的是 `PHAssetResource.originalFilename`（保留原始文件名）。上述映射是在比对 DCIM 原文件 md5 后确认的，不是猜的

### 适用范围（写在明处）

这是**模拟器上的渲染图标注集**，不是真机结论，也不能替代真实照片库；绝对分值与真实库不可比。它确立的是：**PhotoKit → 视觉塔 → 向量矩阵 → 查询解析 → OCR 过滤 → 融合 → 排序**整条链路能把正确的资产排到第一——这是其它任何检查都没做到的。

## 🟢 AND / NOT / OR 在真实照片上的端到端实测

`query` 门禁（64 项）和 `search` 门禁（58 项）覆盖这些规则时用的是**合成输入**。本轮在**内容已知的真实照片**上再跑一遍——这里否定子句必须靠**真实 embedding** 去越过配置的上限，而不是靠手工构造的向量。

```
evalplan|a red image or a green image |clauses=2|combine=any|neg=0
evalplan|a red image and a blue image |clauses=2|combine=all|neg=0
evalplan|a red image not a cyan image |clauses=2|combine=all|neg=1

a red image or a green image   exiftest 0.1335  photo0 0.1324  photo1 0.1314  ...   两种颜色都在
a red image and a blue image   IMG_...  0.0688  photo5 0.0665  photo2 0.0659  ...   无解 → 不自信
a red image not a cyan image   exiftest 0.1335  photo0 0.1324  photo1 0.0644  ...   青色 photo5 消失
```

- ✅ **OR**（`combine=any`，max 融合）：两张红 + 一张绿都留在前 3
- ✅ **AND**（`combine=all`，min 融合）：没有照片既是红又是蓝，最高分塌到 **0.0688**，而真实命中约 **0.13**——"不自信"正是无解时应有的表现
- ✅ **NOT**（`neg=1`）：`photo5.jpg`（青色）在 OR 查询里以 0.0872 出现在列表中，加上 `not a cyan image` 后**被直接拒绝**

### 这些断言**检查的是解析结果，不只是排名**

断言同时核对 `QueryAnalyzer` 自己产出的 `combine` / `neg` 字段——**"看起来对但原因是错的"同样会失败**。两种变异都已验证：

| 变异 | 结果 |
|---|---|
| 把青色照片塞回 NOT 的结果里 | `FAIL`：`photo5.jpg should have been rejected`，退出码 1 |
| 把 `combine=any` 改成 `all` | `FAIL`：`combine='all' expected 'any'`，退出码 1 |

## 🟢 日期与 GPS 过滤：端到端实测（§82「日期/GPS」收口）

此前的向量查询**完全不经过元数据路径**。本轮把另一半也测了：离线地名库把地名解成坐标，日期解析器产出区间。

标注集中三张图分别带**北京/上海/东京**的 GPS EXIF。（实测：`simctl addmedia` **会丢弃 `DateTimeOriginal`，但保留 GPS**——所以日期用例靠"同一批导入"而不是 EXIF。）

```
evalplan|北京        |candidates=1|ocr=|clauses=0|combine=all|neg=0
evalplan|上海        |candidates=1|...
evalplan|东京        |candidates=1|...
evalplan|2026年9月14日|candidates=6|...

北京         ok  gpstest.jpg  @ 39.9042,116.4072
上海         ok  shanghai.jpg @ 31.2304,121.4737
东京         ok  tokyo.jpg    @ 35.6762,139.6503
2026年9月14日 ok  6 results, all on 2026-09-14
```

- ✅ 每个城市查询把 **23 张缩到恰好那一张**——地名解错就**什么都找不到**，而不是找到"看着差不多"的东西
- ✅ 日期查询返回同一批导入的 6 张，全部落在请求区间内

### 两种变异都已验证会失败

| 变异 | 结果 |
|---|---|
| 「北京」解到东京的坐标 | `FAIL: 35.6762,139.6503 is 4.228,23.243 from the expected city`，退出码 1 |
| 日期过滤里混进一张 2011 年的照片 | `FAIL: tokyo.jpg is dated 2011-03-13, outside the requested range`，退出码 1 |

### 顺带查证的一个真实边界：无定位的哨兵值

PhotoKit 在自己库里给**没有定位**的资产存的是 `-180,-180`。索引读的是 `PHAsset.location`，那些资产拿到的是 `nil`，因此被正确排除——23 张库里 `with location: 8`，正好是 Apple 那 5 张真有坐标的 + 我加的 3 张。

⚠️ 若把哨兵值当真，**靠近 180° 经线的查询会匹配到完全没有定位的照片**。这条已确认**没有**发生。

## 🟢 相似图搜索：端到端实测（§82 该项收口）

每张种子图的最近邻在标注集中是已知的，而且**种子不能出现在自己的结果里**——把自己的查询图当成最相似的一张，正是这个功能"看起来能用、其实坏了"的典型表现。

```
photo0.jpg (红)  -> exiftest.jpg (0.9725)   红的最相似是另一张红
photo5.jpg (青)  -> photo2.jpg   (0.9732)   青的最相似是蓝
invoice.jpg (文字)-> passport.jpg (0.7166)  一页纸最像另一页纸
```

- ✅ 分数排序合理：两张纯色在 **~0.97**，两页渲染文字（版式和底色相同、内容不同）在 **~0.72**
- ✅ 三张种子**都没有返回自己**

两种失败模式都已变异验证：

| 变异 | 结果 |
|---|---|
| 种子把自己排到第一 | `FAIL: the seed photo0.jpg returned itself`，退出码 1 |
| 最近邻换成错的 | `FAIL: top is photo1.jpg, expected photo2.jpg`，退出码 1 |

## 🔴→✅ Phase 4 的 Metal 内核：从"死代码 + iOS 上算错"到**定位并修复**

本轮最重要的工作。起因是盘点"还有哪些只在真机上才会暴露的问题"。

### 事实一：内核根本没接进 App（**仍然如此，且是有意为之**）

`MetalSimilaritySearch` 与 `EmbeddingSearchError` **除了自己那个文件以外全工程零引用**，App 走的是 `EmbeddingMatrixReader.scores(query:slots:)` → **Accelerate `cblas_sgemv`**。

### 事实二：`metal` 门禁绿得没有意义

`verify_siglip2.py metal`（31 项）把内核编译进一个 **macOS 命令行 harness**。它绿只说明"在 macOS 上正确"，**完全不覆盖 iOS**——与"转换门禁全绿而 App 里没有模型"同一类骗局。

### 事实三：在 iOS 上它曾经**算错**，根因已定位

自检新增 `== Metal search (iOS) ==`，在 App 内用真实矩阵跑内核并与 Accelerate 逐项比对（查询向量取矩阵里已存的一行，故第 0 行应自相似 ≈1.0）：

```
修复前：metal first: -1428.2224 0.0000 0.0090     ← 余弦不可能超出 [-1,1]
        cpu first:    0.9999   0.9512 0.9360     ← 正确
```

逐一排除后剩下一处**对齐**问题，实测数字直接指认：

```
page size:          16384          ← getpagesize()
header page:         4096          ← EmbeddingHeader.pageSize
row start aligned:  NO             ← base + 4096 不是 16384 的倍数
mmap base aligned:  YES
```

- 🔴 **根因**：`makeBuffer(bytesNoCopy:)` 要求指针**页对齐**。mmap 基地址是对齐的，但行数据在**一个 header 页之后**，而 4096 **不是**硬件页大小 16384 的倍数 → 传给 Metal 的是个非页对齐指针，GPU 读到了完全错误的内存
- **macOS 容忍了它**（同一份代码在 macOS harness 上一直绿），iOS 不容忍。这正是"平台差异"的真实来源——上一轮我曾猜测是 `NSData` 桥接拷贝，**实测同指针，已排除**；也确认 `commandBuffer.error` 被检查且未触发

### ✅ 修复：整段 wrap，绑定时再偏移（保持零拷贝）

```swift
// 包住整个映射（基地址页对齐），行偏移改在 setBuffer 时给
let rowBuffer = device.makeBuffer(bytesNoCopy: base, length: mapped.count, ...)
...
encoder.setBuffer(rowBuffer, offset: EmbeddingHeader.pageSize, index: 0)
```

**修复后实测**：

```
metal top-10 == cpu:   YES
metal first:        0.9997 0.9511 0.9358
cpu first:          0.9999 0.9512 0.9360
max score delta:    1.39e-04        ← Float16 存储精度，正是应有的量级
```

- ✅ 排序与 Accelerate **完全一致**；分数差 1.39e-04 是 float16 量化的固有精度
- ✅ macOS `metal` 门禁 **31 项仍全绿**（修复没有破坏原有平台）
- ✅ 零拷贝性质保留（仍是 mmap 直通显存）
- ✅ 顺带修掉一处隐患：dispatch 的 256 线程宽**改为对 `pipeline.maxTotalThreadsPerThreadgroup` 取小**（本机上限 512，虽不致病，但"假设首选宽度被接受"本身不成立）

### 为何仍然不接进搜索路径：**已用数据定论**（不再是"待测"）

上一轮把这条留成"待真机数据"的开放决策，本轮**在 macOS 上补测掉了**——新增 `tools/models/metal_scale/main.swift`，在**同一个 10 万 × 768 矩阵、同一组查询**上比两条路径：

```
accelerate: P50 9.16 ms, P95 9.41 ms, min 8.95 ms
metal:      P50 8.97 ms, P95 9.21 ms, min 5.74 ms
speedup:    1.02x                      ← 是噪声，不是收益
top-100 rankings agree: YES
max score delta:        6.56e-07
```

- 🔬 **1.02× 说明 GPU 在这里没有优势**：扫描是**内存带宽受限**的（每次查询读 **192 MB**），GPU 和 CPU 等的是同一条带宽，换执行单元不解决问题
- ✅ **top-100 排序一致、分数差 6.56e-07**：快路径与参考路径给出**同一个答案**，所以"哪条出货"纯属性能问题——而性能问题的答案是"无所谓"
- ✅ 结论：**Accelerate 出货是正确的**（已 ~55× 余量），接 Metal 只会多一个 Metal 依赖、一次管线编译和第二条需要信任的代码路径，换取 2%
- 📌 与上一轮的区别：那时说"Metal 大矩阵收益未测"，**现在测了，收益确实不存在**。这是**已定论**，不再挂起
- 📌 `== Metal search (iOS) ==` 探针保留：任何人想启用这条路径，先让它变绿


## 🟢🟢 真机验收完成（第 31 轮）——所有"需真机"项一次性收口

设备在连续 14 轮锁定后首次解锁。App 成功安装并启动，自检在**真实相册（104,462 张）**上跑通。以下全部是**真机实测输出**，不是模拟器推断。

### Core ML 与 ANE

```
compute devices:    neuralEngine, gpu, cpu
neural engine:      available
vision ops total:   716
vision placement:   neuralEngine 306, unassigned 410
```

- ✅ **ANE 确实可用，且确实被使用：716 个视觉算子中 306 个落在 `neuralEngine`**。这条从 Phase 2 起就挂着"需真机"的项**到此关闭**
- 📌 410 个 `unassigned` 是 Core ML 的常规结果（运行时按可用后端调度），不是"没放上去"

### 一致性在真机上成立（§82「一致性测试通过」真机复核）

```
cos(CAT, cat):      0.8612 (expect ~0.8616)
```

- ✅ 与 macOS 参考（0.8616）、进包门禁（0.8610）**三方一致**。词表错配、误加大小写折叠、或模型陈旧都会让这个数字偏离，它在真机上依然成立
- ✅ **这证明"故意不做大小写折叠"的分词器在真机上是同一对**

### 真机延迟（首次拿到设备数字）

| 项目 | 真机 | M1 对照 |
|---|---|---|
| 视觉编码 P50 | **160.0 ms** | 9.87 ms |
| 文本编码 P50 | **2.9 ms** | 9.19 ms |
| 视觉首次加载 | 3362 ms | — |
| 文本首次加载 | 19531 ms | — |
| SQLite | **3.54.0**，FTS5 + trigram ✓ | 3.51.0 ✓ |

- 🔴 **视觉编码在真机上比 M1 慢 16×**。这不是缺陷（ANE 上小批量逐张推理本就如此），但它是**首次建索引耗时的决定性数字**：
  **104,462 张 × 160 ms ≈ 4.6 小时**纯编码，还不含 I/O 与 OCR
- ✅ **文本编码反而比 M1 快 3×**（2.9 ms vs 9.19 ms）——检索侧毫无压力
- 📌 这组数字**正是"暂停/续跑/热控制"必须存在的理由**：4.6 小时的首次索引，用户必然会中断它

### 端到端索引（真实相册，非合成集）

```
total assets:       104462
embedded:           166
pending:            104296
failed:             0
with location:      33304
with text:          36
photo access:       authorized
metadata fullscan:  false  limited: false
```

- ✅ **104,462 张真实资产**枚举成功，**0 失败**
- ✅ **33,304 张带 GPS**（占 31.9%）——真机上的定位数据规模远超模拟器的 8 张
- ✅ **OCR 已在真机产出文本**（36 张），中英混排的真实照片
- ✅ `fullscan: false` —— 走的是**增量**路径而非全量重建

### ✅ 杀掉后续跑：真机实测（§82 明列项）

在索引进行到 **63/104,462** 时杀掉 App，重新启动：

| 时点 | 已嵌入 |
|---|---|
| 杀进程前 | **63** |
| 重启后约 3 分钟 | **166** |

- ✅ **从 63 继续，没有归零重来**。§82「App 被杀后继续」「重启后续跑」在**真实 10 万级相册**上成立
- ✅ 其间 `failed: 0`

### 顺带真机复核的两条既有结论

- ✅ `identifier order kept: NO`（104,462 张规模下依然如此）——`ViewerAssets` 那处修复的必要性在真机上再次确认
- ✅ `requested first: A2D22CDD, DCC684A9` → `returned first: 6D08D66E, A2D22CDD`：PhotoKit **确实不保持传入顺序**

### 自检报告改为边跑边写

首次索引要 4.6 小时，而报告原先**只在结束时写一次**——App 一被杀，最需要的那份报告就没了。已改为**逐行落盘**（`say` 内即时写入，加锁串行化）：
- ✅ 本轮就是靠它**在 App 仍在索引时**读到了上面全部数据
- ✅ 同时修掉一个真实缺陷：长任务中途被杀不再丢失报告

### ⚠️ 本轮**没有**拿到的数字：真机上的 10 万条检索耗时

必须写明，避免把「真机验收完成」读成「每个数字都拿到了」：

- 为补这项加了 `--pv-ai-selfcheck-scan`：在设备上造一个 10 万×768 的合成矩阵（192 MB）并计时扫描
- **它没有跑完**。App 在造矩阵期间**被杀掉**（自检日志停在 `== 100k scan (device) ==` 标题之后，进程随后消失）
- ⚠️ **死因未定，不要采信上一轮写的"最可能是 jetsam"**：那是**猜测**。同样合理（也许更合理）的解释是**手机重新锁屏、App 进后台被系统回收**——设备随后确实变为 `unavailable`。我没有证据区分二者，就不该在基线里写成一个像是结论的推断
- 🔴 **无论如何，它是我引入的风险，已修**：该基准改为**只有显式传 `--pv-ai-selfcheck-scan` 才跑**。默认自检绝不能因为一个可选基准，把动辄数小时的真实索引一起带走
- ✅ 顺带把它做快：合成行不再做单位化（计时只需要形状正确的矩阵），省掉 7.68 千万次 `sqrt`/除法，缩短它占用设备的时间窗口
- 📌 因此 §82「10 万条检索性能」的**真机**数字**仍然缺失**。现有支撑是：M1 上同一条 Accelerate 路径 **P50 ~9.16 ms**（预算 500 ms），以及真机上**文本编码 P50 2.9 ms**（比 M1 还快 3×）——但这些是**替代证据，不是真机检索数字**。设备窗口随即关闭（`unavailable`），补测需设备再次可用

### ✅ opt-in 基准本身已验证可用（在模拟器上跑通）

上一轮只知道"它没跑完"。本轮把合成矩阵去掉单位化后，在模拟器上**完整跑通**，证明基准本身是对的：

```
== 100k scan (device) ==
rows:               100000 (dim 768)
scan P50:           7568.44 ms
scan P95:           7577.33 ms
scan min:           7546.35 ms
```

- 🔴 **模拟器上是 7.57 秒，M1 原生是 ~9 毫秒——差约 800×**。原因是模拟器里 `cblas_sgemv` 走的是没有硬件加速的通用路径
- ✅ 这**正好说明为什么"模拟器数字不能代表设备"**：同一个调用在模拟器上比真实硬件慢三个数量级，用它做性能结论会荒谬地错
- 📌 因此该基准**必须在真机上跑才有意义**；它现在已验证可跑，只等设备可用
- ✅ 三组数字并列，用途各不相同：**M1 ~9 ms**（原生、可作下限参考）、**模拟器 7.57 s**（仅证明基准能跑，值本身无意义）、**真机 = 仍缺**
