import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

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
import 'widgets/photo_info_widget.dart';
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
    final qrRequested = context.select<CommandService, bool>(
      (c) => c.showQrRequested,
    );
    if (qrRequested && !_qrVisible) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => setState(() => _qrVisible = true),
      );
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
              color: Colors.black54,
            ),
            const _Scrim(
              begin: Alignment.bottomCenter,
              end: Alignment.center,
              color: Colors.black54,
            ),
            LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 900;
                return Stack(
                  children: [
                    Positioned(
                      top: compact ? 18 : 32,
                      left: compact ? 18 : 32,
                      child: const _AmbientInfoPanel(),
                    ),
                    Positioned(
                      right: compact ? 18 : 36,
                      bottom: compact ? 72 : 46,
                      width: compact
                          ? constraints.maxWidth - 36
                          : math.min(780, constraints.maxWidth * 0.58),
                      child: const PhotoInfoWidget(),
                    ),
                    Positioned(
                      left: compact ? 18 : 32,
                      bottom: compact ? 18 : 28,
                      child: const VoiceIndicator(),
                    ),
                  ],
                );
              },
            ),
            if (_qrVisible)
              QrCodeOverlay(
                onClose: () {
                  setState(() => _qrVisible = false);
                  context.read<CommandService>().dismissQr();
                },
              ),
            // 标注浮层：底部居中，默认半透明（0.2），hover 强化（1.0）
            Positioned(
              bottom: 16,
              left: 0,
              right: 0,
              child: Center(
                child: AnnotateBar(
                  onAnnotate: (reason) => _annotate(context, reason),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 固定环境信息岛：远距离先看时间，再看天气和日历。
class _AmbientInfoPanel extends StatelessWidget {
  const _AmbientInfoPanel();

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.black.withValues(alpha: 0.64),
              Colors.black.withValues(alpha: 0.28),
            ],
          ),
          boxShadow: const [
            BoxShadow(color: Colors.black38, blurRadius: 24, spreadRadius: 2),
          ],
        ),
        child: const Padding(
          padding: EdgeInsets.fromLTRB(24, 20, 28, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ClockWidget(),
              SizedBox(height: 18),
              WeatherWidget(),
              SizedBox(height: 15),
              CalendarWidget(),
            ],
          ),
        ),
      ),
    );
  }
}

class _Scrim extends StatelessWidget {
  const _Scrim({required this.begin, required this.end, required this.color});

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
