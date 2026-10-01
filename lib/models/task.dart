import 'package:hive_ce/hive.dart';

import 'syncable.dart';

part 'task.g.dart';

@HiveType(typeId: 0)
class Task extends HiveObject with Syncable {
  @HiveField(0)
  String id;

  @HiveField(1)
  String title;

  @HiveField(2)
  bool completed;

  @HiveField(3)
  String categoryId;

  @HiveField(4)
  int position;

  @HiveField(5)
  DateTime createdAt;

  /// Local-change flag consumed by [SyncService]. Defaults to true so a
  /// freshly-constructed task is already queued for push by the time
  /// `_taskBox.put` returns — no separate "mark dirty" call to forget.
  @HiveField(6)
  bool isDirty = true;

  /// Soft-delete tombstone. The row stays in the box until the tombstone
  /// has been confirmed on the server, so the deletion is not lost if the
  /// app closes between the local delete and the next push.
  @HiveField(7)
  bool isDeleted = false;

  Task({
    required this.id,
    required this.title,
    this.completed = false,
    required this.categoryId,
    required this.position,
    required this.createdAt,
    this.isDirty = true,
    this.isDeleted = false,
  });
}
