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
- `@Published` 反应面（`:108-150`）：`authorizationStatus`、`allPhotos: PHFetchResult<PHAsset>?`、`albums`、`albumFolders`、`albumStructureRevision`、`isIndexingUnsorted`、`isLoadingAlbums`、`lastIndexedAt`、`unsortedCount`、`indexStats`、`indexErrorMessage`、`quickAlbumIDs`、`recycleBinIDs`；进度走独立的 `PhotoIndexProgressReporter`（`:12-14`），经节流器 `publishIndexProgress`（`:1474-1483`，≤4 次/秒，阶段切换必发）
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
| `PhotoIndexCoordinator` 的增量驱动 | 直接复用 `PHPersistentChangeToken` 流水线（insert/update/delete 集合已现成） | `PhotoLibraryStore.swift:1485-1549`、`:1670-1689` |
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
| `Index/PhotoIndexCoordinator.swift` | 新增 | 状态机 Idle→Preparing→IndexingEmbedding→IndexingOCR→Completed（方案 §20） |
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

- [ ] **真机 ANE 实测**（compute unit 分布、首次加载耗时、峰值内存）——Mac 数据不能替代（R3/R4）
- [ ] Swift 侧 parity 测试（L1 同输入 + L2 全流程）需 XCTest target（D3）
- [ ] `tokenizer.model` 的 Swift 移植与 `verify_siglip2.py --mode tokenizer` 对照
- [ ] `.mlpackage` 尚未拷贝进工程、尚未登记进 `project.pbxproj`（D4/D5）

**Phase 1/2 未修改任何 `.swift` 或 `.pbxproj`**，与方案"不要在完成检查之前大规模修改工程"完全一致。
