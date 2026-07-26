/// NAS 截图过滤：判断 NAS 上的路径/文件名是否放行（即不是截图）。
///
/// 供 NAS 相册列目录时逐文件调用。[keywords] 采用替换语义：它就是完整
/// 生效的关键词列表（默认值只是初始内容），不存在隐藏的内置关键词。
/// 规则（[enabled] 为 false 时全部放行）：
/// 1. 路径（转小写后）含任一非空关键词（转小写）→ 排除；
/// 2. 文件名 basename 命中常见截图命名模式（Screenshot_*、Screen Shot *、
///    screencap*，大小写不敏感）→ 排除（内置正则，不受 keywords 影响）；
/// 3. 其余放行。
library;

/// 常见截图文件名模式（匹配文件名 basename，大小写不敏感）。
/// 与关键词过滤相互独立，自定义 keywords 不会关闭这些内置模式。
final _screenshotPatterns = [
  RegExp(r'^Screenshot[_ -]', caseSensitive: false),
  RegExp(r'^Screen Shot', caseSensitive: false),
  RegExp(r'^screencap', caseSensitive: false),
];

/// 判断 [pathOrName]（NAS 路径或文件名）是否放行。
///
/// 规则（[enabled] 为 false 时全部放行）：
/// 1. 路径任一段为 `@eaDir`（群晖缩略图目录）→ 排除（文件级防御；
///    目录级在列目录时早 skip 不递归）；
/// 2. [size] < [minBytes]（>0 时）→ 排除（缩略图/图标）；
/// 3. 路径（转小写后）含任一非空关键词（转小写）→ 排除；
/// 4. 文件名 basename 命中常见截图命名模式 → 排除（内置正则）；
/// 5. 其余放行。
bool nasPhotoAllowed(
  String pathOrName, {
  required bool enabled,
  required List<String> keywords,
  int size = 0,
  int minBytes = 0,
}) {
  if (!enabled) return true;
  if (pathOrName.split(RegExp(r'[/\\]')).any((s) => s == '@eaDir')) {
    return false;
  }
  if (minBytes > 0 && size < minBytes) return false;
  final lower = pathOrName.toLowerCase();
  for (final keyword in keywords) {
    if (keyword.isEmpty) continue;
    if (lower.contains(keyword.toLowerCase())) return false;
  }
  final basename = pathOrName.split(RegExp(r'[/\\]')).last;
  for (final pattern in _screenshotPatterns) {
    if (pattern.hasMatch(basename)) return false;
  }
  return true;
}
