// ignore_for_file: avoid_print
import 'package:web_socket_channel/io.dart';

/// 连 web 控制台 WS，打印第一条 state 快照（含 nas 状态、photoCount）。
/// 用于诊断 NAS 列表是否完成、相册总数。
/// 用法：dart run tool/check_status.dart [host:port]   默认 localhost:8780
void main(List<String> argv) async {
  final host = argv.isNotEmpty ? argv[0] : 'localhost:8780';
  final ws = IOWebSocketChannel.connect(Uri.parse('ws://$host/ws'));
  final msg = await ws.stream.first.timeout(const Duration(seconds: 5));
  print(msg);
  await ws.sink.close();
}
