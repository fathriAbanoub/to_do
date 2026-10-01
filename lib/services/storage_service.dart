import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_ce/hive.dart';
import 'package:uuid/uuid.dart';

import '../models/syncable.dart';
import '../models/task.dart';
import '../models/category.dart';
import '../constants.dart';

const _uuid = Uuid();

/// Central data-access layer wrapping the task, category and app-settings
/// Hive boxes.
///
/// Every mutation to a sync-eligible row routes through [_saveDirty] or
/// [_softDelete] so the sync engine's persistent outbox (the `isDirty` flag
/// on the row itself) is always current. A naked `.save()` or `.delete()`
/// on a sync-eligible box is a bug — review rule enforced at code review
/// time; the helpers exist specifically so there is exactly one place to
/// audit.
///
/// All methods are static — there is exactly one logical store, initialised
/// by [init] with the local-db cipher from the key gate in main.dart (after
/// the master key has been loaded or adopted). Nothing may touch this class
/// before init succeeds: the gate shows the task screen and starts sync
/// only afterwards, and an init failure blocks both behind an explicit,
/// confirmed reset — never an automatic wipe.
// ponytail: static-method service is sufficient for a single-screen-at-a-time
// app; promote to a provided/injected service if multi-window or testing needs
// arise.
class StorageService {
  static late Box<Task> _taskBox;
  static late Box<TaskCategory> _categoryBox;
  static late Box<String> _settingsBox;

  // ── Dirty / soft-delete helpers ─────────────────────────────────────
  /// Single choke point for local mutations. Marks the row dirty and saves
  /// it, so the box watcher in SyncService always sees a change worth
  /// pushing. Every mutable path in this class MUST go through here or
  /// [_softDelete] — no bare `.save()`.
  static Future<void> _saveDirty(Syncable obj) async {
    obj.isDirty = true;
    await obj.save();
  }

  /// Soft-delete a row: mark it deleted AND dirty, then save. The row stays
  /// in the box so the tombstone can be pushed; [purgeDeleted] hard-removes
  /// it once the push has confirmed.
  static Future<void> _softDelete(Syncable obj) async {
    obj.isDeleted = true;
    obj.isDirty = true;
    await obj.save();
  }

  // ── Initialisation ──────────────────────────────────────────────────
  /// Opens the settings box (plaintext — it holds only flags, the pull
  /// watermark and the last category id, no user content), then the task
  /// and category boxes AES-encrypted with [cipher], then runs the
  /// schema-version clear, the one-time legacy migration and the Quick
  /// Tasks guarantee — in that order (see the schema-version note).
  ///
  /// Throws when a box cannot be opened with [cipher] (wrong or missing
  /// key, damaged files) or when the legacy migration fails verification;
  /// the caller turns that into the blocking reset screen.
  static Future<void> init(HiveAesCipher cipher) async {
    // Settings first: the schema-version key and the migration marker live
    // in it, and resetLocalData must work even when a later open below
    // throws.
    _settingsBox = await Hive.openBox<String>(kSettingsBoxName);
    _taskBox = await Hive.openBox<Task>(kTaskBoxName, encryptionCipher: cipher);
    _categoryBox = await Hive.openBox<TaskCategory>(
      kCategoryBoxName,
      encryptionCipher: cipher,
    );

    // Schema v2 (soft deletes) migration. Hive adapters default missing
    // fields to their constructor defaults; since `isDirty` defaults to
    // `true`, EVERY pre-existing row reads back dirty on the first launch
    // after upgrade — which would trigger a mass re-upload that overwrites
    // newer server data on the next sync. Clear those false-positive flags
    // once, but only for installs that have already completed their initial
    // push (a fresh install's rows are genuinely dirty and must be pushed).
    //
    // MUST run BEFORE _migrateLegacyBoxes: a user upgrading straight from
    // pre-encryption has legacy plaintext boxes that the migration will
    // copy into the encrypted ones — those copied rows are new and DO need
    // pushing, so clearing their flags after the migration would strand
    // them locally.
    final schemaVersion = _settingsBox.get(
      kSchemaVersionKey,
      defaultValue: '1',
    );
    if (schemaVersion == '1') {
      if (_settingsBox.get(kInitialPushDoneKey) != null) {
        for (final t in _taskBox.values) {
          if (t.isDirty) {
            t.isDirty = false;
            await t.save(); // NOT _saveDirty — we're clearing, not marking.
          }
        }
        for (final c in _categoryBox.values) {
          if (c.isDirty) {
            c.isDirty = false;
            await c.save(); // NOT _saveDirty — we're clearing, not marking.
          }
        }
      }
      await _settingsBox.put(kSchemaVersionKey, kSchemaVersionSoftDeletes);
    }

    await _migrateLegacyBoxes();
    await ensureQuickTasks();
  }

  /// Hard-removes every soft-deleted row whose tombstone has already been
  /// pushed (`isDeleted && !isDirty`).
  ///
  /// Runs ONCE per launch, from main.dart after [init] succeeds — never
  /// after a push, because the undo snackbar's window is still open then
  /// and removing the row from disk would break its UNDO action. Running
  /// only at startup also means the purge competes with nothing: no UI is
  /// mounted, no gestures are mid-flight, no snackbars are queued.
  static Future<void> purgeDeleted() async {
    final toPurgeTasks = _taskBox.values
        .where((t) => t.isDeleted && !t.isDirty)
        .toList();
    for (final t in toPurgeTasks) {
      await _taskBox.delete(t.id);
    }

    final toPurgeCats = _categoryBox.values
        .where((c) => c.isDeleted && !c.isDirty)
        .toList();
    for (final c in toPurgeCats) {
      await _categoryBox.delete(c.id);
    }
  }

  /// One-time import of the pre-encryption plaintext boxes (Phase 4),
  /// keyed by kLegacyMigrationDoneKey in the settings box. Unchanged from
  /// the previous version — see the surrounding comment there.
  static Future<void> _migrateLegacyBoxes() async {
    if (_settingsBox.get(kLegacyMigrationDoneKey) != null) {
      await _deleteLegacyBoxesQuietly();
      return;
    }
    final hasLegacyTasks = await Hive.boxExists(kLegacyTaskBoxName);
    final hasLegacyCategories = await Hive.boxExists(kLegacyCategoryBoxName);
    if (!hasLegacyTasks && !hasLegacyCategories) return;
    final legacyTasks = hasLegacyTasks
        ? await Hive.openBox<Task>(kLegacyTaskBoxName)
        : null;
    final legacyCategories = hasLegacyCategories
        ? await Hive.openBox<TaskCategory>(kLegacyCategoryBoxName)
        : null;
    // A HiveObject cannot belong to two boxes: every record is rebuilt
    // field by field into a FRESH model instance, under the same key.
    if (legacyTasks != null) {
      for (final key in legacyTasks.keys.cast<String>()) {
        final t = legacyTasks.get(key)!;
        await _taskBox.put(
          key,
          Task(
            id: t.id,
            title: t.title,
            completed: t.completed,
            categoryId: t.categoryId,
            position: t.position,
            createdAt: t.createdAt,
            // Legacy rows predate soft deletes: carry the flags forward
            // explicitly so the constructor defaults do not silently mark
            // them dirty (they were captured by the schema-version clear
            // above before this migration ran).
            isDirty: false,
            isDeleted: false,
          ),
        );
      }
    }
    if (legacyCategories != null) {
      for (final key in legacyCategories.keys.cast<String>()) {
        final c = legacyCategories.get(key)!;
        await _categoryBox.put(
          key,
          TaskCategory(
            id: c.id,
            name: c.name,
            colorValue: c.colorValue,
            position: c.position,
            isDirty: false,
            isDeleted: false,
          ),
        );
      }
    }
    if (legacyTasks != null) {
      if (_taskBox.length != legacyTasks.length) {
        throw StateError(
          'legacy task migration: ${_taskBox.length} of '
          '${legacyTasks.length} records present',
        );
      }
      for (final key in legacyTasks.keys) {
        if (!_taskBox.containsKey(key)) {
          throw StateError('legacy task migration: key missing after copy');
        }
      }
    }
    if (legacyCategories != null) {
      if (_categoryBox.length != legacyCategories.length) {
        throw StateError(
          'legacy category migration: ${_categoryBox.length} of '
          '${legacyCategories.length} records present',
        );
      }
      for (final key in legacyCategories.keys) {
        if (!_categoryBox.containsKey(key)) {
          throw StateError('legacy category migration: key missing after copy');
        }
      }
    }
    await _settingsBox.put(kLegacyMigrationDoneKey, kSettingsMarkerValue);
    if (legacyTasks != null) await legacyTasks.close();
    if (legacyCategories != null) await legacyCategories.close();
    await _deleteLegacyBoxesQuietly();
  }

  static Future<void> _deleteLegacyBoxesQuietly() async {
    for (final name in _legacyBoxNames) {
      try {
        await Hive.deleteBoxFromDisk(name);
      } catch (e) {
        debugPrint('legacy box delete failed ($name): ${e.runtimeType}');
      }
    }
  }

  // ── App settings (dedicated settings box) ────────────────────────────
  static String? getLastSelectedCategoryId() =>
      _settingsBox.get(kLastCategoryIdKey);

  static Future<void> setLastSelectedCategoryId(String id) =>
      _settingsBox.put(kLastCategoryIdKey, id);

  static String getLastSyncWatermark() =>
      _settingsBox.get(kLastSyncWatermarkKey, defaultValue: kEpochWatermark)!;

  static Future<void> setLastSyncWatermark(String iso) =>
      _settingsBox.put(kLastSyncWatermarkKey, iso);

  static bool getInitialPushDone() =>
      _settingsBox.get(kInitialPushDoneKey) != null;

  static Future<void> setInitialPushDone() =>
      _settingsBox.put(kInitialPushDoneKey, kSettingsMarkerValue);

  /// Category id to open at launch. Skips soft-deleted categories so a
  /// restart cannot land on a tombstone.
  static String getInitialCategoryId() {
    final last = getLastSelectedCategoryId();
    return (last != null && getCategory(last) != null)
        ? last
        : kQuickTasksCategoryId;
  }

  /// Wipes local storage after a user-confirmed reset (there is no
  /// automatic wipe anywhere in the app).
  static Future<void> resetLocalData() async {
    await Hive.deleteBoxFromDisk(kTaskBoxName);
    await Hive.deleteBoxFromDisk(kCategoryBoxName);
    await Hive.deleteBoxFromDisk(kLegacyTaskBoxName);
    await Hive.deleteBoxFromDisk(kLegacyCategoryBoxName);
    if (Hive.isBoxOpen(kSettingsBoxName)) {
      await _settingsBox.delete(kInitialPushDoneKey);
      await setLastSyncWatermark(kEpochWatermark);
    } else {
      await Hive.deleteBoxFromDisk(kSettingsBoxName);
    }
  }

  static String? getUserName() => _settingsBox.get(kUserNameKey);
  static Future<void> setUserName(String name) =>
      _settingsBox.put(kUserNameKey, name);

  // ── Categories ──────────────────────────────────────────────────────────
  /// Soft-deleted categories are filtered out so the UI and every count
  /// derived from this list stay consistent with what the user can see.
  static List<TaskCategory> getCategories() {
    final cats = _categoryBox.values.where((c) => !c.isDeleted).toList()
      ..sort((a, b) => a.position.compareTo(b.position));
    return cats;
  }

  /// O(1) — category ids are used as box keys. A soft-deleted category
  /// reads as null, matching the reader-filter contract.
  static TaskCategory? getCategory(String id) {
    final c = _categoryBox.get(id);
    return (c == null || c.isDeleted) ? null : c;
  }

  static Future<TaskCategory> addCategory(String name, int colorValue) async {
    final categories = getCategories();
    final cat = TaskCategory(
      id: _uuid.v4(),
      name: name,
      colorValue: colorValue,
      position: categories.length,
    );
    // Default isDirty: true — put() alone queues the row.
    await _categoryBox.put(cat.id, cat);
    return cat;
  }

  static Future<void> updateCategory(
    String id, {
    String? name,
    int? colorValue,
  }) async {
    final cat = getCategory(id);
    if (cat == null) return;
    if (name != null) cat.name = name;
    if (colorValue != null) cat.colorValue = colorValue;
    await _saveDirty(cat);
  }

  /// Deletes a category. If [moveTasks] is true, tasks migrate to Quick Tasks
  /// instead of being destroyed.  §19 guarantees the caller has already asked
  /// the user which path to take.
  static Future<void> deleteCategory(
    String id, {
    required bool moveTasks,
  }) async {
    if (id == kQuickTasksCategoryId) return; // §20 protection

    if (moveTasks) {
      // ponytail: moveTasks: true is an UPDATE, not a delete. The tasks
      // are pushed as ordinary mutations (new categoryId, new position).
      // Only the category itself is soft-deleted. Using _softDelete on the
      // moved tasks here would wipe them everywhere.
      final tasks = getTasksForCategory(id);
      final quickTasks = getTasksForCategory(kQuickTasksCategoryId);
      int nextPosition = quickTasks.isEmpty ? 0 : quickTasks.last.position + 1;
      for (final task in tasks) {
        task.categoryId = kQuickTasksCategoryId;
        task.position = nextPosition++;
        await _saveDirty(task); // UPDATE, not delete.
      }
    } else {
      final tasks = getTasksForCategory(id);
      for (final task in tasks) {
        await _softDelete(task); // Actual delete.
      }
    }

    final cat = getCategory(id);
    if (cat != null) await _softDelete(cat);

    await _reindexCategoryPositions();
  }

  static Future<void> reorderCategories(List<TaskCategory> newOrder) async {
    for (int i = 0; i < newOrder.length; i++) {
      newOrder[i].position = i;
      await _saveDirty(newOrder[i]);
    }
  }

  /// §15 / §20: guarantee Quick Tasks always exists.
  static Future<void> ensureQuickTasks() async {
    if (_categoryBox.get(kQuickTasksCategoryId) != null) return;
    final cat = TaskCategory(
      id: kQuickTasksCategoryId,
      name: kQuickTasksCategoryName,
      colorValue: kDefaultCategoryColorValue,
      position: 0,
      // A fresh install has no server state to protect; let the sync engine
      // push the Quick Tasks row as soon as it verifies.
      isDirty: true,
      isDeleted: false,
    );
    await _categoryBox.put(cat.id, cat);
  }

  // ── Tasks ───────────────────────────────────────────────────────────────
  static List<Task> getTasksForCategory(String categoryId) {
    return _taskBox.values
        .where((t) => t.categoryId == categoryId && !t.isDeleted)
        .toList()
      ..sort((a, b) => a.position.compareTo(b.position));
  }

  static ({List<Task> active, List<Task> completed}) getTasksSplit(
    String categoryId,
  ) {
    final all = getTasksForCategory(categoryId);
    return (
      active: all.where((t) => !t.completed).toList(),
      completed: all.where((t) => t.completed).toList(),
    );
  }

  static Future<Task> addTask(String title, String categoryId) async {
    final all = getTasksForCategory(categoryId);
    final active = all.where((t) => !t.completed).toList();
    final position = active.isEmpty ? 0 : active.last.position + 1;
    // Shift any completed tasks whose position would collide.
    final completed = all.where((t) => t.completed).toList();
    for (final task in completed) {
      if (task.position >= position) {
        task.position = task.position + 1;
        await _saveDirty(task);
      }
    }
    final task = Task(
      id: _uuid.v4(),
      title: title,
      categoryId: categoryId,
      position: position,
      createdAt: DateTime.now(),
      // Default isDirty: true — put() alone queues the row.
    );
    await _taskBox.put(task.id, task);
    return task;
  }

  static Future<void> updateTask(Task task) async => await _saveDirty(task);

  static Future<void> deleteTask(String id) async {
    final task = _taskBox.get(id);
    if (task != null) await _softDelete(task);
  }

  /// Toggle completed state and reorder so active tasks precede completed ones.
  static Future<void> toggleTaskCompleted(Task task) async {
    task.completed = !task.completed;
    await _saveDirty(task);
    await _reindexTaskPositions(task.categoryId);
  }

  /// Re-insert a previously-deleted task.
  ///
  /// Capture-before-mutate ordering is load-bearing: Hive's `box.values`
  /// returns in-memory references, so flipping `task.isDeleted = false`
  /// BEFORE reading [getTasksForCategory] would put the restoring task into
  /// its own `existing` list and corrupt the shift math by one slot.
  static Future<void> restoreTask(Task task) async {
    final existing = getTasksForCategory(task.categoryId)
        .where((t) => t.id != task.id)
        .toList();

    task.position = task.position.clamp(0, existing.length);
    for (final t in existing) {
      if (t.position >= task.position) {
        t.position++;
        await _saveDirty(t);
      }
    }

    task.isDeleted = false;
    task.isDirty = true;
    await _taskBox.put(task.id, task);
  }

  /// Re-insert a previously-deleted category at its old slot and put its
  /// captured tasks back under it. Same capture-before-mutate ordering as
  /// [restoreTask].
  static Future<void> restoreCategory(
    TaskCategory category,
    List<({Task task, int position})> tasks,
  ) async {
    final existing = getCategories().where((c) => c.id != category.id).toList();
    category.position = category.position.clamp(0, existing.length);
    for (final c in existing) {
      if (c.position >= category.position) {
        c.position++;
        await _saveDirty(c);
      }
    }

    category.isDeleted = false;
    category.isDirty = true;
    await _categoryBox.put(category.id, category);

    for (final snap in tasks) {
      snap.task.categoryId = category.id;
      snap.task.position = snap.position;
      snap.task.isDeleted = false;
      snap.task.isDirty = true;
      await _taskBox.put(snap.task.id, snap.task);
    }
  }

  static Future<void> reorderActiveTasks(
    String categoryId,
    List<Task> newActiveOrder,
  ) async {
    final completed = getTasksForCategory(categoryId)
        .where((t) => t.completed)
        .toList();
    int pos = 0;
    for (final task in newActiveOrder) {
      task.position = pos++;
      await _saveDirty(task);
    }
    for (final task in completed) {
      task.position = pos++;
      await _saveDirty(task);
    }
  }

  /// §12: remove only completed tasks in the given category.
  static Future<int> clearCompleted(String categoryId) async {
    final completed = getTasksForCategory(categoryId)
        .where((t) => t.completed)
        .toList();
    for (final task in completed) {
      await _softDelete(task);
    }
    return completed.length;
  }

  /// §13: remove ALL tasks in the given category.
  static Future<void> deleteAllTasks(String categoryId) async {
    final tasks = getTasksForCategory(categoryId);
    for (final task in tasks) {
      await _softDelete(task);
    }
  }

  static int getTaskCountForCategory(String categoryId) {
    return _taskBox.values
        .where((t) => t.categoryId == categoryId && !t.isDeleted)
        .length;
  }

  /// Completed tasks only — backs the Clear Completed confirmation dialog.
  static int getCompletedCount(String categoryId) {
    return _taskBox.values
        .where((t) => t.categoryId == categoryId && t.completed && !t.isDeleted)
        .length;
  }

  // ── Private helpers ────────────────────────────────────────────────────
  static Future<void> _reindexTaskPositions(String categoryId) async {
    final all = getTasksForCategory(categoryId);
    final active = all.where((t) => !t.completed).toList();
    final completed = all.where((t) => t.completed).toList();
    int pos = 0;
    for (final task in active) {
      task.position = pos++;
      await _saveDirty(task);
    }
    for (final task in completed) {
      task.position = pos++;
      await _saveDirty(task);
    }
  }

  static Future<void> _reindexCategoryPositions() async {
    final cats = getCategories();
    for (int i = 0; i < cats.length; i++) {
      cats[i].position = i;
      await _saveDirty(cats[i]);
    }
  }
}

const List<String> _legacyBoxNames = [
  kLegacyTaskBoxName,
  kLegacyCategoryBoxName,
];

// ── Sanity checks ──────────────────────────────────────────────────────────
// Pure-math simulations of the shift/clamp/fallback logic above — the real
// methods need open Hive boxes and a cipher, which a headless run cannot
// provide. Unchanged from the previous version: the shift math itself did
// not change, only WHEN the capture happens (see restoreTask's doc).
void main() {
  var assertsEnabled = false;
  assert(() {
    assertsEnabled = true;
    return true;
  }());
  if (!assertsEnabled) {
    throw StateError(
      'sanity checks ran without asserts; without asserts every check '
      'below would silently pass',
    );
  }
  _assertRestorePositionShift();
  _assertRestoreClamp();
  _assertCategoryRestoreShift();
  _assertLastCategoryFallback();
  _assertQuickTasksProtection();
  // ignore: avoid_print
  print('All StorageService sanity checks passed.');
}

void _assertRestorePositionShift() {
  final positions = [0, 2, 3];
  const restoreAt = 2;
  final shifted = positions.map((p) => p >= restoreAt ? p + 1 : p).toList();
  assert(shifted[0] == 0, 'Position 0 unchanged');
  assert(shifted[1] == 3, 'Position 2 shifted to 3');
  assert(shifted[2] == 4, 'Position 3 shifted to 4');
}

void _assertQuickTasksProtection() {
  assert(kQuickTasksCategoryId == 'quick-tasks');
}

void _assertRestoreClamp() {
  const existingPositions = [0, 1];
  const staleBeyondEnd = 5;
  final insertAt = staleBeyondEnd.clamp(0, existingPositions.length);
  final shifted = existingPositions
      .map((p) => p >= insertAt ? p + 1 : p)
      .toList();
  assert(insertAt == 2, 'Out-of-range position clamps to existing.length');
  assert(shifted[0] == 0 && shifted[1] == 1, 'Nothing shifts on end-append');
  const staleInRange = 1;
  final insertAt2 = staleInRange.clamp(0, existingPositions.length);
  final shifted2 = existingPositions
      .map((p) => p >= insertAt2 ? p + 1 : p)
      .toList();
  assert(insertAt2 == 1, 'In-range position is used as-is');
  assert(shifted2[0] == 0 && shifted2[1] == 2, 'Shift frees the insert slot');
}

void _assertCategoryRestoreShift() {
  const positions = [0, 1, 2];
  const restoreAt = 1;
  final shifted = positions.map((p) => p >= restoreAt ? p + 1 : p).toList();
  assert(shifted[0] == 0 && shifted[1] == 2 && shifted[2] == 3);
  assert(5.clamp(0, positions.length) == 3, 'Beyond-end slot clamps');
}

void _assertLastCategoryFallback() {
  String resolve(String? storedId, {bool categoryExists = true}) =>
      storedId != null && categoryExists ? storedId : kQuickTasksCategoryId;
  assert(
    resolve(null) == kQuickTasksCategoryId,
    'First launch opens Quick Tasks',
  );
  assert(
    resolve('gone', categoryExists: false) == kQuickTasksCategoryId,
    'Missing category falls back to Quick Tasks',
  );
  assert(resolve('study') == 'study', 'Existing category is restored');
}
