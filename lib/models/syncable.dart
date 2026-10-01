import 'package:hive_ce/hive.dart';

/// Minimal contract shared by every sync-eligible Hive model.
///
/// Two independent flags, two independent meanings:
///  - [isDirty]   — the row has local changes the sync engine has not yet
///                  pushed. Set by every mutation; cleared by [SyncService]
///                  after a successful upsert (or by the schema-version
///                  migration for pre-existing rows on first launch after
///                  the soft-delete upgrade).
///  - [isDeleted] — a soft-delete tombstone. The row stays in the box (so
///                  the deletion itself can be pushed, and so UNDO has
///                  something to flip back) until [StorageService.purgeDeleted]
///                  hard-removes it on the next startup, once the push has
///                  confirmed the server saw the tombstone.
///
/// Applying this mixin to a model is the ONLY way to participate in sync;
/// the storage service refuses to mutate a row without routing through
/// `_saveDirty` / `_softDelete`, which is what guarantees every change
/// reaches the outbox.
mixin Syncable on HiveObject {
  bool get isDirty;
  set isDirty(bool value);
  bool get isDeleted;
  set isDeleted(bool value);
}
