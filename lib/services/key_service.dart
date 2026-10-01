// Master key custody: the ONLY place the master key touches disk.
//
// Policy (fixed by the target architecture):
//  - the master key lives exclusively in flutter_secure_storage (Android
//    Keystore / Linux Secret Service); there is NO plaintext-file fallback,
//    ever — a missing or failing keyring must surface as an error instead;
//  - the master key is never sent to Supabase and never derived from a
//    password;
//  - the stored form is the 64-hex recovery key, so the string shown once
//    to the user is byte-identical to what is stored;
//  - nothing is persisted until the Phase 3 gate has generated the key in
//    memory, shown the recovery key and verified the canary — or until the
//    key-entry flow has parsed a user-typed recovery key.

import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'crypto_service.dart';

/// Secure-storage key under which the recovery key (64-hex master key) is
/// stored.
const String kMasterKeyStorageName = 'todo.master_key';

class KeyService {
  KeyService._();

  // resetOnError defaults to true, which PERMANENTLY erases stored data on a
  // keystore error, after which a read looks like "no key" (first run). A
  // master key must fail loudly instead.
  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );

  /// Reads the stored master key.
  ///
  /// Returns null when no key exists yet (first run) — callers can
  /// distinguish "absent" from "corrupt": a stored value that is not a valid
  /// recovery key throws [FormatException] instead of returning null, so
  /// corruption can never be mistaken for first run.
  static Future<Uint8List?> load() async {
    final stored = await _storage.read(key: kMasterKeyStorageName);
    if (stored == null) return null;
    return CryptoService.parseRecoveryKey(stored);
  }

  /// Persists the master key bytes as the recovery key hex.
  ///
  /// Throws [StateError] when a key already exists — an existing key is
  /// never overwritten, because swapping the key under already-encrypted
  /// data destroys that data. Also throws [StateError] for a wrong-length
  /// key: storing anything that is not a [kMasterKeyLength]-byte master key
  /// would make encrypted data unrecoverable later.
  static Future<void> save(List<int> bytes) async {
    if (bytes.length != kMasterKeyLength) {
      throw StateError(
        'refusing to store a ${bytes.length}-byte key '
        '(expected $kMasterKeyLength)',
      );
    }
    if (await _storage.containsKey(key: kMasterKeyStorageName)) {
      throw StateError('master key already exists; refusing to overwrite');
    }
    // ponytail: contains-then-write is not atomic and the plugin offers no
    // compare-and-set; both callers (Phase 3 gate, key-entry flow) are
    // user-driven and sequential. Upgrade path: serialize through an
    // in-memory guard if a second caller ever appears.
    await _storage.write(key: kMasterKeyStorageName, value: hexEncode(bytes));
  }
}
