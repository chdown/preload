import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'preload_controller.dart';

class PreloadManager<T> {
  // 核心数据
  List<T> _data = [];
  final List<PreloadController> _controllers = [];

  // 核心状态（简化）
  int _activeIndex = -1; // 当前活跃索引
  int _centerIndex = 0; // 窗口中心索引
  int _prevIndex = 0; // 上一个索引

  // 配置参数（使用 this.xxx 初始化）
  final int preloadBackward;
  final int preloadForward;
  final int paginationThreshold;

  // 控制标志
  bool _isPaginating = false;
  final bool autoplayFirstItem;
  bool _firstItemPlayed = false;
  bool _disposed = false;
  bool _isRebuilding = false; // 新增：防止并发重建

  // 回调函数
  final PreloadController Function(T data) controllerFactory;
  final void Function(PreloadController controller)? onControllerInitialized;
  final void Function()? onPlayStateChanged;
  final Future<void> Function()? onPaginationNeeded;

  PreloadManager({
    this.preloadBackward = 3,
    this.preloadForward = 3,
    this.paginationThreshold = 5,
    required List<T> data,
    required this.controllerFactory,
    this.onControllerInitialized,
    this.onPlayStateChanged,
    this.onPaginationNeeded,
    this.autoplayFirstItem = false,
  }) {
    _data = List.of(data);

    // 验证参数
    assert(preloadBackward >= 0, 'preloadBackward must be non-negative');
    assert(preloadForward >= 0, 'preloadForward must be non-negative');
    assert(paginationThreshold >= 0, 'paginationThreshold must be non-negative');

    // 初始化窗口（异步，但不等待）
    if (_data.isNotEmpty) {
      // 使用 Future.microtask 确保在构造函数完成后执行
      Future.microtask(() {
        _rebuildPreloadWindow(0).catchError((error) {
          _log('Failed to initialize preload window: $error', emoji: '❌', color: 'red');
        });
      });
    }
  }

  /// 核心方法：重建预加载窗口
  /// 这是统一窗口管理的核心，所有操作都通过这个方法
  Future<void> _rebuildPreloadWindow(int centerIndex) async {
    if (_disposed) return;

    // 添加重建互斥锁，防止并发重建
    if (_isRebuilding) {
      _log('Window rebuild already in progress, skipping...', emoji: '⏳', color: 'yellow');
      return;
    }
    _isRebuilding = true;

    try {
      _log('Rebuilding window around center: $centerIndex', emoji: '🔨', color: 'blue');

      // 数据为空或索引无效检查
      if (_data.isEmpty || centerIndex < 0 || centerIndex >= _data.length) {
        _log('No data available or invalid center index: $centerIndex (data length: ${_data.length})', emoji: '🧹', color: 'yellow');
        return;
      }

      // 计算窗口范围
      int start = (centerIndex - preloadBackward).clamp(0, _data.length - 1);
      int end = (centerIndex + preloadForward + 1).clamp(0, _data.length);

      // 创建新的控制器列表（不立即销毁旧的）
      final newControllers = <PreloadController>[];

      // 创建新控制器
      for (int i = start; i < end; i++) {
        newControllers.add(_createController(_data[i], i));
      }

      // 等待所有新控制器初始化完成
      await Future.wait(newControllers.map((controller) => controller.initialize()));

      // 现在安全地销毁旧控制器
      for (var controller in _controllers) {
        await _disposeController(controller);
      }

      // 更新控制器列表
      _controllers.clear();
      _controllers.addAll(newControllers);
      _centerIndex = centerIndex;

      _log('Window rebuilt: ${_controllers.length} controllers from index $start to ${end - 1}', emoji: '✅', color: 'green');

      // 处理控制器初始化完成的回调
      for (int i = 0; i < newControllers.length; i++) {
        final controller = newControllers[i];
        final globalIndex = start + i;

        if (onControllerInitialized != null) {
          onControllerInitialized!(controller);
        }

        // 处理自动播放逻辑
        if (autoplayFirstItem && globalIndex == 0 && !_firstItemPlayed) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_disposed && globalIndex == _activeIndex) {
              _autoPlayCurrent(0);
              _firstItemPlayed = true;
            }
          });
        }

        // 如果这是当前活跃索引，自动播放
        if (globalIndex == _activeIndex && !_disposed) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_disposed && globalIndex == _activeIndex) {
              _autoPlayCurrent(globalIndex);
            }
          });
        }
      }
    } finally {
      _isRebuilding = false;
    }
  }

  PreloadController _createController(T data, int index) {
    final controller = controllerFactory(data);

    // 不在这里调用initialize，让_rebuildPreloadWindow统一管理
    // 这样可以确保所有控制器都准备好后再销毁旧的

    return controller;
  }

  Future<void> _disposeController(PreloadController controller) async {
    try {
      // 先暂停，再释放（安全地处理可能未初始化的控制器）
      try {
        if (controller.isInitialized && controller.isPlaying) {
          await controller.pause();
        }
      } catch (e) {
        // 暂停失败不影响释放
        _log('Error pausing controller before dispose: $e', emoji: '⚠️', color: 'yellow');
      }

      // 等待一小段时间，确保Surface完全释放
      await Future.delayed(const Duration(milliseconds: 50));

      await controller.dispose();

      // 再等待一小段时间，确保资源完全清理
      await Future.delayed(const Duration(milliseconds: 50));
    } catch (e) {
      _log('Error disposing controller: $e', emoji: '❌', color: 'red');
      // 即使出错也要继续，防止阻塞其他清理操作
    }
  }

  /// 检查并触发分页
  Future<void> _triggerPaginationIfNeeded(int currentIndex) async {
    if (_isPaginating) return;

    final remainingItems = _data.length - currentIndex - 1;

    if (remainingItems <= paginationThreshold && onPaginationNeeded != null) {
      _isPaginating = true;
      _log(
        'Pagination threshold reached! Remaining items: $remainingItems',
        emoji: '📄',
        color: 'magenta',
      );

      try {
        await onPaginationNeeded!();
        _log(
          'Added new items via pagination',
          emoji: '➕',
          color: 'green',
        );
      } catch (e) {
        _log('Pagination failed: $e', emoji: '❌', color: 'red');
      } finally {
        _isPaginating = false;
      }
    }
  }

  /// 暂停除指定索引外的所有项目
  void _pauseOtherItems(int currentIndex) {
    int pausedCount = 0;
    // 计算窗口实际起始位置
    int windowStart = (_centerIndex - preloadBackward).clamp(0, _data.length - 1);

    for (int i = 0; i < _controllers.length; i++) {
      int globalIndex = windowStart + i;
      if (globalIndex != currentIndex && _controllers[i].isPlaying) {
        _controllers[i].pause();
        pausedCount++;
      }
    }

    if (pausedCount > 0) {
      _log(
        'Paused $pausedCount item(s) except index: $currentIndex',
        emoji: '⏸️',
        color: 'yellow',
      );
    }

    // Notify UI of play state change
    if (onPlayStateChanged != null) {
      onPlayStateChanged!();
    }
  }

  /// 自动播放当前索引的项目（带重试机制）
  void _autoPlayCurrent(int currentIndex) {
    if (_disposed) return; // 防止在已销毁状态下调用

    _activeIndex = currentIndex;
    final controller = getControllerAtIndex(currentIndex);
    if (controller != null) {
      if (controller.isInitialized && !controller.isPlaying) {
        try {
          controller.play();
          _log(
            'Auto-playing item at index: $currentIndex',
            emoji: '▶️',
            color: 'green',
          );
          // Notify UI of play state change
          if (onPlayStateChanged != null) {
            onPlayStateChanged!();
          }
        } catch (e) {
          _log('Error playing controller at index $currentIndex: $e', emoji: '❌', color: 'red');
        }
      } else if (!controller.isInitialized) {
        // If not initialized yet, wait and try again
        _log(
          'Waiting for item initialization at index: $currentIndex',
          emoji: '⏳',
          color: 'yellow',
        );
      }
    } else {
      _log('Controller not found for index $currentIndex', emoji: '⚠️', color: 'yellow');
    }
  }

  Future<void> scroll(int index) async {
    if (_disposed) return;

    // 数据为空检查
    if (_data.isEmpty) {
      _log('Cannot scroll - no data available', emoji: '⚠️', color: 'yellow');
      return;
    }

    // 边界检查
    if (index < 0 || index >= _data.length) {
      _log('Invalid scroll index: $index (data length: ${_data.length})', emoji: '❌', color: 'red');
      return;
    }

    _log('Scrolling to index: $index (previous: $_prevIndex)', emoji: '🔄', color: 'blue');

    // 暂停其他项目
    _pauseOtherItems(index);

    if (index == _prevIndex) {
      _autoPlayCurrent(index);
      return;
    }

    // 检查分页
    await _triggerPaginationIfNeeded(index);

    // 重建窗口到目标索引
    await _rebuildPreloadWindow(index);

    _prevIndex = index;
    _autoPlayCurrent(index);
  }

  /// 获取当前聚焦的控制器（窗口中部）
  PreloadController? getCurrentController() {
    if (_controllers.isEmpty) {
      _log('Preload window is empty, cannot get current controller', emoji: '⚠️', color: 'yellow');
      return null;
    }
    int center = (_controllers.length / 2).floor();
    return _controllers[center];
  }

  /// 获取所有激活的控制器（调试/外部访问）
  List<PreloadController> getActiveControllers() => _controllers;

  /// 释放所有控制器
  Future<void> disposeAll() async {
    if (_disposed) return; // 防止重复调用

    _disposed = true;
    _log('Disposing all controllers...', emoji: '🧹', color: 'red');
    for (var controller in _controllers) {
      await _disposeController(controller);
    }
    _controllers.clear();
    _log('All controllers disposed', emoji: '✅', color: 'green');
  }

  /// 安全获取：若索引越界返回 null
  PreloadController? getControllerAtIndex(int index) {
    // 边界检查
    if (index < 0 || index >= _data.length || _controllers.isEmpty) {
      return null;
    }

    // 计算窗口实际范围（与 _rebuildPreloadWindow 保持一致）
    int windowStart = (_centerIndex - preloadBackward).clamp(0, _data.length - 1);
    int windowEnd = (_centerIndex + preloadForward + 1).clamp(0, _data.length);

    // 检查索引是否在窗口范围内
    if (index < windowStart || index >= windowEnd) {
      return null;
    }

    // 计算在控制器数组中的相对位置
    int relative = index - windowStart;
    if (relative >= 0 && relative < _controllers.length) {
      return _controllers[relative];
    }

    return null;
  }

  /// 获取当前活跃索引
  int getActiveIndex() => _activeIndex;

  /// 强制自动播放指定索引（初始化时使用）
  void forceAutoPlay(int index) {
    if (_disposed) return; // 防止在已销毁状态下调用

    // 边界检查
    if (index < 0 || index >= _data.length) {
      _log('Invalid forceAutoPlay index: $index (data length: ${_data.length})', emoji: '❌', color: 'red');
      return;
    }

    _log('Force auto-playing index: $index', emoji: '🎬', color: 'magenta');
    _autoPlayCurrent(index);
  }

  /// 切换指定控制器的播放/暂停
  void togglePlayPause(PreloadController controller) {
    if (_disposed) return; // 防止在已销毁状态下调用

    try {
      if (controller.isPlaying) {
        controller.pause();
        _log('Item paused', emoji: '⏸️', color: 'yellow');
      } else {
        // Pause all other items first
        for (var ctrl in _controllers) {
          if (ctrl != controller && ctrl.isPlaying) {
            try {
              ctrl.pause();
            } catch (e) {
              _log('Error pausing controller: $e', emoji: '⚠️', color: 'red');
            }
          }
        }

        // 确保控制器已初始化
        if (controller.isInitialized) {
          controller.play();
          _log('Item resumed', emoji: '▶️', color: 'green');
        } else {
          _log('Cannot play uninitialized controller', emoji: '⚠️', color: 'yellow');
          return;
        }
      }

      // Notify UI of play state change
      if (onPlayStateChanged != null) {
        onPlayStateChanged!();
      }
    } catch (e) {
      _log('Error in togglePlayPause: $e', emoji: '❌', color: 'red');
    }
  }

  /// 获取数据总数
  int getTotalCount() => _data.length;

  /// 删除指定索引的数据
  Future<bool> removeData(int index) async {
    if (_disposed || index < 0 || index >= _data.length) return false;

    _log('Removing item at index $index', emoji: '🗑️', color: 'red');

    _data.removeAt(index);
    _adjustActiveIndexAfterRemove(index, 1);

    // 重建窗口 - 确保锚点有效
    int anchor;
    if (_data.isEmpty) {
      return true; // 数据为空，无需重建窗口
    } else if (_activeIndex >= 0 && _activeIndex < _data.length) {
      anchor = _activeIndex;
    } else {
      anchor = index.clamp(0, _data.length - 1);
    }
    await _rebuildPreloadWindow(anchor);

    _log('Successfully removed item at index $index', emoji: '✅', color: 'green');
    return true;
  }

  /// 在列表末尾追加数据
  Future<int> addData(List<T> data) async {
    if (_disposed || data.isEmpty) return 0;

    _data.addAll(data);
    _log('Added ${data.length} item(s) to the end', emoji: '➕', color: 'green');

    // 重建窗口
    final anchor = _activeIndex >= 0 ? _activeIndex : 0;
    await _rebuildPreloadWindow(anchor);

    return data.length;
  }

  /// 重新设置数据源
  Future<void> setDataSource(List<T> data, {int initialIndex = 0, bool autoPlay = true}) async {
    if (_disposed) return;

    // 先清理现有资源
    for (var controller in _controllers) {
      await _disposeController(controller);
    }
    _controllers.clear();

    // 重置状态
    _data = List.of(data);
    _isPaginating = false;
    _firstItemPlayed = false;
    _activeIndex = -1;
    _prevIndex = 0;

    if (_data.isNotEmpty) {
      int targetIndex = initialIndex.clamp(0, _data.length - 1);
      await _rebuildPreloadWindow(targetIndex);

      if (autoPlay) {
        _autoPlayCurrent(targetIndex);
      }
    }
  }

  /// 在指定位置插入数据
  Future<bool> insertData(int index, List<T> data) async {
    if (_disposed || index < 0 || index > _data.length || data.isEmpty) return false;

    _log('Inserting ${data.length} item(s) at index $index', emoji: '➕', color: 'green');

    _data.insertAll(index, data);
    _adjustActiveIndexAfterInsert(index, data.length);

    // 重建窗口
    final anchor = _activeIndex >= 0 ? _activeIndex : index;
    await _rebuildPreloadWindow(anchor);

    _log('Successfully inserted ${data.length} item(s)', emoji: '✅', color: 'green');
    return true;
  }

  /// 调整当前活跃索引（删除后）
  void _adjustActiveIndexAfterRemove(int removedIndex, int removedCount) {
    if (_activeIndex < 0) return;

    if (_activeIndex < removedIndex) {
      // 当前活跃的项目在删除范围之前，无需调整
      return;
    }

    if (_activeIndex < removedIndex + removedCount) {
      // 当前活跃的项目被删除了，需要选择新的活跃位置
      if (removedIndex > 0) {
        _activeIndex = removedIndex - 1; // 活跃前一个项目
      } else if (_data.isNotEmpty) {
        _activeIndex = 0; // 活跃第一个项目
      } else {
        _activeIndex = -1; // 没有项目了
      }
      _log('Active index adjusted to $_activeIndex after removal', emoji: '🔄', color: 'yellow');
    } else {
      // 当前活跃的项目在删除范围之后，需要调整索引
      _activeIndex = (_activeIndex - removedCount).clamp(0, _data.length - 1);
      _log('Active index adjusted to $_activeIndex after removal', emoji: '🔄', color: 'yellow');
    }
  }

  /// 调整当前活跃索引（插入后）
  void _adjustActiveIndexAfterInsert(int insertIndex, int insertCount) {
    if (_activeIndex < 0) return;

    if (_activeIndex < insertIndex) {
      // 当前活跃的项目在插入位置之前，无需调整
      return;
    }

    // 当前活跃的项目在插入位置之后，需要调整索引
    _activeIndex = (_activeIndex + insertCount).clamp(0, _data.length - 1);
    _log('Active index adjusted to $_activeIndex after insertion', emoji: '🔄', color: 'yellow');
  }

  /// 获取数据列表的当前状态
  Map<String, dynamic> getDataListStatus() {
    return {
      'totalItems': _data.length,
      'preloadWindowCenter': _centerIndex,
      'preloadWindowStart': _centerIndex - preloadBackward,
      'preloadWindowEnd': _centerIndex + preloadForward,
      'activeIndex': _activeIndex,
      'previousIndex': _prevIndex,
      'windowSize': _controllers.length,
      'isPaginating': _isPaginating,
      'disposed': _disposed,
    };
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
