import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../services/command_service.dart';
import '../services/photo_index_service.dart';
import '../services/photo_service.dart';
import '../voice/voice_provider.dart';
import 'widgets/calendar_widget.dart';
import 'widgets/clock_widget.dart';
import 'widgets/photo_slideshow.dart';
import 'widgets/annotate_bar.dart';
import 'widgets/qrcode_overlay.dart';
import 'widgets/settings_sheet.dart';
import 'widgets/voice_indicator.dart';
import 'widgets/weather_widget.dart';

/// 全屏智能屏主页：相册背景 + 小组件层 + 浮层（二维码/设置）。
class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  bool _qrVisible = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final commands = context.read<CommandService>();
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowRight:
        context.read<PhotoService>().next();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        context.read<PhotoService>().prev();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyQ:
        setState(() => _qrVisible = !_qrVisible);
        if (!_qrVisible) commands.dismissQr();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyS:
        SettingsSheet.show(context);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.space:
        context.read<VoiceProvider>().triggerListen();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        if (!Platform.isAndroid) windowManager.setFullScreen(false);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.digit1:
        unawaited(_annotate(context, 'duplicate'));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.digit2:
        unawaited(_annotate(context, 'low_quality'));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.digit3:
        unawaited(_annotate(context, 'ad'));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.digit4:
        unawaited(_annotate(context, 'screenshot'));
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 人工标注当前照片（键盘 1-4）→ 立即隐藏并跳下一张。
  Future<void> _annotate(BuildContext context, String reason) async {
    final photos = context.read<PhotoService>();
    final index = context.read<PhotoIndexService>();
    final cur = photos.current;
    if (cur == null) return;
    await index.annotate(cur.id, reason);
    photos.next();
  }

  @override
  Widget build(BuildContext context) {
    // 手机端请求显示二维码时同步打开浮层
    final qrRequested = context
        .select<CommandService, bool>((c) => c.showQrRequested);
    if (qrRequested && !_qrVisible) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => setState(() => _qrVisible = true));
    }

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            const PhotoSlideshow(),
            // 顶部/底部渐变，保证文字可读
            const _Scrim(
                begin: Alignment.topCenter,
                end: Alignment.center,
                color: Colors.black54),
            const _Scrim(
                begin: Alignment.bottomCenter,
                end: Alignment.center,
                color: Colors.black54),
            const Padding(
              padding: EdgeInsets.all(32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      WeatherWidget(),
                      Spacer(),
                      ClockWidget(),
                    ],
                  ),
                  Spacer(),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      CalendarWidget(),
                      Spacer(),
                      VoiceIndicator(),
                    ],
                  ),
                ],
              ),
            ),
            if (_qrVisible)
              QrCodeOverlay(onClose: () {
                setState(() => _qrVisible = false);
                context.read<CommandService>().dismissQr();
              }),
            // 标注浮层：底部居中，默认半透明（0.2），hover 强化（1.0）
            Positioned(
              bottom: 16,
              left: 0,
              right: 0,
              child: Center(
                child: AnnotateBar(
                    onAnnotate: (reason) => _annotate(context, reason)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Scrim extends StatelessWidget {
  const _Scrim(
      {required this.begin, required this.end, required this.color});

  final Alignment begin;
  final Alignment end;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: begin,
            end: end,
            colors: [color, Colors.transparent],
          ),
        ),
      ),
    );
  }
}
