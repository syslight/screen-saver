import 'package:flutter/material.dart';

import '../api/home_admin_api.dart';
import '../frame/frame_control_client.dart';
import '../models/family_server.dart';
import 'provider_settings_page.dart';

class FrameDashboardPage extends StatelessWidget {
  const FrameDashboardPage({
    required this.server,
    required this.frame,
    required this.token,
    required this.apiBuilder,
    required this.onCreateEnrollmentCode,
    required this.onLogout,
    super.key,
  });

  final FamilyServer server;
  final FrameController frame;
  final String token;
  final HomeAdminApi Function(FamilyServer server) apiBuilder;
  final Future<ParentEnrollmentCode> Function() onCreateEnrollmentCode;
  final Future<void> Function() onLogout;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: frame,
      builder: (context, _) {
        final state = frame.state;
        final connected = frame.connection == FrameConnection.connected;
        return Scaffold(
          appBar: AppBar(
            title: const Text('HomeAdmin'),
            actions: [
              if (!server.isCloud)
                IconButton(
                  tooltip: 'AI Provider',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ProviderSettingsPage(
                        server: server,
                        token: token,
                        apiBuilder: apiBuilder,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.tune),
                ),
              if (server.isCloud)
                IconButton(
                  tooltip: '绑定另一台家长手机',
                  onPressed: () => _showEnrollmentCode(context),
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                ),
              IconButton(
                tooltip: '退出登录',
                onPressed: onLogout,
                icon: const Icon(Icons.logout),
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: frame.connect,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(
                          connected ? Icons.check_circle : Icons.cloud_off,
                          color: connected ? Colors.green : Colors.orange,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                connected ? '客厅智能屏已连接' : _connectionText(),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                server.displayName,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        if (!connected)
                          IconButton(
                            tooltip: '重新连接',
                            onPressed: frame.connect,
                            icon: const Icon(Icons.refresh),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text('正在播放', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.photo_library_outlined),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                state.photo,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                            Text('${state.photoCount} 张'),
                          ],
                        ),
                        const Divider(height: 28),
                        _InfoRow(
                          icon: Icons.cloud_outlined,
                          text: state.weather,
                        ),
                        const SizedBox(height: 10),
                        _InfoRow(icon: Icons.mic_none, text: state.voice),
                        const SizedBox(height: 10),
                        _InfoRow(icon: Icons.storage_outlined, text: state.nas),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: connected
                            ? () => frame.send('prev_photo')
                            : null,
                        icon: const Icon(Icons.skip_previous),
                        label: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 13),
                          child: Text('上一张'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: connected
                            ? () => frame.send('next_photo')
                            : null,
                        icon: const Icon(Icons.skip_next),
                        label: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 13),
                          child: Text('下一张'),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.volume_up_outlined),
                            const SizedBox(width: 8),
                            const Text('播报音量'),
                            const Spacer(),
                            Text('${(state.volume * 100).round()}%'),
                          ],
                        ),
                        Slider(
                          value: state.volume.clamp(0, 1),
                          onChanged: connected ? frame.previewVolume : null,
                          onChangeEnd: connected
                              ? (value) =>
                                    frame.send('set_volume', value: value)
                              : null,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.music_note_rounded),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                '相册配乐',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                            Switch(
                              value: state.musicEnabled,
                              onChanged: connected
                                  ? (value) => frame.send(
                                      'set_music_enabled',
                                      value: value ? 1 : 0,
                                    )
                                  : null,
                            ),
                          ],
                        ),
                        Text(
                          state.musicQuiet
                              ? '夜间静音 · ${state.musicMood}'
                              : state.musicMood,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          state.musicTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            IconButton(
                              tooltip: state.musicMuted ? '打开音乐声音' : '静音音乐',
                              onPressed: connected
                                  ? () => frame.send(
                                      'set_music_muted',
                                      value: state.musicMuted ? 0 : 1,
                                    )
                                  : null,
                              icon: Icon(
                                state.musicMuted
                                    ? Icons.volume_off_rounded
                                    : Icons.volume_down_rounded,
                              ),
                            ),
                            Expanded(
                              child: Slider(
                                value: state.musicVolume.clamp(0, 1),
                                onChanged: connected
                                    ? frame.previewMusicVolume
                                    : null,
                                onChangeEnd: connected
                                    ? (value) => frame.send(
                                        'set_music_volume',
                                        value: value,
                                      )
                                    : null,
                              ),
                            ),
                            SizedBox(
                              width: 42,
                              child: Text(
                                '${(state.musicVolume * 100).round()}%',
                                textAlign: TextAlign.end,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: connected
                      ? () => frame.send('refresh_weather')
                      : null,
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新智能屏天气'),
                ),
                if (frame.lastEvent != null) ...[
                  const SizedBox(height: 14),
                  Text(
                    frame.lastEvent!,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  String _connectionText() => switch (frame.connection) {
    FrameConnection.connecting => '正在连接客厅智能屏…',
    FrameConnection.disconnected => '客厅智能屏离线',
    FrameConnection.connected => '客厅智能屏已连接',
  };

  Future<void> _showEnrollmentCode(BuildContext context) async {
    try {
      final enrollment = await onCreateEnrollmentCode();
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('绑定另一台家长手机'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('在另一台手机选择“使用一次性绑定码连接云平台”，然后输入：'),
              const SizedBox(height: 18),
              SelectableText(
                enrollment.code,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 4,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '约 10 分钟内有效，只能使用一次',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('完成'),
            ),
          ],
        ),
      );
    } on HomeAdminApiException catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 20),
      const SizedBox(width: 10),
      Expanded(child: Text(text)),
    ],
  );
}
