import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'preload_controller.dart';

class PreloadManager<T> {
  late int _preloadBackward;
  late int _preloadForward;
  late int _windowSize;
  late final List<PreloadController> _preloadWindow = [];
  late int _end;
  int _prevIndex = 0;
  int _start = 0;
  int _activeIndex = -1; // 当前播放索引
  final bool _autoplayFirstVideo;
  bool _firstVideoPlayed = false;

  List<T> _data = [];
  bool _isPaginating = false;

  final int paginationThreshold;

  // Custom controller factory
  final PreloadController Function(T data) controllerFactory;

  // 状态管理
  bool _disposed = false;

  /// 控制器初始化完成时的回调
  final void Function(PreloadController controller)? onControllerInitialized;

  /// 播放状态变化时的回调
  final void Function()? onPlayStateChanged;

  /// 触达分页阈值时的回调（用于拉取更多数据）
  final Future<List<T>> Function()? onPaginationNeeded;

  PreloadManager({
    int? preloadBackward,
    int? preloadForward,
    int? windowSize,
    required List<T> data,
    required this.controllerFactory,
    this.onControllerInitialized,
    this.onPlayStateChanged,
    this.onPaginationNeeded,
    this.paginationThreshold = 5,
    bool autoplayFirstItem = false,
  }) : _autoplayFirstVideo = autoplayFirstItem {
    // 外部通过 dataList 访问
    _data = List.of(data);

    _preloadBackward = preloadBackward ?? 3;
    _preloadForward = preloadForward ?? 3;
    _windowSize = windowSize ?? 8;

    assert(
    _preloadBackward <= _windowSize,
    'preloadBackward must not exceed windowSize',
    );
    assert(
    _preloadForward <= _windowSize,
    'preloadForward must not exceed windowSize',
    );
    assert(
    _preloadBackward + _preloadForward < _windowSize,
    'Sum of preloadBackward and preloadForward must be less than windowSize',
    );

    // 检查 videoData 是否为空
    if (_data.isEmpty) {
      _start = 0;
      _end = 0;
      _log('No videos provided, initializing with empty window', emoji: '⚠️', color: 'yellow');
      return;
    }

    int initialLoadSize = _windowSize > _data.length ? _data.length : _windowSize;

    for (int i = 0; i < initialLoadSize; i++) {
      _preloadWindow.add(_initController(_data[i], i));
    }

    _start = 0;
    _end = _preloadWindow.length;

    _seeWhatsInsidePreloadWindow();
  }

  int _lastActivePaginationIndex = -1;

  PreloadController _initController(T data, int index) {
    final controller = controllerFactory(data);
    controller.initialize().then((_) {
      _log(
        'Controller initialized successfully for: $data',
        emoji: '✅',
        color: 'green',
      );
      if (_autoplayFirstVideo && index == 0 && !_firstVideoPlayed) {
        //add post frame callback to play the video
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _autoPlayCurrent(0);
          _firstVideoPlayed = true;
        });
      }
      // 修复异步竞态：检查当前索引是否仍然是活跃索引
      if (index == _activeIndex && !_disposed) {
        _autoPlayCurrent(index);
      }
      if (onControllerInitialized != null) {
        onControllerInitialized!(controller);
      }
    }).catchError((error) {
      _log(
        'Failed to initialize controller for: $data - Error: $error',
        emoji: '❌',
        color: 'red',
      );
    });
    return controller;
  }

  Future<void> _disposeController(PreloadController controller) async {
    try {
      await controller.pause();
      await controller.dispose();
      _log('Controller disposed successfully', emoji: '🗑️', color: 'yellow');
    } catch (e) {
      _log('Error disposing controller: $e', emoji: '⚠️', color: 'red');
    }
  }

  /// 检查是否需要分页并触发
  Future<void> _checkAndTriggerPagination(int currentIndex) async {
    if (_isPaginating || _disposed) return;  // 添加 _disposed 安全检查

    final remainingItems = _data.length - currentIndex - 1;

    if (remainingItems <= paginationThreshold && onPaginationNeeded != null) {
      _isPaginating = true;
      _log(
        'Pagination threshold reached! Remaining items: $remainingItems',
        emoji: '📄',
        color: 'magenta',
      );

      try {
        final newUrls = await onPaginationNeeded!();
        if (newUrls.isNotEmpty) {
          _data.addAll(newUrls);
          _log(
            'Added ${newUrls.length} new videos via pagination',
            emoji: '➕',
            color: 'green',
          );
        }
      } catch (e) {
        _log('Pagination failed: $e', emoji: '❌', color: 'red');
      } finally {
        _isPaginating = false;
      }
    }
  }

  Future<void> _onScrollForward(
      int index,
      ) async {
    if (_disposed) return; // 防止在已销毁状态下调用

    // 分页检查已在 scroll() 中处理
    if (_end >= _data.length) {
      _log(
        "Cannot scroll forward - reached end of videos",
        emoji: '🛑',
        color: 'yellow',
      );

      if (_lastActivePaginationIndex == -1) {
        _lastActivePaginationIndex = index - 1;
      }
      return;
    }

    var newController = _initController(_data[_end], _end);
    _preloadWindow.add(newController);

    if (_preloadWindow.length > _windowSize) {
      await _disposeController(_preloadWindow.removeAt(0));
    }

    _start++;
    _end++;
    _log(
      'Scrolled forward - Window: $_start to $_end',
      emoji: '⏩',
      color: 'cyan',
    );
    _seeWhatsInsidePreloadWindow();
  }

  Future<void> _onScrollBackward(int index) async {
    if (_disposed) return; // 防止在已销毁状态下调用

    if (_start <= 0) {
      _log(
        "Cannot scroll backward - reached beginning",
        emoji: '🛑',
        color: 'yellow',
      );
      return;
    }

    if (_lastActivePaginationIndex != -1 && _lastActivePaginationIndex < index) {
      _log(
        "Index not active yet for backward scroll",
        emoji: '⏸️',
        color: 'yellow',
      );
      return;
    }

    _lastActivePaginationIndex = -1;

    int newStart = _start - 1;
    if (newStart >= 0 && newStart < _data.length) {
      var newController = _initController(_data[newStart], newStart);
      _preloadWindow.insert(0, newController);

      if (_preloadWindow.length > _windowSize) {
        await _disposeController(_preloadWindow.removeLast());
      }

      _start = newStart;
      _end--;
      _log(
        'Scrolled backward - Window: $_start to $_end',
        emoji: '⏪',
        color: 'cyan',
      );
    }

    _seeWhatsInsidePreloadWindow();
  }

  /// 暂停除指定索引外的所有视频
  void _pauseAllExcept(int currentIndex) {
    if (_disposed) return; // 防止在已销毁状态下调用

    int pausedCount = 0;
    for (int i = 0; i < _preloadWindow.length; i++) {
      int globalIndex = _start + i;
      if (globalIndex != currentIndex && _preloadWindow[i].isPlaying) {
        _preloadWindow[i].pause();
        pausedCount++;
      }
    }

    if (pausedCount > 0) {
      _log(
        'Paused $pausedCount video(s) except index: $currentIndex',
        emoji: '⏸️',
        color: 'yellow',
      );
    }

    // Notify UI of play state change
    if (onPlayStateChanged != null) {
      onPlayStateChanged!();
    }
  }

  /// 自动播放当前索引的视频（带重试机制）
  void _autoPlayCurrent(int currentIndex) {
    if (_disposed) return; // 防止在已销毁状态下调用

    _activeIndex = currentIndex;
    final controller = getControllerAtIndex(currentIndex);
    if (controller != null) {
      if (controller.isInitialized && !controller.isPlaying) {
        controller.play();
        _log(
          'Auto-playing video at index: $currentIndex',
          emoji: '▶️',
          color: 'green',
        );
        // Notify UI of play state change
        if (onPlayStateChanged != null) {
          onPlayStateChanged!();
        }
      } else if (!controller.isInitialized) {
        // If not initialized yet, wait and try again
        _log(
          'Waiting for video initialization at index: $currentIndex',
          emoji: '⏳',
          color: 'yellow',
        );
      }
    }
  }

  Future<void> scroll(int index) async {
    if (_disposed) return; // 防止在已销毁状态下调用

    _log(
      'Scrolling to index: $index (previous: $_prevIndex)',
      emoji: '🔄',
      color: 'blue',
    );

    // Pause all videos except the current one
    _pauseAllExcept(index);

    if (index == _prevIndex) return;

    final int pivot = _start + _preloadBackward;

    if (index > pivot) {
      // Check for pagination before scrolling forward
      await _checkAndTriggerPagination(index);
      // Adjust window by scrolling forward
      while (index > _start + _preloadBackward && _end < _data.length) {
        await _onScrollForward(index);
      }
    } else if (index < pivot) {
      // Adjust window by scrolling backward
      while (index < _start + _preloadBackward && _start > 0) {
        await _onScrollBackward(index);
      }
    }

    _prevIndex = index;

    // Auto-play the current video with a small delay to ensure initialization
    _autoPlayCurrent(index);
  }

  /// 获取所有激活的控制器（调试/外部访问）
  List<PreloadController> getActiveControllers() => _preloadWindow;

  /// 释放所有控制器
  Future<void> disposeAll() async {
    if (_disposed) return; // 防止重复调用

    _disposed = true;
    _log('Disposing all controllers...', emoji: '🧹', color: 'red');
    for (var controller in _preloadWindow) {
      await _disposeController(controller);
    }
    _preloadWindow.clear();
    _log('All controllers disposed', emoji: '✅', color: 'green');
  }

  /// 安全获取：若索引越界返回 null
  PreloadController? getControllerAtIndex(int index) {
    int relative = index - _start;
    if (relative >= 0 && relative < _preloadWindow.length) {
      return _preloadWindow[relative];
    } else {
      _log(
        "Index $index is out of preload range ($_start - $_end)",
        emoji: '⚠️',
        color: 'yellow',
      );
      return null;
    }
  }

  /// 获取窗口起始索引
  int getStart() => _start;

  /// 获取当前播放索引
  int getActiveIndex() => _activeIndex;

  /// 强制自动播放指定索引（初始化时使用）
  void forceAutoPlay(int index) {
    if (_disposed) return; // 防止在已销毁状态下调用

    _log('Force auto-playing index: $index', emoji: '🎬', color: 'magenta');
    _autoPlayCurrent(index);
  }

  /// 切换指定控制器的播放/暂停
  void togglePlayPause(PreloadController controller) {
    if (_disposed) return; // 防止在已销毁状态下调用

    if (controller.isPlaying) {
      if (!_disposed) controller.pause();
      _log('Video paused', emoji: '⏸️', color: 'yellow');
    } else {
      // Pause all other videos first
      for (var ctrl in _preloadWindow) {
        if (ctrl != controller && ctrl.isPlaying && !_disposed) {
          ctrl.pause();
        }
      }
      if (!_disposed) controller.play();
      _log('Video resumed', emoji: '▶️', color: 'green');
    }
    // Notify UI of play state change
    if (onPlayStateChanged != null) {
      onPlayStateChanged!();
    }
  }

  // ========== 数据访问 API ==========

  /// 获取数据列表（可直接修改，PreloadManager 拥有此列表）
  List<T> get dataList => _data;

  /// 获取视频总数
  int get length => _data.length;

  /// 检查列表是否为空
  bool get isEmpty => _data.isEmpty;

  /// 删除指定索引的视频
  /// [index] 要删除的视频索引
  /// 返回是否删除成功
  Future<bool> removeData(int index) async {
    if (_disposed) return false;

    if (index < 0 || index >= _data.length) {
      _log('Invalid remove parameter: index=$index', emoji: '❌', color: 'red');
      return false;
    }

    _log('Removing video at index $index', emoji: '🗑️', color: 'red');

    // 删除视频URL
    _data.removeAt(index);

    // 处理预加载窗口的调整
    await _adjustPreloadWindowAfterRemove(index, 1);

    // 调整当前播放索引
    _adjustActiveIndexAfterRemove(index, 1);

    _log('Successfully removed video at index $index', emoji: '✅', color: 'green');
    return true;
  }

  /// 在列表末尾追加视频数据
  /// 返回实际追加的数量
  Future<int> addData(List<T> data) async {
    if (_disposed) return 0;
    if (data.isEmpty) return 0;

    _data.addAll(data);
    _log('Manually added ${data.length} video(s) to the end', emoji: '➕', color: 'green');

    // 追加后尽量把预加载窗口补满
    await _fillWindowAfterAppend();
    return data.length;
  }

  /// 重新设置数据源，并在 [initialIndex] 附近重建预加载窗口
  Future<void> setDataSource(List<T> data, {int initialIndex = 0, bool autoPlay = true}) async {
    if (_disposed) return;

    _log('🔄 setDataSource called - old data.length: ${_data.length}, new data.length: ${data.length}', emoji: '🔄', color: 'magenta');

    // 清理旧窗口
    for (var controller in _preloadWindow) {
      await _disposeController(controller);
    }
    _preloadWindow.clear();

    // 重置内部状态
    _data = List.of(data);  // 创建副本，PreloadManager 完全拥有数据
    _isPaginating = false;
    _firstVideoPlayed = false;
    _activeIndex = -1;
    _prevIndex = 0;
    _lastActivePaginationIndex = -1;

    if (_data.isEmpty) {
      _start = 0;
      _end = 0;
      _log('Set empty data source; window cleared', emoji: '🧹', color: 'yellow');
      return;
    }

    // 规范化初始索引
    int targetIndex = initialIndex;
    if (targetIndex < 0) targetIndex = 0;
    if (targetIndex >= _data.length) targetIndex = _data.length - 1;

    // 计算新的窗口范围
    // 窗口应该包含 windowSize 个元素，以 targetIndex 为中心
    // 但要确保窗口不超出数据范围
    final startIdx = (targetIndex - _preloadBackward).clamp(0, _data.length);
    final endIdx = (startIdx + _windowSize).clamp(0, _data.length);

    _start = startIdx;
    _end = endIdx;

    _log('📊 Creating controllers - start: $_start, end: $_end, targetIndex: $targetIndex, windowSize: $_windowSize', emoji: '📊', color: 'blue');

    // 初始化窗口内控制器
    for (int i = startIdx; i < endIdx; i++) {
      _log('  Creating controller for index $i, dataId: ${_data[i]}', emoji: '  🎬', color: 'cyan');
      _preloadWindow.add(_initController(_data[i], i));
    }

    _seeWhatsInsidePreloadWindow();

    // 自动播放初始索引（可配置）
    if (autoPlay) {
      _autoPlayCurrent(targetIndex);
    }
  }

  /// 追加数据后，尽量将窗口补齐到设定大小
  Future<void> _fillWindowAfterAppend() async {
    if (_disposed) return;

    final desiredEnd = (_start + _windowSize).clamp(0, _data.length);
    while (_end < desiredEnd && _end < _data.length) {
      _preloadWindow.add(_initController(_data[_end], _end));
      _end++;
    }
    _seeWhatsInsidePreloadWindow();
  }

  /// 在指定位置插入视频
  /// [index] 插入位置索引
  /// [videoData] 要插入的视频数据列表
  /// 返回是否插入成功
  Future<bool> insertData(int index, List<T> data) async {
    if (_disposed) return false;

    if (index < 0 || index > _data.length || data.isEmpty) {
      _log('Invalid insert parameters: index=$index, data=${data.length}', emoji: '❌', color: 'red');
      return false;
    }

    _log('Inserting ${data.length} video(s) at index $index', emoji: '➕', color: 'green');

    // 插入视频数据
    _data.insertAll(index, data);

    // 处理预加载窗口的调整
    await _adjustPreloadWindowAfterInsert(index, data.length);

    // 调整当前播放索引
    _adjustActiveIndexAfterInsert(index, data.length);

    _log('Successfully inserted ${data.length} video(s)', emoji: '✅', color: 'green');
    return true;
  }

  /// 调整预加载窗口（删除后）
  Future<void> _adjustPreloadWindowAfterRemove(int removedIndex, int removedCount) async {
    // 如果删除的范围在预加载窗口之外，只需要调整索引
    if (removedIndex >= _end) {
      // 删除范围在窗口之后，只需要调整结束索引
      _end = (_end - removedCount).clamp(0, _data.length);
      return;
    }

    if (removedIndex + removedCount <= _start) {
      // 删除范围在窗口之前，需要调整开始和结束索引
      _start = (_start - removedCount).clamp(0, _data.length);
      _end = (_end - removedCount).clamp(0, _data.length);
      return;
    }

    // 删除范围与预加载窗口重叠，需要重新构建窗口
    await _rebuildPreloadWindow();
  }

  /// 调整预加载窗口（插入后）
  Future<void> _adjustPreloadWindowAfterInsert(int insertIndex, int insertCount) async {
    // 如果插入位置在预加载窗口之后，只需要调整索引
    if (insertIndex >= _end) {
      _end = (_end + insertCount).clamp(0, _data.length);
      return;
    }

    if (insertIndex <= _start) {
      // 插入位置在窗口之前，需要调整索引
      _start = (_start + insertCount).clamp(0, _data.length);
      _end = (_end + insertCount).clamp(0, _data.length);
      return;
    }

    // 插入位置在窗口内部，需要重新构建窗口
    await _rebuildPreloadWindow();
  }

  /// 重新构建预加载窗口
  Future<void> _rebuildPreloadWindow() async {
    _log('Rebuilding preload window due to structural changes', emoji: '🔨', color: 'yellow');

    // 清理现有控制器
    for (var controller in _preloadWindow) {
      await _disposeController(controller);
    }
    _preloadWindow.clear();

    // 重新计算窗口范围
    final currentIndex = _activeIndex >= 0 ? _activeIndex : 0;
    // 使用正确的窗口计算公式（与 setDataSource 一致）
    final startIdx = (currentIndex - _preloadBackward).clamp(0, _data.length);
    final endIdx = (startIdx + _windowSize).clamp(0, _data.length);

    _start = startIdx;
    _end = endIdx;

    // 重新初始化控制器
    for (int i = startIdx; i < endIdx; i++) {
      if (i < _data.length) {
        _preloadWindow.add(_initController(_data[i], i));
      }
    }

    _log('Preload window rebuilt: $_start to $_end', emoji: '✅', color: 'green');
  }

  /// 调整当前播放索引（删除后）
  void _adjustActiveIndexAfterRemove(int removedIndex, int removedCount) {
    if (_activeIndex < 0) return;

    if (_activeIndex < removedIndex) {
      // 当前播放的视频在删除范围之前，无需调整
      return;
    }

    if (_activeIndex < removedIndex + removedCount) {
      // 当前播放的视频被删除了，需要选择新的播放位置
      if (removedIndex > 0) {
        _activeIndex = removedIndex - 1; // 播放前一个视频
      } else if (_data.isNotEmpty) {
        _activeIndex = 0; // 播放第一个视频
      } else {
        _activeIndex = -1; // 没有视频了
      }
      _log('Active index adjusted to $_activeIndex after removal', emoji: '🔄', color: 'yellow');
    } else {
      // 当前播放的视频在删除范围之后，需要调整索引
      _activeIndex = (_activeIndex - removedCount).clamp(0, _data.length - 1);
      _log('Active index adjusted to $_activeIndex after removal', emoji: '🔄', color: 'yellow');
    }
  }

  /// 调整当前播放索引（插入后）
  void _adjustActiveIndexAfterInsert(int insertIndex, int insertCount) {
    if (_activeIndex < 0) return;

    if (_activeIndex < insertIndex) {
      // 当前播放的视频在插入位置之前，无需调整
      return;
    }

    // 当前播放的视频在插入位置之后，需要调整索引
    _activeIndex = (_activeIndex + insertCount).clamp(0, _data.length - 1);
    _log('Active index adjusted to $_activeIndex after insertion', emoji: '🔄', color: 'yellow');
  }

  /// 获取视频列表的当前状态
  Map<String, dynamic> getDataListStatus() {
    return {
      'totalVideos': _data.length,
      'preloadWindowStart': _start,
      'preloadWindowEnd': _end,
      'activeIndex': _activeIndex,
      'previousIndex': _prevIndex,
      'windowSize': _preloadWindow.length,
      'isPaginating': _isPaginating,
      'disposed': _disposed,
    };
  }

  void _seeWhatsInsidePreloadWindow() {
    _log(
      "Preload Window | Start: $_start | End: $_end | Total Videos: ${_data.length}",
      emoji: '🔍',
      color: 'blue',
    );
  }

  /// 彩色日志（带表情符号）
  void _log(String message, {String emoji = '📱', String color = 'blue'}) {
    if (kDebugMode) {
      // ANSI color codes for terminal output
      const colors = {
        'red': '\x1B[31m',
        'green': '\x1B[32m',
        'yellow': '\x1B[33m',
        'blue': '\x1B[34m',
        'magenta': '\x1B[35m',
        'cyan': '\x1B[36m',
        'white': '\x1B[37m',
        'reset': '\x1B[0m',
      };

      final colorCode = colors[color] ?? colors['blue'];
      final resetCode = colors['reset'];

      print('$colorCode$emoji $message$resetCode');
    }
  }
}
