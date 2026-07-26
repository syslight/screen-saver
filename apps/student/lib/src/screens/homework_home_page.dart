import 'package:flutter/material.dart';

import '../api/student_api.dart';
import '../app.dart';
import '../models/homework.dart';
import 'homework_detail_page.dart';

class HomeworkHomePage extends StatefulWidget {
  const HomeworkHomePage({
    required this.credentials,
    required this.api,
    required this.capturePhoto,
    this.photoPreviewBuilder,
    required this.onCredentialsInvalid,
    super.key,
  });

  final DeviceCredentials credentials;
  final StudentApi api;
  final CapturePhoto capturePhoto;
  final PhotoPreviewBuilder? photoPreviewBuilder;
  final Future<void> Function() onCredentialsInvalid;

  @override
  State<HomeworkHomePage> createState() => _HomeworkHomePageState();
}

class _HomeworkHomePageState extends State<HomeworkHomePage> {
  List<HomeworkTask> _tasks = const [];
  var _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final tasks = await widget.api.listTasks();
      if (!mounted) return;
      setState(() => _tasks = tasks);
    } on StudentApiException catch (error) {
      if (error.isUnauthorized) {
        await widget.onCredentialsInvalid();
        return;
      }
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openTask(HomeworkTask task) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => HomeworkDetailPage(
          initialTask: task,
          api: widget.api,
          capturePhoto: widget.capturePhoto,
          photoPreviewBuilder: widget.photoPreviewBuilder,
          onCredentialsInvalid: widget.onCredentialsInvalid,
        ),
      ),
    );
    await _load();
  }

  Future<void> _confirmForget() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重新配对？'),
        content: const Text('当前设备绑定会从平板移除。服务端设备仍需家长在作业中心撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('重新配对'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.onCredentialsInvalid();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.credentials.childName}的作业'),
        actions: [
          IconButton(
            onPressed: _confirmForget,
            tooltip: '重新配对',
            icon: const Icon(Icons.phonelink_erase_outlined),
          ),
        ],
      ),
      body: RefreshIndicator(onRefresh: _load, child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading && _tasks.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 260),
          Center(child: CircularProgressIndicator()),
        ],
      );
    }
    if (_error != null && _tasks.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 120),
          const Icon(Icons.cloud_off_outlined, size: 64),
          const SizedBox(height: 16),
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Center(
            child: FilledButton(onPressed: _load, child: const Text('重试')),
          ),
        ],
      );
    }
    if (_tasks.isEmpty) {
      return ListView(
        key: const Key('emptyTasks'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: const [
          SizedBox(height: 120),
          Icon(Icons.celebration_outlined, size: 72),
          SizedBox(height: 16),
          Text('现在没有作业', textAlign: TextAlign.center),
          SizedBox(height: 8),
          Text('下拉可以刷新', textAlign: TextAlign.center),
        ],
      );
    }
    return ListView.separated(
      key: const Key('taskList'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      itemCount: _tasks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final task = _tasks[index];
        return Card(
          child: InkWell(
            key: Key('task-${task.id}'),
            borderRadius: BorderRadius.circular(12),
            onTap: () => _openTask(task),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  CircleAvatar(
                    child: Icon(
                      task.status == 'completed'
                          ? Icons.check
                          : Icons.edit_note,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          task.title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${task.taskDate.month}月${task.taskDate.day}日 · ${task.subject}',
                        ),
                      ],
                    ),
                  ),
                  Chip(label: Text(task.statusLabel)),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
