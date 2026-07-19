import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../server/control_server.dart';

/// 控制台二维码浮层：手机扫码进入 Web 控制台。
class QrCodeOverlay extends StatelessWidget {
  const QrCodeOverlay({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final server = context.read<ControlServer>();
    final url = server.url ?? '服务器启动中…';
    return GestureDetector(
      onTap: onClose,
      child: Container(
        color: Colors.black87,
        child: Center(
          child: Container(
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: const Color(0xFF1e2228),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('手机扫码控制',
                    style: TextStyle(fontSize: 24, color: Colors.white)),
                const SizedBox(height: 20),
                if (server.url != null)
                  QrImageView(
                    data: server.url!,
                    size: 260,
                    backgroundColor: Colors.white,
                  ),
                const SizedBox(height: 16),
                Text(url,
                    style: const TextStyle(
                        fontSize: 18, color: Colors.white70)),
                const SizedBox(height: 8),
                const Text('手机和本机需在同一局域网 · 点击任意处关闭',
                    style: TextStyle(fontSize: 14, color: Colors.white38)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
