## 简介

`preload` 是一个用于短视频流的预加载管理器，支持上下滑动窗口预加载、分页加载、图文+视频混排、可插拔的视频控制器接口，帮助你在 Flutter 中快速搭建抖音/快手式的短视频浏览体验。

## 适用场景

- 短视频上下滑切，前后若干个视频的“滑动窗口”预加载
- 长列表靠近尾部自动/手动分页加载
- 图文 + 视频混排（对图文使用空控制器即可）

## 特性

- 窗口预加载：仅维护“当前 + 前后若干”的控制器，节省内存并保证流畅
- 分页触发：靠近尾部自动触发，也支持手动 `addVideos` 追加
- 生命周期安全：统一销毁、销毁后防误用、边界检查
- 可插拔控制器：由你提供 `PreloadController` 的实现（不限播放器 SDK）

## 安装

本仓库未发布至 pub，示例通过本地依赖方式：

```yaml
dependencies:
  preload:
    path: ../
```

## 快速开始

### 定义数据与控制器

```dart
import 'package:preload/preload.dart';

class VideoData {
  final String id;
  final String url;
  final String cover;
  VideoData(this.id, this.url, this.cover);
}

// 播放器控制器示例：实现 PreloadController（可对接任意播放器 SDK）
class MyVideoController implements PreloadController {
  final VideoData data;
  bool _inited = false;
  bool _playing = false;

  MyVideoController(this.data);

  @override
  Future<void> initialize() async { /* 初始化播放器 */ _inited = true; }

  @override
  Future<void> play() async { if (_inited) _playing = true; }

  @override
  Future<void> pause() async { _playing = false; }

  @override
  Future<void> dispose() async { _inited = false; _playing = false; }

  @override
  bool get isInitialized => _inited;

  @override
  bool get isPlaying => _playing;

  @override
  String get dataSource => data.url;
}
```

### 创建管理器并绑定 UI

```dart
final manager = PreloadManager<VideoData>(
  videoData: initialList,
  controllerFactory: (d) => MyVideoController(d),
  preloadBackward: 2,
  preloadForward: 2,
  windowSize: 5,
  paginationThreshold: 5,
  autoplayFirstVideo: true,
  onPlayStateChanged: () { setState(() {}); },
  onPaginationNeeded: () async {
    // 拉取更多（建议：页面侧也 setState 同步自己的列表）
    final more = await api.fetchNextPage();
    return more;
  },
);

// PageView 滚动时通知
onPageChanged: (index) => manager.scroll(index);

// 渲染视频卡片时获取控制器（可能为 null）
final ctrl = manager.getControllerAtIndex(index);
```

## 运行时 API（常用）

- 滚动与控制器
  - `Future<void> scroll(int index)`：通知滑动到索引
  - `PreloadController? getControllerAtIndex(int index)`：取窗口内控制器
  - `PreloadController? getCurrentController()`：取窗口中部控制器
  - `void togglePlayPause(PreloadController controller)`：切换播放/暂停

- 分页与数据源
  - `Future<int> addVideos(List<T> videos)`：末尾手动追加，自动尝试补满窗口
  - `Future<void> setDataSource(List<T> videoData, {int initialIndex = 0, bool autoPlay = true})`
    - 重置数据源并在 `initialIndex` 附近重建窗口
    - `autoPlay` 控制是否自动播放初始索引（默认 true）

- 列表修改
  - `Future<bool> removeVideo(int index)`：删除单个
  - `Future<bool> insertVideos(int index, List<T> videos)`：在指定位置插入

- 其他
  - `int getActiveIndex()`：当前播放索引
  - `int getTotalVideoCount()`：总条数
  - `Future<void> disposeAll()`：释放全部控制器

## 图文 + 视频混排

- 工厂函数对“非视频项”返回一个 No-op 控制器（实现 `PreloadController`，但 `play/pause` 为空实现，`isInitialized=true`）
- UI 按类型渲染图文/视频卡片
- 若当前是图文项：
  - 方案 A：页面侧在 `onPageChanged` 中跳到最近的视频索引再 `scroll`
  - 方案 B：修改 `_autoPlayCurrent`，遇到不可播控制器直接跳过

## 设计要点

- 防御性拷贝：内部使用 `List.of(videoData)` 隔离外部列表且保证可变
- 生命周期安全：所有对外 API 都有 `_disposed` 防护
- 窗口策略：仅维护有限窗口内控制器，滑动时淘汰/创建，防止一次性创建过多播放器

## 常见问题

- UI 没刷新：分页回调里建议页面侧先 `setState(() => list.addAll(more))`，并 `return more` 给管理器
- 触发分页过早/过晚：调小/调大 `paginationThreshold`，或改用 `addVideos` 手动触发
- 更换播放器 SDK：不支持运行期热切换，需 `disposeAll` 后用新工厂重建 `PreloadManager`

## 释放

组件销毁（页面退出）务必调用：

```dart
await manager.disposeAll();
```

## 版本建议

- Flutter 3.10+ / Dart 3+
- 若集成第三方播放器（如腾讯云），请遵循其 License/NDK 等平台要求


