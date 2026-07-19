import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/photo_service.dart';

/// 全屏相册轮播背景：交叉渐变切换；无照片时显示渐变占位。
/// 本地项直接显示；NAS 项缓存命中直接显示，未命中保持上一帧、
/// 异步下载完成后再切换；每次展示后预取下一张。
class PhotoSlideshow extends StatefulWidget {
  const PhotoSlideshow({super.key});

  @override
  State<PhotoSlideshow> createState() => _PhotoSlideshowState();
}

class _PhotoSlideshowState extends State<PhotoSlideshow> {
  /// 当前展示的文件（NAS 下载期间保持上一帧不变）
  File? _file;

  /// [_file] 对应的相册项 id
  String? _itemId;

  /// 正在下载的相册项 id（防止在途期间重建重复发起请求）
  String? _loadingId;

  /// 递增序号：item 变化后使过期的取图结果失效
  int _requestSeq = 0;

  @override
  Widget build(BuildContext context) {
    final photos = context.watch<PhotoService>();
    final item = photos.current;
    if (item == null) {
      _file = null;
      _itemId = null;
      _loadingId = null;
    } else if (item.id != _itemId && item.id != _loadingId) {
      final cached = photos.cachedFileFor(item);
      if (cached != null) {
        // 本地项或缓存命中的 NAS 项：直接显示
        _file = cached;
        _itemId = item.id;
        _requestSeq++; // 使在途的旧请求失效
        _loadingId = null; // 旧请求已被序号判废，守卫 id 一并清除，否则它永不显示
        photos.prefetchNext();
      } else {
        // NAS 缓存未命中：保持上一帧，下载完成后再切换
        final seq = ++_requestSeq;
        final itemId = item.id;
        _loadingId = itemId;
        unawaited(photos.fileFor(item).then((file) {
          if (!mounted || seq != _requestSeq) return; // 丢弃过期结果
          setState(() {
            _loadingId = null;
            // 失败也记录 id，避免每次重建都重试；失败时保持上一帧
            _itemId = itemId;
            if (file != null) _file = file;
          });
          photos.prefetchNext();
        }));
      }
    }
    final file = _file;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 1200),
      child: file == null
          ? Container(
              key: const ValueKey('placeholder'),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF1a2a4a), Color(0xFF0d1420)],
                ),
              ),
              child: const Center(
                child: Text('把照片放进相册目录，或用手机上传',
                    style: TextStyle(fontSize: 20, color: Colors.white38)),
              ),
            )
          : Image.file(
              file,
              key: ValueKey(file.path),
              fit: BoxFit.contain,
              width: double.infinity,
              height: double.infinity,
              gaplessPlayback: true,
              errorBuilder: (context, error, stackTrace) =>
                  Container(color: Colors.black),
            ),
    );
  }
}
