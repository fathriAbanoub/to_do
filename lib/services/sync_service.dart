import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show ValueNotifier, mapEquals;
import 'package:hive_ce/hive.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../constants.dart';
import '../models/category.dart';
import '../models/task.dart';
import 'crypto_service.dart';
import 'storage_service.dart';

/// Outcome of checking this device's sync key against the server canary.
enum SyncKeyCheck {
  /// The server canary opens under this key — or the server had no canary
  /// and one sealed with this key was adopted, refetched and verified.
  verified,

  /// The server canary exists and does NOT open under this key.
  mismatch,

  /// The server could not be reached or the check could not complete; the
  /// result says nothing about the key. Callers retry later.
  unavailable,
}

/// Best-effort two-way sync between the local Hive boxes and the Supabase
/// `items` table (single user, RLS-scoped).
///
/// Push: Hive box watch events → debounced batch upsert of every row whose
/// `isDirty` flag is set. Soft-deleted rows are pushed with a `deleted_at`
/// timestamp; rows whose `isDirty` clears after a successful push stay in
/// the box (as tombstones) until [StorageService.purgeDeleted] hard-removes
/// them at the next launch.
///
/// Pull: once verified, rows whose server updated_at is above the stored
/// watermark, applied on start and every [kSyncPollInterval]. A remote row
/// is applied only when its decoded content differs from local AND the
/// local row is not itself dirty (a local edit wins by pushing later,
/// last-write-wins by push time).
///
/// The pending push set is NOT in memory: `isDirty` on the row is the
/// outbox. An edit, a create and a delete all survive process death and
/// resume on the next launch, which is the entire point of the refactor.
// ponytail: LWW per row loses one of two concurrent offline edits of the same
// row; fine for one user on two devices, upgrade path is field-level merge.
// ponytail: 15s polling instead of a Supabase Realtime channel — one less
// listener to debug at personal scale; upgrade path is
// client.channel(...).onPostgresChanges feeding the same _applyRow.
class SyncService {
  /// Sync is opt-in until real keys are pasted into constants.dart.
  static bool get enabled => kSupabaseUrl.startsWith('https://');

  static Timer? _debounce;
  static Timer? _poll;
  static StreamSubscription<BoxEvent>? _taskSub;
  static StreamSubscription<BoxEvent>? _categorySub;
  static bool _running = false;

  static SecretKey? _syncKey;
  static bool _keyVerified = false;

  /// Raised (set true) when the server canary fails to verify against this
  /// device's key. Cleared (set false) the next time a canary verification
  /// succeeds.
  static final ValueNotifier<bool> keyMismatch = ValueNotifier(false);

  /// Pull watermark: newest server updated_at already applied locally, in
  /// MICROSECONDS since epoch.
  static int _watermarkUs = 0;

  static SupabaseClient get _client => Supabase.instance.client;

  /// Starts box watchers and the verify/pull/push loop.
  static Future<void> start({required SecretKey syncKey}) async {
    if (_running) return;
    _running = true;
    _syncKey = syncKey;
    _keyVerified = false;
    _watermarkUs = DateTime.parse(StorageService.getLastSyncWatermark())
        .toUtc()
        .microsecondsSinceEpoch;
    // Hand edit: while the initial-push flag is unset, this device's boxes
    // may be a stale pre-encryption copy, and the initial push would then
    // overwrite newer server rows. Starting the first pull from the epoch
    // re-downloads everything newer before that push can run.
    if (!StorageService.getInitialPushDone()) {
      _watermarkUs = DateTime.parse(kEpochWatermark)
          .toUtc()
          .microsecondsSinceEpoch;
    }
    _taskSub = Hive.box<Task>(kTaskBoxName).watch().listen(_onTaskEvent);
    _categorySub = Hive.box<TaskCategory>(kCategoryBoxName)
        .watch()
        .listen(_onCategoryEvent);

    await _tick();
    if (!_running) return;
    _poll?.cancel();
    _poll = Timer.periodic(kSyncPollInterval, (_) => _tick());
  }

  /// Stops syncing. Local data (including dirty rows) is untouched — the
  /// dirty flags persist across sign-out, so signing back in resumes the
  /// outbox from exactly where it left off.
  static Future<void> stop() async {
    _running = false;
    final debounce = _debounce;
    _debounce = null;
    debounce?.cancel();
    final poll = _poll;
    _poll = null;
    poll?.cancel();
    final taskSub = _taskSub;
    _taskSub = null;
    await taskSub?.cancel();
    final categorySub = _categorySub;
    _categorySub = null;
    await categorySub?.cancel();
    // No pending sets to clear — dirty flags on the rows are the outbox.
  }

  // ── Key verification (the Phase 3 gate) ────────────────────────────────
  static Future<SyncKeyCheck> checkCanary(SecretKey syncKey) async {
    String? sealed;
    try {
      sealed = await _fetchCanary();
    } catch (e, stack) {
      _log('canary fetch', e, stack);
      return SyncKeyCheck.unavailable;
    }
    if (sealed == null) {
      try {
        await _client.from(kSupabaseItemsTable).upsert([
          {
            'id': kCanaryId,
            'kind': kCanaryKind,
            'data': await CryptoService.sealCanary(syncKey),
          },
        ], ignoreDuplicates: true);
      } catch (e, stack) {
        _log('canary upload', e, stack);
        return SyncKeyCheck.unavailable;
      }
      try {
        sealed = await _fetchCanary();
      } catch (e, stack) {
        _log('canary refetch', e, stack);
        return SyncKeyCheck.unavailable;
      }
      if (sealed == null) {
        return SyncKeyCheck.unavailable;
      }
    }
    if (await CryptoService.verifyCanary(syncKey, sealed)) {
      return SyncKeyCheck.verified;
    }
    return SyncKeyCheck.mismatch;
  }

  static Future<void> _verifyKey() async {
    final syncKey = _syncKey;
    if (syncKey == null || _keyVerified) return;
    final check = await checkCanary(syncKey);
    if (check == SyncKeyCheck.verified) {
      _keyVerified = true;
      keyMismatch.value = false;
    } else if (check == SyncKeyCheck.mismatch) {
      keyMismatch.value = true;
      await stop();
    }
    // unavailable: stay unverified; the next poll tick retries.
  }

  static Future<String?> _fetchCanary() async {
    final row = await _client
        .from(kSupabaseItemsTable)
        .select('data')
        .eq('id', kCanaryId)
        .maybeSingle();
    return row == null ? null : row['data'] as String?;
  }

  /// True while a poll step is running — prevents a slow tick from stacking
  /// another on top.
  static bool _tickInFlight = false;

  static Future<void> _tick() async {
    if (_tickInFlight) return;
    _tickInFlight = true;
    try {
      if (!_keyVerified) {
        await _verifyKey();
        if (!_keyVerified || !_running) return;
      }
      await pull();
      await _initialPushIfNeeded();
      await push();
    } catch (e, stack) {
      _log('tick', e, stack);
    } finally {
      _tickInFlight = false;
    }
  }

  /// Box watch only fires for changes made after start(), so the first
  /// sign-in on a device with pre-existing data seeds the server with
  /// everything in the boxes, once. Marking every row dirty here is what
  /// makes the initial push see them — there is no in-memory set to seed.
  static Future<void> _initialPushIfNeeded() async {
    if (StorageService.getInitialPushDone()) return;
    for (final t in Hive.box<Task>(kTaskBoxName).values) {
      if (!t.isDirty) {
        t.isDirty = true;
        await t.save();
      }
    }
    for (final c in Hive.box<TaskCategory>(kCategoryBoxName).values) {
      if (!c.isDirty) {
        c.isDirty = true;
        await c.save();
      }
    }
    if (await push()) await StorageService.setInitialPushDone();
  }

  /// Pushes every row whose `isDirty` flag is set. Returns false while the
  /// key is unverified (nothing may leave the device before the canary
  /// check) and on failure; true means the batch was upserted and the flags
  /// were cleared.
  ///
  /// The dirty flags themselves are the retry mechanism: a failed push
  /// leaves them set, and the next tick (or the next box event) will pick
  /// the rows up again. No in-memory re-queue needed.
  static Future<bool> push() async {
    if (!_keyVerified) return false;
    final dirtyTasks = Hive.box<Task>(kTaskBoxName).values
        .where((t) => t.isDirty)
        .toList();
    final dirtyCats = Hive.box<TaskCategory>(kCategoryBoxName).values
        .where((c) => c.isDirty)
        .toList();

    if (dirtyTasks.isEmpty && dirtyCats.isEmpty) return true;

    final rows = <Map<String, dynamic>>[];
    try {
      for (final t in dirtyTasks) {
        rows.add({
          'id': t.id,
          'kind': kSyncKindTask,
          'data': await _seal(_taskJson(t), kind: kSyncKindTask, id: t.id),
          // Always include deleted_at so a restore (isDeleted flipped back
          // to false) clears the server-side tombstone; omitting the column
          // would leave the previous tombstone intact.
          'deleted_at': t.isDeleted
              ? DateTime.now().toUtc().toIso8601String()
              : null,
        });
      }
      for (final c in dirtyCats) {
        rows.add({
          'id': c.id,
          'kind': kSyncKindCategory,
          'data': await _seal(
            _categoryJson(c),
            kind: kSyncKindCategory,
            id: c.id,
          ),
          'deleted_at': c.isDeleted
              ? DateTime.now().toUtc().toIso8601String()
              : null,
        });
      }

      final res = await _client
          .from(kSupabaseItemsTable)
          .upsert(rows)
          .select('updated_at');
      for (final r in res) {
        _bumpWatermark(DateTime.parse(r['updated_at'] as String));
      }

      // Clear the flags only after the server has confirmed. Any failure
      // before this point leaves the rows dirty and they are re-tried.
      for (final t in dirtyTasks) {
        t.isDirty = false;
        await t.save();
      }
      for (final c in dirtyCats) {
        c.isDirty = false;
        await c.save();
      }
      return true;
    } catch (e, stack) {
      _log('push', e, stack);
      return false;
    }
  }

  // ── Codec seam ─────────────────────────────────────────────────────────
  static Future<String> _seal(
    Map<String, dynamic> json, {
    required String kind,
    required String id,
  }) {
    assert(_syncKey != null && _keyVerified);
    return CryptoService.seal(
      _syncKey!,
      utf8.encode(jsonEncode(json)),
      kind: kind,
      id: id,
    );
  }

  /// Opens a server payload into its JSON map.
  ///
  /// Rows written before encryption shipped are still plain, unprefixed
  /// JSON and are accepted as-is here. See the previous version's comment
  /// for the full justification and the query to run before deleting the
  /// legacy branch.
  static Future<Map<String, dynamic>> _open(
    String payload, {
    required String kind,
    required String id,
  }) async {
    assert(_syncKey != null && _keyVerified);
    if (!payload.startsWith(kSealPrefix)) {
      return Map<String, dynamic>.from(jsonDecode(payload) as Map);
    }
    final opened = await CryptoService.open(
      _syncKey!,
      payload,
      kind: kind,
      id: id,
    );
    return Map<String, dynamic>.from(jsonDecode(utf8.decode(opened)) as Map);
  }

  static Map<String, dynamic> _taskJson(Task t) => {
    'title': t.title,
    'completed': t.completed,
    'categoryId': t.categoryId,
    'position': t.position,
    'createdAt': t.createdAt.toUtc().toIso8601String(),
  };

  static Map<String, dynamic> _categoryJson(TaskCategory c) => {
    'name': c.name,
    'colorValue': c.colorValue,
    'position': c.position,
  };

  // ── Push ──────────────────────────────────────────────────────────────
  /// Noise guard: only a row that is actually dirty is worth scheduling a
  /// push for. Without this, every `t.isDirty = false; await t.save();` in
  /// `push()` would re-arm the debounce and the engine would ping-pong.
  static void _onTaskEvent(BoxEvent e) {
    final t = Hive.box<Task>(kTaskBoxName).get(e.key);
    if (t?.isDirty ?? false) _schedulePush();
  }

  static void _onCategoryEvent(BoxEvent e) {
    final c = Hive.box<TaskCategory>(kCategoryBoxName).get(e.key);
    if (c?.isDirty ?? false) _schedulePush();
  }

  static void _schedulePush() {
    _debounce?.cancel();
    _debounce = Timer(kSyncPushDebounce, push);
  }

  // ── Pull ───────────────────────────────────────────────────────────────
  static Future<void> pull() async {
    if (!_keyVerified) return;
    try {
      final since = DateTime.fromMicrosecondsSinceEpoch(
        _watermarkUs,
        isUtc: true,
      ).toIso8601String();
      final rows = await _client
          .from(kSupabaseItemsTable)
          .select('id, kind, data, deleted_at, updated_at')
          .gt('updated_at', since);
      // Categories before tasks so a task pulled in the same batch can
      // resolve its categoryId (alphabetical by kind happens to do it).
      rows.sort((a, b) => (a['kind'] as String).compareTo(b['kind'] as String));
      for (final row in rows) {
        try {
          await _applyRow(row);
        } catch (e, stack) {
          _log('pull row ${row['id']}', e, stack);
        }
        _bumpWatermark(DateTime.parse(row['updated_at'] as String));
      }
    } catch (e, stack) {
      _log('pull', e, stack);
    }
  }

  static Future<void> _applyRow(Map<String, dynamic> row) async {
    final id = row['id'] as String;
    final kind = row['kind'] as String;
    final deleted = row['deleted_at'] != null;

    if (kind == kSyncKindTask) {
      final box = Hive.box<Task>(kTaskBoxName);
      final local = box.get(id);

      // Local edit waiting to push: it wins by pushing later (LWW).
      if (local != null && local.isDirty) return;

      if (deleted) {
        // Remote tombstone: hard-delete locally (no undo window here — the
        // delete originated on another device).
        if (local != null) await box.delete(id);
      } else {
        final j = await _open(
          row['data'] as String,
          kind: kSyncKindTask,
          id: id,
        );

        // Echo guard: skip only if content matches AND local isn't
        // soft-deleted. A locally soft-deleted row must be resurrected if
        // the server says it's alive (a remote edit after our delete wins).
        if (local != null &&
            !local.isDeleted &&
            mapEquals(j, _taskJson(local))) {
          return;
        }

        await box.put(
          id,
          Task(
            id: id,
            title: j['title'] as String,
            completed: j['completed'] as bool? ?? false,
            categoryId: j['categoryId'] as String,
            position: (j['position'] as num).toInt(),
            createdAt: DateTime.parse(j['createdAt'] as String),
            // Critical: a pulled row is NOT a local mutation. Without
            // these, the box watcher would see the just-written row as
            // dirty and re-push it forever.
            isDirty: false,
            isDeleted: false,
          ),
        );
      }
    } else if (kind == kSyncKindCategory) {
      final box = Hive.box<TaskCategory>(kCategoryBoxName);
      final local = box.get(id);

      if (local != null && local.isDirty) return;

      if (deleted) {
        if (local != null) await box.delete(id);
      } else {
        final j = await _open(
          row['data'] as String,
          kind: kSyncKindCategory,
          id: id,
        );

        if (local != null &&
            !local.isDeleted &&
            mapEquals(j, _categoryJson(local))) {
          return;
        }

        await box.put(
          id,
          TaskCategory(
            id: id,
            name: j['name'] as String,
            colorValue: (j['colorValue'] as num).toInt(),
            position: (j['position'] as num).toInt(),
            isDirty: false,
            isDeleted: false,
          ),
        );
      }
    }
    // The canary kind (and any future kind) falls through and is ignored.
  }

  static void _bumpWatermark(DateTime serverTime) {
    final us = serverTime.toUtc().microsecondsSinceEpoch;
    if (us > _watermarkUs) {
      _watermarkUs = us;
      StorageService.setLastSyncWatermark(
        DateTime.fromMicrosecondsSinceEpoch(us, isUtc: true).toIso8601String(),
      );
    }
  }

  // ── Logging ────────────────────────────────────────────────────────────
  static void _log(String tag, Object error, StackTrace stack) {
    var what = error.runtimeType.toString();
    if (error is PostgrestException) {
      what = '$what(code: ${error.code}, message: ${error.message})';
    }
    // ignore: avoid_print
    print('[sync:$tag] $what\n$stack');
  }
}
