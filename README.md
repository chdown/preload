## 简介

`preload` 是一个专为 Flutter 短视频场景设计的智能预加载框架。它采用滑动窗口机制，支持自动预加载、内存管理、分页加载以及灵活的播放器控制，帮助开发者快速构建高性能的类 TikTok/Reels 短视频应用。

## 核心特性

- **滑动窗口预加载**：智能维护“当前 + 前后若干”个视频控制器的生命周期，平衡流畅度与内存占用。
- **自动分页加载**：支持滚动到底部自动触发加载更多数据。
- **生命周期管理**：自动处理播放器的初始化、播放、暂停和销毁，防止内存泄漏。
- **应用级生命周期支持**：提供 `pauseAll` 和 `resumeCurrent` 方法，轻松应对应用切后台/前台场景。
- **灵活的数据操作**：支持动态插入、删除、追加数据，并自动调整预加载窗口。
- **可插拔控制器**：通过 `PreloadController` 抽象层，可适配任意视频播放器 SDK（如 video_player, fijkplayer 等）。

## 快速开始

### 1. 定义数据模型

```dart
class VideoData {
  final String id;
  final String url;
  final String cover;
  
  VideoData(this.id, this.url, this.cover);
}
```

### 2. 实现控制器接口

你需要实现 `PreloadController` 抽象类，对接你选择的播放器 SDK。

```dart
import 'package:preload/preload.dart';

class MyVideoController extends PreloadController {
  final String url;
  // 假设使用某个播放器实例
  // final VideoPlayerController _videoPlayer; 

  MyVideoController(this.url);

  @override
  Future<void> initialize() async {
    // 初始化播放器逻辑
    // await _videoPlayer.initialize();
  }

  @override
  Future<void> play() async {
    // await _videoPlayer.play();
  }

  @override
  Future<void> pause() async {
    // await _videoPlayer.pause();
  }

  @override
  Future<void> dispose() async {
    // await _videoPlayer.dispose();
  }

  @override
  bool get isPlaying => false; // 返回实际播放状态

  @override
  bool get isInitialized => true; // 返回实际初始化状态

  @override
  String get dataSource => url;
}
```

### 3. 初始化管理器

> 建议数据源使用PreloadManager统一管理

在你的页面 State 中创建并初始化 `PreloadManager`。

```dart
class _MyPageState extends State<MyPage> {
  late PreloadManager<VideoData> _manager;

  @override
  void initState() {
    super.initState();
    _manager = PreloadManager<VideoData>(
      data: initialVideoList,
      // 预加载配置
      preloadBackward: 2, // 向前预加载数量
      preloadForward: 3,  // 向后预加载数量
      windowSize: 6,      // 窗口总大小
      paginationThreshold: 3, // 触发加载更多的阈值
      autoplayFirstItem: true, // 是否自动播放第一个视频
      
      // 控制器工厂方法
      controllerFactory: (data) => MyVideoController(data.url),
      
      // 状态回调
      onPlayStateChanged: () {
        if (mounted) setState(() {});
      },
      onPaginationNeeded: () async {
        // 加载更多数据
        final newVideos = await fetchMoreVideos();
        return newVideos;
      },
    );
  }

  @override
  void dispose() {
    _manager.disposeAll(); // 务必销毁管理器
    super.dispose();
  }
}
```

### 4. 绑定 PageView

在 `PageView` 的 `onPageChanged` 中调用管理器的 `scroll` 方法。

```dart
PageView.builder(
  scrollDirection: Axis.vertical,
  itemCount: _manager.length,
  onPageChanged: (index) {
    _manager.scroll(index);
  },
  itemBuilder: (context, index) {
    // 获取当前索引的控制器（可能为空，如果不在预加载窗口内）
    final controller = _manager.getControllerAtIndex(index);
    final data = _manager.dataList[index];

    return VideoItemWidget(
      data: data,
      controller: controller,
    );
  },
)
```

## API 参考

### PreloadManager

#### 构造函数参数
- `data`: 初始数据列表。
- `controllerFactory`: 根据数据创建控制器的工厂函数。
- `preloadBackward`: 当前索引向前预加载的个数（默认 3）。
- `preloadForward`: 当前索引向后预加载的个数（默认 3）。
- `windowSize`: 保持活跃的控制器最大数量（默认 8）。
- `paginationThreshold`: 剩余多少个视频时触发加载更多（默认 5）。
- `autoplayFirstItem`: 是否自动播放列表第一个视频（默认 false）。

#### 核心方法
- `Future<void> scroll(int index)`: 核心驱动方法，当页面滚动时调用。处理窗口移动、自动播放和分页触发。
- `PreloadController? getControllerAtIndex(int index)`: 获取指定索引的控制器。如果该索引不在预加载窗口内，返回 null。
- `void pauseAll()`: 暂停所有视频（通常在 App 切后台时调用）。
- `void resumeCurrent()`: 恢复当前视频播放（通常在 App 切回前台时调用）。
- `Future<void> disposeAll()`: 销毁所有控制器并释放资源。

#### 数据操作
- `Future<int> addData(List<T> data)`: 在列表末尾追加数据。
- `Future<bool> removeData(int index)`: 删除指定索引的数据，并自动调整窗口。
- `Future<bool> insertData(int index, List<T> data)`: 在指定位置插入数据。
- `Future<void> setDataSource(List<T> data, {int initialIndex = 0, bool autoPlay = true})`: 重置整个数据源。

#### 状态查询
- `int getActiveIndex()`: 获取当前正在播放的索引。
- `List<T> get dataList`: 获取当前的数据列表。
- `int get length`: 获取数据总数。

### PreloadController

自定义控制器需实现以下方法：
- `initialize()`: 初始化播放器资源。
- `play()`: 开始播放。
- `pause()`: 暂停播放。
- `dispose()`: 释放资源。
- `togglePlayPause()`: 切换播放/暂停（基类已实现默认逻辑）。

## 最佳实践

1. **生命周期响应**：
   在 `WidgetsBindingObserver` 中监听 App 生命周期，调用 `manager.pauseAll()` 和 `manager.resumeCurrent()`。

   ```dart
   @override
   void didChangeAppLifecycleState(AppLifecycleState state) {
     if (state == AppLifecycleState.paused) {
       _manager.pauseAll();
     } else if (state == AppLifecycleState.resumed) {
       _manager.resumeCurrent();
     }
   }
   ```

2. **内存优化**：
   根据目标设备的性能调整 `windowSize`。较大的窗口能提供更流畅的滑动体验，但会消耗更多内存。

3. **混合布局**：
   如果列表中包含非视频项（如广告、图片），可以在 `controllerFactory` 中返回一个空的控制器实现（No-op Controller），或者在 UI 层根据数据类型决定是否请求控制器。
