# Pastelet 性能修复执行计划

日期：2026-05-29
基于：`PERFORMANCE_REVIEW.md`（用户报告） + 本次代码梳理新发现。

本文件记录"已改 / 待确认"，防止漏改或重复改。

---

## A. 本次梳理新发现（用户报告之外的补充）

| 编号 | 问题 | 严重度 | 处理 |
| --- | --- | --- | --- |
| N1 | `clampedSelection` 是计算属性，内部全量执行 `filteredItems` 过滤。在 `body` 与 `ForEach` 每张卡片里都读它 → 每次 body（含每次 hover）会对历史做 **N+ 次全量 filter**（36 卡 ≈ 36 次）。这是 hover/选中掉帧的主因之一。 | 高 | ✅ 直接改 |
| N2 | `SmoothHorizontalScrollView.updateNSView` 每次更新都 `hostingView.fittingSize`（强制整树布局测量）。hover 改 `selectedIndex` 也会触发。 | 高 | ✅ 直接改（按公式算宽度） |
| N3 | 过期清理 `pruneExpired()` 跟随 0.7s 轮询每次执行（含 `AppSettings.shared` 访问 + 全量扫描），常驻后台空转。 | 中 | ✅ 直接改 |
| N4 | `HistoryStore.save()` 全程在主线程：PNG 转码 + JSON 编码 + 写盘 + 扫描整个 images 目录删孤儿。删除/收藏/链接预览回填都会触发。 | 高 | ✅ 直接改（拆后台 + 原子写 + 降低孤儿清理频率，保留退出同步落盘） |
| N5 | 图片项在内存里持有**全分辨率** `NSImage`（卡片只显示 232pt）。36 张 4K 截图常驻 → 几百 MB。降采样会影响"粘贴回原图"的保真度。 | 高（内存） | ⏸ 待确认（见下方 Q1） |
| N6 | `ClipboardItem.fingerprint` 用 `尺寸 + tiffRepresentation.count`，既要在主线程对大图做 tiff 转码，又可能不同图碰撞同名文件→预览错图。改 hash 会让旧图片文件名失配（一次性孤儿）。 | 中 | ⏸ 待确认（见下方 Q2） |
| N7 | `ClipboardItem.==` 只比较 `id + isFavorite`，忽略 `previewTitle/previewImage` 等。当前未接 `EquatableView` 暂不致错，但是个隐患。 | 低 | 暂不动，记录 |

## B. 用户报告中本次直接处理的项

- P2「搜索过滤重复计算」→ 与 N1 合并修复（一次 body 只算一次 filtered + 选中钳制）。
- P2「横向滚动每次 `fittingSize`」→ N2。
- P3「过期清理频率过高」→ N3。
- P1「每次保存全量重写 + 扫描图片目录」→ N4（后台 + 原子写 + 降频清理）。
- P3「`try?` 吞错」→ 关键写盘失败加 `NSLog`。

## C. 需确认项（已获批准，均已实现）

- **Q1（内存，影响最大）→ ✅ 已实现**：内存只留缩略图（最长边 512px），原图完整留盘，粘贴时按需从磁盘加载原图。
- **Q2（图片指纹）→ ✅ 已实现**：图片指纹改为剪贴板原始字节的 SHA256（截断 16 字节十六进制）。旧图片文件名失配将作为孤儿被清理重建。
- **Q3（上限）→ ✅ 部分实现**：RTF >1MB 降级纯文本；收藏数量上限 100。文本"超大存摘要"未做（见说明）。

---

## D. 变更日志（已落地）

> 状态：以下均已实现，`swift build -c release --arch arm64` 通过。

1. **N1 + P2 搜索/选中重复过滤** — `ClipboardPanelView`
   - `clampedSelection` 由"每次读都全量 filter 的计算属性"改为 `clampedSelection(count:)` 函数。
   - `body` 开头一次性 `let items = filteredItems` / `let selection = ...`，向下透传，`ForEach` 内 `isSelected` 不再每张卡片重算 filter。
   - `timeline(items:)` 改为 `timeline(items:selection:)`。
   - `moveSelection/deleteSelected/selectCurrent` 各自只算一次 `filteredItems`。
   - 效果：一次 body（含每次 hover）从约 N+ 次全量过滤降到 1 次。

2. **N2 + P2 横向滚动布局测量** — `SmoothHorizontalScrollView`
   - 新增 `itemCount` 入参，按 `count*width + (count-1)*spacing + padding*2` 公式算内容宽。
   - `updateNSView` 不再调用 `hostingView.fittingSize`（不再强制整树布局测量）；仅在宽/高变化时改 frame。
   - 效果：hover/选中变化不再触发整条时间线的布局测量。

3. **N3 + P3 过期清理降频** — `ClipboardMonitor`
   - 0.7s 高频定时器只做 `pollPasteboard()`（changeCount 检测）。
   - 新增 60s 低频 `pruneTimer` 跑 `pruneExpired()`；启动时仍清理一次。

4. **N4 + P1 保存搬后台 + 原子写 + 降频清理** — `HistoryStore`（标 `@MainActor`）/ `ClipboardMonitor` / `AppDelegate`
   - 新增串行 `ioQueue`，JSON 编码 + 写盘 + 孤儿清理全部移到后台。
   - 主线程只做"准备快照 + 仅对新图片 PNG 转码一次"（NSImage 非线程安全，转码必须留主线程）。
   - 新增 `writtenImageFilenames` 内存缓存，避免每次保存在主线程 `fileExists` stat 磁盘。
   - 索引与图片均 `.atomic` 写，避免半写损坏。
   - 孤儿图片清理降频：每 12 次保存一次；清空历史时立即清理。
   - 写盘失败由静默 `try?` 改为 `NSLog`（P3）。
   - 退出路径：`flushNow()`（异步）+ 新增 `flushAndWait()`（`ioQueue.sync` 等待），`applicationWillTerminate` 用后者确保不丢数据。

5. **GlassEffectView / VisualEffectView updateNSView 加变更判等**
   - 仅在属性实际变化时赋值，避免每次 body 重算（hover）都重设 `tintColor` 等触发玻璃/材质层重绘。

6. **Q1 图片内存：内存只留缩略图，原图留盘** — 新增 `ImageThumbnail.swift` / `HistoryStore` / `ClipboardMonitor`
   - 新增 `NSImage.pasteletThumbnail(maxPixel:512)`（高质量降采样）。
   - 加载历史（`HistoryStore.makeItem`）与文件图片捕获（`makeFileItem`）只放缩略图，不再常驻全分辨率位图。
   - 粘贴时 `restore` 对图片项调用 `store.fullImage(for: fingerprint)` 从磁盘读原图，保真度不变（新复制项尚未落盘时回退到内存图）。
   - 文件→图片的尺寸 detail 改用保存时记录的原始尺寸，不用缩略图尺寸。
   - 链接预览图也降采样（最长边 160px，卡片只显示 56pt）。
   - 收益：历史含大图时的常驻内存从几百 MB 量级降到几 MB 量级。

7. **Q2 图片指纹改内容 hash** — `ClipboardMonitor` / `ImageThumbnail.swift`
   - `makeImageItem` 指纹 = `"image:" + SHA256(剪贴板原始字节).prefix(16)`，优先复用 `.png/.tiff` 原始数据，避免主线程额外 TIFF 转码。
   - 去重更准、消除"不同图同名碰撞导致预览错图"，文件名也由 hash 决定。

8. **Q3 大小/数量上限** — `ClipboardMonitor`
   - `maxRTFBytes = 1MB`：RTF 超限丢弃，降级为纯文本（纯文本仍可粘贴，仅丢格式）。
   - `maxFavorites = 100`：收藏达上限时拒绝新增并提示音，防止收藏豁免 `maxItems` 导致无界增长。
   - 文本"超大转摘要"未实现：会破坏"完整粘贴大段文本"的功能（如粘贴大文件内容会被截断），属功能回退，故保留完整文本。如需仍可加，请告知阈值。

9. **搜索框聚焦蓝环左侧被切（视觉）** — `ClipboardPanelView.searchControl`
   - 聚焦描边由 `.stroke`（描边跨边缘，外半部分在 frame 之外）改为 `.strokeBorder`（描边画在形状内侧）。
   - 原因：父容器 `toolbarCluster` 有 `.clipped()`，搜索框左边缘正好在裁剪边界，跨边缘的描边外半部分被切掉，看起来左侧圆角边框缺一块。`strokeBorder` 全部画在内侧即不会被裁。未改任何坐标，点击命中检测不受影响。

10. **搜索框打字掉帧** — `ClipboardPanelView`
   - 新增 `debouncedQuery`，过滤改用它；`.task(id: searchText)` 做 150ms 防抖（清空立即生效）。
   - 原因：原来每敲一个字符都立即重算过滤 + 重建整条卡片时间线（NSHostingView 重新布局），输入越快掉帧越明显。防抖后打字过程不触发卡片重建，停顿 150ms 后才过滤一次。

11. **面板弹出动画掉帧** — `ClipboardPanelController.makePanel`
   - 在内容 `hostingView.layer` 上设 `allowsGroupOpacity = false`。
   - 原因：入场动画对整层做 `opacity` 0→1 渐变，而内容层有子图层（玻璃+卡片+阴影，整层约 1400×330 retina）。开启组透明度时，每帧都要把整棵图层树离屏重合成一次再统一应用透明度——这是弹出掉帧的主因。关掉后透明度按各子图层独立应用，不再每帧离屏 flatten，滑入+淡入仍保留。

12. **搜索过滤后卡片错位（bug）** — `SmoothHorizontalScrollView` / `PasteletSmoothScrollView`
   - 现象：搜索框输入文字再退格删除后，卡片出现错位/残留。
   - 根因：文档视图尺寸原本在 `updateNSView` 里按 clip view 高度即时设置，但 `updateNSView` 只在 SwiftUI 状态变化时触发。空搜索结果会把时间线换成空状态视图，退格又换回时间线（重新 `makeNSView`），首个 `updateNSView` 可能在 clip view 尚无有效高度时跑，把内容定成错误尺寸且之后无更新自愈；另外列表过滤导致内容宽变化时，横向滚动偏移没被钳回有效范围。
   - 修法：尺寸改由 `PasteletSmoothScrollView.layout()` 统一处理——文档视图高度始终跟随可视区高度、宽度取内容宽与可视宽较大者，并在每次布局把横向偏移钳回 `[0, maxX]`。`updateNSView` 只负责赋 `rootView` 和设置 `contentWidth`（触发重新布局）。比改动前更健壮。

## E. 仍建议但本次未动（低优先或需确认）

- 卡片 `compositingGroup()` + 阴影：每卡一次离屏合成，36 卡在动画时是 GPU 成本。改动会影响视觉，建议先用 Instruments 量化再决定，故未动。
- `ClipboardCardView.relativeTime` 每次重绘取 `Date()`、`sourceAccent` 每次重算字符串：均为极小开销，未做缓存（避免引入静态缓存的并发复杂度）。
- hover 改 `selectedIndex` 仍会触发整个面板 body 重算：彻底消除需把"选中态"抽到独立 ObservableObject 仅由卡片观察，属较大重构，未动。
- `load()` 仍在启动时同步读盘（已不再整图解码，见 2026-05-30 的 R4）。

---

## F. 2026-05-30 复审与第二轮优化

复审基线：第一轮（A–E）已落地的版本。逐文件重读后未发现新的 P0；以下为本轮直接处理项，`swift build` + `./scripts/build-app.sh` 均通过，已覆盖部署 `/Applications` 并重启。

### 本轮新发现（第一轮文档未记）

| 编号 | 问题 | 严重度 | 处理 |
| --- | --- | --- | --- |
| R1 | **剪贴板直接复制图片**这条路第一轮 Q1 没覆盖到：`makeImageItem` 仍把全分辨率 `NSImage` 放进 `item.image`/`previewImage` 常驻内存、卡片也按全分辨率画；保存时 `pngData(item.image!)` 在主线程把整张大图重新编码 PNG。而此时手里已有剪贴板原始字节（只拿去算了 hash 就丢）。 | 高 | ✅ 已改（R-A） |
| R2 | `availableSources`/`availableKinds` 是计算属性，无条件传入 `toolbarCluster` → 每次 body（含每次 hover / 打字）都全量遍历 items 建 Set+数组+排序，而过滤弹窗大多没开。 | 中 | ✅ 已改（R-C） |
| R3 | 文本卡片 `highlightedSnippet` 在无搜索词时直接用**完整** rawText 构建 AttributedString，而 rawText 无长度上限（Q3 的"超大转摘要"未做），超大文本每次重绘都整段转换，卡片却只显示 7 行。 | 中 | ✅ 已改（R-D） |

### 变更日志（已落地）

- **R-A 复制图片：原始字节直写磁盘 + 内存只留缩略图** — `ClipboardMonitor` / `HistoryStore`
  - `ClipboardMonitor` 新增 `pendingImageData`（fingerprint→原始字节）暂存；`makeImageItem` 内存/卡片改放 `pasteletThumbnail()`，原始字节暂存待落盘。
  - 新增 `persist()` 统一落盘：`store.save(items, imageData:)` 在同步阶段取走所需字节后清空暂存；`flushNow`/`flushAndWait`/`saveSoon` 均改走 `persist()`。
  - `HistoryStore.save(_:imageData:)` 优先**直接写剪贴板原始字节**（免主线程把大图重新编码 PNG），无字节时才回退对缩略图编码。
  - `restore` 增加"未落盘窗口内用暂存原始字节还原全分辨率"兜底；原图完整留盘，粘贴保真度不变。
  - 收益：复制截图/大图时主线程不再重编码大图，且不再常驻全分辨率位图。

- **R-C 过滤选项懒求值** — `SearchToolbarClusterView` / `ClipboardPanelView`
  - `availableKinds`/`availableSources` 由值改为闭包 `() -> [...]`，只在过滤弹窗真正打开（弹层内 `SourceFilterMenu`）时才计算，不再每次 body 重建来源列表 + 排序。

- **R-D 大文本卡片展示截断** — `ClipboardCardView`
  - `highlightedSnippet` 无搜索分支只取前 ~600 字符再转 `AttributedString`；粘贴走 `rawText` 不受影响（纯展示侧截断）。

- **R4（即原 P2-E）历史加载改 ImageIO 直接降采样** — `ImageThumbnail` / `HistoryStore`
  - 新增 `NSImage.pasteletThumbnail(contentsOf:maxPixel:)`：用 `CGImageSourceCreateThumbnailAtIndex` 直接从磁盘 URL 解到缩略图尺寸，不再"整图解码进内存再缩"。
  - `HistoryStore.makeItem` 两处 `NSImage(contentsOf:)?.pasteletThumbnail()` 改用之。
  - R-A 之后磁盘存的是全分辨率原图，load 回来若整图解码内存/CPU 都贵；本项与 R-A 互补：磁盘留原图保真、load 只解缩略图。

### 本轮评估后仍未动（含原因）

- **选中态抽独立 ObservableObject（消除 hover 重建整条时间线）**：hover 跨卡会令 `selectedIndex` 进 `timelineSignature` → 重建 36 张卡片 body。但量级仅 36、SwiftUI diffing 下实际重绘只有 2 张、且 hover 高亮本地 `isHovered` 已生效，单次成本被稀释；属中等重构且易踩选中/键盘/滚动/删除落点联动 bug，ROI 偏低，暂不动。真有 hover 掉帧更可能是每卡 `compositingGroup()`+阴影的 GPU 离屏合成（P3），需 Instruments 量化后再定。
- **R4 的"load 异步回填"**：解码改 downsample-direct 后单次已很便宜，且启动期面板不可见，挪后台要引入 `var image` + Sendable 数据跨线程 + 按 fingerprint 回填 + 批量重发布，边际收益小、联动风险大，故只做同步 CGImageSource，未做异步。
- 链接预览仍无缓存/去重/并发限制/取消（第一轮 REVIEW P1，未做）。
- 每卡 `compositingGroup()`+阴影离屏合成；`relativeTime` 每帧取 `Date()`、`sourceAccent` 每帧拼字符串：均待 Instruments 量化后再定。
</content>
