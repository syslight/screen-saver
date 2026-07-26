import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api/student_api.dart';
import '../app.dart';
import '../models/homework.dart';

class HomeworkDetailPage extends StatefulWidget {
  const HomeworkDetailPage({
    required this.initialTask,
    required this.api,
    required this.capturePhoto,
    this.photoPreviewBuilder,
    required this.onCredentialsInvalid,
    super.key,
  });

  final HomeworkTask initialTask;
  final StudentApi api;
  final CapturePhoto capturePhoto;
  final PhotoPreviewBuilder? photoPreviewBuilder;
  final Future<void> Function() onCredentialsInvalid;

  @override
  State<HomeworkDetailPage> createState() => _HomeworkDetailPageState();
}

class _HomeworkDetailPageState extends State<HomeworkDetailPage> {
  late HomeworkTask _task;
  List<HomeworkSubmission> _submissions = const [];
  final List<XFile> _photos = [];
  var _loading = true;
  var _starting = false;
  var _capturing = false;
  var _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _task = widget.initialTask;
    _reload();
  }

  Future<void> _reload() async {
    try {
      final results = await Future.wait<dynamic>([
        widget.api.getTask(_task.id),
        widget.api.listSubmissions(_task.id),
      ]);
      if (!mounted) return;
      setState(() {
        _task = results[0] as HomeworkTask;
        _submissions = results[1] as List<HomeworkSubmission>;
        _error = null;
      });
    } on StudentApiException catch (error) {
      await _handleApiError(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _handleApiError(StudentApiException error) async {
    if (error.isUnauthorized) {
      await widget.onCredentialsInvalid();
    } else if (mounted) {
      setState(() => _error = error.message);
    }
  }

  Future<void> _start() async {
    setState(() => _starting = true);
    try {
      final task = await widget.api.startTask(_task.id);
      if (mounted) setState(() => _task = task);
    } on StudentApiException catch (error) {
      await _handleApiError(error);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _capture() async {
    if (_photos.length >= 6) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('一次最多提交 6 张照片')));
      return;
    }
    setState(() => _capturing = true);
    try {
      final photo = await widget.capturePhoto();
      if (photo != null && mounted) setState(() => _photos.add(photo));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法打开相机，请检查相机权限')));
      }
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _submit() async {
    if (_photos.isEmpty) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.api.submit(_task.id, List.unmodifiable(_photos));
      if (!mounted) return;
      setState(() => _photos.clear());
      await _reload();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('作业已提交，等待家长检查')));
      }
    } on StudentApiException catch (error) {
      await _handleApiError(error);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final latestReview = _submissions
        .expand((submission) => submission.reviews)
        .firstOrNull;
    return Scaffold(
      appBar: AppBar(title: const Text('作业详情')),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _task.title,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                        ),
                        Chip(label: Text(_task.statusLabel)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _task.instructions,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '${_task.taskDate.month}月${_task.taskDate.day}日 · ${_task.subject}'
                      '${_task.dueAt == null ? '' : ' · ${_task.dueAt!.hour.toString().padLeft(2, '0')}:${_task.dueAt!.minute.toString().padLeft(2, '0')}前'}',
                    ),
                  ],
                ),
              ),
            ),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null) ...[
              const SizedBox(height: 12),
              MaterialBanner(
                content: Text(_error!),
                actions: [
                  TextButton(onPressed: _reload, child: const Text('重试')),
                ],
              ),
            ],
            if (_task.status == 'pending') ...[
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('startTaskButton'),
                onPressed: _starting ? null : _start,
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(_starting ? '正在开始…' : '开始做作业'),
              ),
            ],
            if (latestReview != null) ...[
              const SizedBox(height: 20),
              _ReviewCard(review: latestReview),
            ],
            if (_task.status == 'in_progress') ...[
              const SizedBox(height: 22),
              Text('拍摄作业', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              const Text('请确保字迹清楚、页面完整。可以连续拍摄，最多 6 张。'),
              const SizedBox(height: 14),
              if (_photos.isNotEmpty)
                _PhotoGrid(
                  photos: _photos,
                  previewBuilder: widget.photoPreviewBuilder,
                  onRemove: (index) => setState(() => _photos.removeAt(index)),
                ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const Key('capturePhotoButton'),
                onPressed: _capturing || _photos.length >= 6 ? null : _capture,
                icon: const Icon(Icons.camera_alt_outlined),
                label: Text(
                  _capturing ? '正在打开相机…' : '拍一页（${_photos.length}/6）',
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('submitHomeworkButton'),
                onPressed: _submitting || _photos.isEmpty ? null : _submit,
                icon: _submitting
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_upload_outlined),
                label: Text(_submitting ? '正在提交，请不要退出…' : '提交给家长检查'),
              ),
            ],
            if (_task.status == 'needs_parent_review') ...[
              const SizedBox(height: 28),
              const _StateMessage(
                icon: Icons.hourglass_top_rounded,
                title: '已提交，等待家长检查',
                message: '家长检查后，这里会显示完成结果或需要修改的地方。',
              ),
            ],
            if (_task.status == 'completed') ...[
              const SizedBox(height: 28),
              const _StateMessage(
                icon: Icons.verified_rounded,
                title: '作业已完成',
                message: '做得好！这次作业已经由家长确认。',
              ),
            ],
            if (_task.status == 'cancelled') ...[
              const SizedBox(height: 28),
              const _StateMessage(
                icon: Icons.cancel_outlined,
                title: '作业已取消',
                message: '这项作业不需要继续提交。',
              ),
            ],
            if (_submissions.isNotEmpty) ...[
              const SizedBox(height: 28),
              Text('提交记录', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 10),
              ..._submissions.map(
                (submission) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    tileColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    leading: CircleAvatar(
                      child: Text('${submission.attemptNo}'),
                    ),
                    title: Text('第 ${submission.attemptNo} 次提交'),
                    subtitle: Text(
                      '${submission.assetCount} 张照片 · ${submission.status}',
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReviewCard extends StatelessWidget {
  const _ReviewCard({required this.review});

  final HomeworkReview review;

  @override
  Widget build(BuildContext context) {
    final retry = review.decision == 'retry';
    return Card(
      color: retry ? const Color(0xFFFFF1E8) : const Color(0xFFE8F5ED),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              retry ? Icons.rate_review_outlined : Icons.thumb_up_alt_outlined,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    review.decisionLabel,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(review.summary),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhotoGrid extends StatelessWidget {
  const _PhotoGrid({
    required this.photos,
    required this.onRemove,
    this.previewBuilder,
  });

  final List<XFile> photos;
  final ValueChanged<int> onRemove;
  final PhotoPreviewBuilder? previewBuilder;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: photos.length,
      itemBuilder: (context, index) => Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child:
                previewBuilder?.call(photos[index]) ??
                Image.file(File(photos[index].path), fit: BoxFit.cover),
          ),
          Positioned(
            right: 4,
            top: 4,
            child: IconButton.filled(
              key: Key('removePhoto-$index'),
              onPressed: () => onRemove(index),
              icon: const Icon(Icons.close, size: 18),
              tooltip: '删除这张照片',
            ),
          ),
        ],
      ),
    );
  }
}

class _StateMessage extends StatelessWidget {
  const _StateMessage({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        children: [
          Icon(icon, size: 62, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 10),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
