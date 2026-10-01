import 'package:hive_ce/hive.dart';

import 'syncable.dart';

part 'category.g.dart';

/// Named TaskCategory to avoid collision with Flutter's Category.
@HiveType(typeId: 1)
class TaskCategory extends HiveObject with Syncable {
  @HiveField(0)
  String id;

  @HiveField(1)
  String name;

  @HiveField(2)
  int colorValue;

  @HiveField(3)
  int position;

  /// See [Task.isDirty]. Defaults to true so construction alone queues the
  /// row for the outbox.
  @HiveField(4)
  bool isDirty = true;

  /// See [Task.isDeleted].
  @HiveField(5)
  bool isDeleted = false;

  TaskCategory({
    required this.id,
    required this.name,
    required this.colorValue,
    required this.position,
    this.isDirty = true,
    this.isDeleted = false,
  });
}
