// ignore_for_file: avoid_print
// NAS WebDAV 连接诊断脚本（独立运行，不依赖 Flutter 运行时）。
//
// 用法（在项目根目录，先 unset 代理变量，避免局域网请求被代理劫持）：
//   dart run tool/check_nas.dart --url http://192.168.1.22:5005 \
//       --user <账号> --password <密码> --dir /photo
// 省略参数时：按顺序读环境变量 NAS_URL/NAS_USER/NAS_PASSWORD/NAS_DIR，
// 再省略则用 app_config.dart 的默认值（仅 url 有默认）。
//
// 诊断三步：
//   1. ping        —— TCP/HTTP 可达性 + 凭据是否正确（401 会抛出）
//   2. readDir     —— remoteDir 是否存在、账号是否有读权限
//   3. 递归列图片  —— 按项目过滤规则统计可播放图片数与被过滤数
import 'dart:io';

import 'package:webdav_client/webdav_client.dart' as webdav;

// 与 lib/services/photo_service.dart / nas_filter.dart 保持一致，避免 import
// 带 Flutter 依赖的库导致纯 dart VM 无法运行。
const imageExts = ['.jpg', '.jpeg', '.png', '.webp', '.bmp', '.gif'];
const defaultKeywords = ['截图', 'screenshot', '屏幕快照', '收集'];
final screenshotPatterns = [
  RegExp(r'^Screenshot[_ -]', caseSensitive: false),
  RegExp(r'^Screen Shot', caseSensitive: false),
  RegExp(r'^screencap', caseSensitive: false),
];

bool allowed(String pathOrName) {
  final lower = pathOrName.toLowerCase();
  for (final kw in defaultKeywords) {
    if (kw.isNotEmpty && lower.contains(kw.toLowerCase())) return false;
  }
  final basename = pathOrName.split(RegExp(r'[/\\]')).last;
  for (final p in screenshotPatterns) {
    if (p.hasMatch(basename)) return false;
  }
  return true;
}

/// 取路径扩展名（含点，小写），与 package:path 的 extension 行为一致。
String _ext(String path) {
  final base = path.split(RegExp(r'[/\\]')).last;
  final dot = base.lastIndexOf('.');
  return dot >= 0 ? base.substring(dot).toLowerCase() : '';
}

class Args {
  final String url, user, password, dir;
  Args(this.url, this.user, this.password, this.dir);
}

String _firstNonEmpty(List<String> candidates, [String fallback = '']) {
  for (final c in candidates) {
    if (c.isNotEmpty) return c;
  }
  return fallback;
}

Args parseArgs(List<String> argv) {
  String getOpt(String name) {
    final i = argv.indexOf('--$name');
    if (i >= 0 && i + 1 < argv.length) return argv[i + 1];
    return '';
  }

  final env = Platform.environment;
  return Args(
    _firstNonEmpty(
        [getOpt('url'), env['NAS_URL'] ?? ''], 'http://192.168.1.22:5005'),
    _firstNonEmpty([getOpt('user'), env['NAS_USER'] ?? '']),
    _firstNonEmpty([getOpt('password'), env['NAS_PASSWORD'] ?? '']),
    _firstNonEmpty([getOpt('dir'), env['NAS_DIR'] ?? '']),
  );
}

void main(List<String> argv) async {
  final a = parseArgs(argv);
  print('━━━ NAS 连接诊断 ━━━');
  print('URL     : ${a.url}');
  print('User    : ${a.user.isEmpty ? "(空)" : a.user}');
  print('Password: ${a.password.isEmpty ? "(空)" : "${a.password.length} 位"}');
  print('Remote  : ${a.dir.isEmpty ? "(空 → 未配置，必填)" : a.dir}');
  print('');

  if (a.dir.isEmpty) {
    print('✗ remoteDir 为空：即使启用也不会扫描（状态显示"未配置"）。');
    print('  请用 --dir 指定 NAS 上照片所在目录，如 /photo 或 /homes/admin/Photos。');
    exit(1);
  }

  final client = webdav.newClient(a.url, user: a.user, password: a.password);
  client.setConnectTimeout(8000);
  client.setReceiveTimeout(30000);

  // 1) ping
  stdout.write('[1/3] ping ${a.url} ... ');
  try {
    await client.ping();
    print('OK');
  } catch (e) {
    print('失败');
    print('  → $e');
    print('  可能原因：NAS 不开机 / 不在同一网段 / 端口不对 / 代理未关。');
    exit(1);
  }

  // 2) readDir
  stdout.write('[2/3] readDir ${a.dir} ... ');
  try {
    final entries = await client.readDir(a.dir);
    print('OK（${entries.length} 个条目）');
  } catch (e) {
    print('失败');
    print('  → $e');
    print('  可能原因：路径不存在 / 账号无权限 / 凭据错误(401)。');
    exit(1);
  }

  // 3) 递归列图片
  stdout.write('[3/3] 递归列出图片 ... ');
  var images = 0, filtered = 0, dirs = 0;
  try {
    await _walk(client, a.dir, (path, isDir) {
      if (isDir) {
        dirs++;
        return;
      }
      if (!imageExts.contains(_ext(path))) return;
      if (allowed(path)) {
        images++;
      } else {
        filtered++;
      }
    });
    print('OK');
  } catch (e) {
    print('失败');
    print('  → $e');
    exit(1);
  }

  print('');
  print('━━━ 结果 ━━━');
  print('目录数         : $dirs');
  print('可播放图片     : $images');
  print('被过滤(截图等) : $filtered');
  if (images == 0) {
    print('⚠ 没有可播放图片：检查 remoteDir 是否指向照片目录、扩展名是否在白名单内。');
  } else {
    print('✓ 连接正常，配置写入后即可播放。');
  }
}

Future<void> _walk(webdav.Client client, String dir,
    void Function(String path, bool isDir) emit) async {
  for (final entry in await client.readDir(dir)) {
    final path = entry.path;
    if (path == null) continue;
    // 跳过目录自身回环（部分 WebDAV 服务会把 "." 返回）
    if (path == dir) continue;
    final isDir = entry.isDir == true;
    emit(path, isDir);
    if (isDir) await _walk(client, path, emit);
  }
}
