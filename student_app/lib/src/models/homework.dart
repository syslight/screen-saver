class DeviceCredentials {
  const DeviceCredentials({
    required this.baseUrl,
    required this.deviceId,
    required this.deviceKey,
    required this.childId,
    required this.childName,
  });

  final String baseUrl;
  final String deviceId;
  final String deviceKey;
  final String childId;
  final String childName;
}

class StudentProfile {
  const StudentProfile({
    required this.deviceId,
    required this.deviceName,
    required this.childId,
    required this.childName,
  });

  factory StudentProfile.fromJson(Map<String, dynamic> json) => StudentProfile(
    deviceId: json['deviceId'] as String,
    deviceName: json['deviceName'] as String,
    childId: json['childId'] as String,
    childName: json['childName'] as String,
  );

  final String deviceId;
  final String deviceName;
  final String childId;
  final String childName;
}

class HomeworkTask {
  const HomeworkTask({
    required this.id,
    required this.title,
    required this.subject,
    required this.taskDate,
    required this.instructions,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.dueAt,
  });

  factory HomeworkTask.fromJson(Map<String, dynamic> json) => HomeworkTask(
    id: json['id'] as String,
    title: json['title'] as String,
    subject: json['subject'] as String,
    taskDate: DateTime.parse(json['taskDate'] as String),
    dueAt: json['dueAt'] == null
        ? null
        : DateTime.parse(json['dueAt'] as String),
    instructions: json['instructions'] as String,
    status: json['status'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );

  final String id;
  final String title;
  final String subject;
  final DateTime taskDate;
  final DateTime? dueAt;
  final String instructions;
  final String status;
  final DateTime createdAt;
  final DateTime updatedAt;

  String get statusLabel => switch (status) {
    'pending' => '待开始',
    'in_progress' => '进行中',
    'needs_parent_review' => '等待家长检查',
    'completed' => '已完成',
    'cancelled' => '已取消',
    _ => status,
  };
}

class HomeworkReview {
  const HomeworkReview({
    required this.decision,
    required this.summary,
    required this.qualityLevel,
    required this.createdAt,
  });

  factory HomeworkReview.fromJson(Map<String, dynamic> json) => HomeworkReview(
    decision: json['decision'] as String,
    summary: json['summary'] as String,
    qualityLevel: json['qualityLevel'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );

  final String decision;
  final String summary;
  final String qualityLevel;
  final DateTime createdAt;

  String get decisionLabel => decision == 'accept' ? '家长已确认' : '需要重做';
}

class HomeworkSubmission {
  const HomeworkSubmission({
    required this.id,
    required this.taskId,
    required this.attemptNo,
    required this.status,
    required this.submittedAt,
    required this.assetCount,
    required this.reviews,
  });

  factory HomeworkSubmission.fromJson(Map<String, dynamic> json) =>
      HomeworkSubmission(
        id: json['id'] as String,
        taskId: json['taskId'] as String,
        attemptNo: json['attemptNo'] as int,
        status: json['status'] as String,
        submittedAt: DateTime.parse(json['submittedAt'] as String),
        assetCount: json['assetCount'] as int,
        reviews: (json['reviews'] as List<dynamic>)
            .map(
              (item) => HomeworkReview.fromJson(item as Map<String, dynamic>),
            )
            .toList(growable: false),
      );

  final String id;
  final String taskId;
  final int attemptNo;
  final String status;
  final DateTime submittedAt;
  final int assetCount;
  final List<HomeworkReview> reviews;
}
