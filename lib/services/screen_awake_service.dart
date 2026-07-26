import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// 保持智能屏常亮：Flutter wakelock + Linux X11 DPMS 双保险，并在恢复时重申。
class ScreenAwakeService with WidgetsBindingObserver {
  Timer? _refreshTimer;

  Future<void> start() async {
    WidgetsBinding.instance.addObserver(this);
    await _apply();
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(
      const Duration(minutes: 2),
      (_) => unawaited(_apply()),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_apply());
  }

  Future<void> _apply() async {
    try {
      await WakelockPlus.enable();
    } catch (error) {
      debugPrint('wakelock 启用失败: $error');
    }
    if (!Platform.isLinux) return;
    for (final args in const [
      ['s', 'off'],
      ['-dpms'],
      ['s', 'noblank'],
    ]) {
      try {
        await Process.run('xset', args);
      } catch (error) {
        debugPrint('xset ${args.join(' ')} 失败: $error');
      }
    }
  }

  void dispose() {
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }
}
