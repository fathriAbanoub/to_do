// Pure-Dart crypto core for the local-first todo app.
//
// Constraints honored here:
//  - no Flutter imports and no constants.dart import (credentials stay out),
//    so the self-check runs under the plain dart VM:
//      dart --enable-asserts lib/services/crypto_service.dart
//  - all crypto constants live at the top of this file.
//
// Key hierarchy (fixed by the target architecture):
//   master key (32 random bytes, custody in KeyService)
//     |- HKDF-SHA256(info: local-db)     -> Hive AES cipher key
//     |- HKDF-SHA256(info: sync-payload) -> AES-256-GCM payload key
// The master key never goes to Supabase and is never derived from a
// password; the 64-hex recovery key is exactly the master key in hex.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:hive_ce/hive.dart' show Hive;

// ---------------------------------------------------------------------------
// Crypto constants.
// ---------------------------------------------------------------------------

/// AES-256 key size in bytes; the master key and both derived keys are
/// AES-256 keys, so all three share this length.
const int kAes256KeyLength = 32;

/// Master key length in bytes.
const int kMasterKeyLength = kAes256KeyLength;

/// Length of each HKDF-derived key in bytes.
const int kDerivedKeyLength = kAes256KeyLength;

/// Hex encoding parameters.
const int kHexRadix = 16;
const int kHexDigitsPerByte = 2;

/// Zero-padding digit for bytes that render as a single hex digit.
const String kHexPadDigit = '0';

/// A master key renders as / parses from exactly this many hex characters.
const int kRecoveryKeyHexLength = kMasterKeyLength * kHexDigitsPerByte;

/// hexDecode validates against this pattern BEFORE parsing, because
/// int.parse would otherwise accept leading signs and surrounding
/// whitespace ('-abc', ' 0a') that are not hex encodings.
final RegExp kHexDigitsPattern = RegExp(r'^[0-9a-fA-F]+$');

/// Characters parseRecoveryKey strips before the strict hex check: display
/// grouping a user may type, or that a password-manager paste may add.
final RegExp kRecoveryKeyStripPattern = RegExp(r'[\s-]');

/// Versioned envelope prefix for sealed payloads; Phase 3 swaps
/// sync_service.dart's _encode/_decode seam to this format.
const String kSealPrefix = 'enc1:';

/// Separator between kind and id inside the AAD string.
const String kSealSeparator = '|';

/// HKDF info constants. Distinct values force key separation between the
/// Hive cipher key and the payload key even though both derive from the
/// same master key. Bump a suffix only together with a migration.
const String kHkdfInfoLocalDb = 'todo.local-db.v1';
const String kHkdfInfoSyncPayload = 'todo.sync-payload.v1';

/// Canary row identity: sealed once at key adoption and verified by the
/// Phase 3 startup gate before the app touches encrypted data. 'meta' is
/// deliberately not one of the sync kinds (task/category).
const String kCanaryKind = 'meta';
const String kCanaryId = 'canary';
const String kCanaryPlaintext = 'todo-canary-v1';

// ---------------------------------------------------------------------------
// Shared helpers.
// ---------------------------------------------------------------------------

/// Byte comparison for the canary and the self-check; the compared values
/// are public, so early exit is fine.
bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Hex helpers (dart:convert has no hex codec; stdlib-only implementation).
// ---------------------------------------------------------------------------

/// Encodes [bytes] as lowercase hex, two digits per byte.
String hexEncode(List<int> bytes) => bytes
    .map(
      (byte) => byte
          .toRadixString(kHexRadix)
          .padLeft(kHexDigitsPerByte, kHexPadDigit),
    )
    .join();

/// Decodes an even-length run of hex digits.
///
/// Throws [FormatException] for anything else — odd length, empty input, or
/// any character outside the hex digits. The check runs before parsing
/// because int.parse accepts leading signs and surrounding whitespace that
/// are not hex encodings.
// ponytail: no `source` argument in these FormatExceptions on purpose — the
// source here is key material (a recovery key), and echoing it would risk
// leaking the master key into logs. Callers add their own context.
Uint8List hexDecode(String hex) {
  if (hex.length.isOdd || !kHexDigitsPattern.hasMatch(hex)) {
    throw FormatException('expected an even-length run of hex digits');
  }
  final bytes = Uint8List(hex.length ~/ kHexDigitsPerByte);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(
      hex.substring(kHexDigitsPerByte * i, kHexDigitsPerByte * (i + 1)),
      radix: kHexRadix,
    );
  }
  return bytes;
}

/// Crypto primitives used by later phases (payload sealing, key derivation).
/// Static-only; the single piece of state is the shared AES-GCM object.
class CryptoService {
  CryptoService._();

  static final AesGcm _aesGcm = AesGcm.with256bits();

  /// Nonce + GCM tag bytes inside the base64 part of a sealed payload.
  static int get _sealedOverhead =>
      _aesGcm.nonceLength + _aesGcm.macAlgorithm.macLength;

  /// Generates a fresh master key from a secure RNG.
  ///
  /// The caller must persist the result via KeyService.save — only AFTER the
  /// recovery key has been shown and the canary verified (Phase 3 gate) —
  /// and show hexEncode(key) as the one-time recovery key; a master key that
  /// is neither persisted nor recovered means losing every sealed row.
  static Uint8List generateMasterKey() {
    final key = Uint8List.fromList(Hive.generateSecureKey());
    assert(key.length == kMasterKeyLength);
    return key;
  }

  /// Parses a recovery key back into master key bytes.
  ///
  /// Whitespace and hyphens are stripped first (display grouping); then
  /// throws [FormatException] unless what remains is exactly
  /// [kRecoveryKeyHexLength] hex characters (case-insensitive). Any other
  /// character — including '+' — is rejected even at the right length.
  static Uint8List parseRecoveryKey(String recoveryKey) {
    final cleaned = recoveryKey.replaceAll(kRecoveryKeyStripPattern, '');
    final bytes = hexDecode(cleaned);
    if (bytes.length != kMasterKeyLength) {
      throw FormatException(
        'recovery key must be $kRecoveryKeyHexLength hex characters',
      );
    }
    return bytes;
  }

  /// Derives the two independent AES-256 keys from the master key via
  /// HKDF-SHA256. Deterministic: same master key in, same keys out.
  static Future<({SecretKey localDbKey, SecretKey syncKey})> deriveKeys(
    Uint8List masterKey,
  ) async {
    final master = SecretKey(masterKey);
    // ponytail: both HKDF calls below use the library default salt, which is
    // an empty salt; the two distinct info constants are what actually
    // separate the keys. A real salt only earns its keep with key rotation,
    // which is out of scope — upgrade path: store a random salt per key
    // generation and version it alongside the envelope prefix.
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: kDerivedKeyLength);
    final localDbKey = await hkdf.deriveKey(
      secretKey: master,
      info: utf8.encode(kHkdfInfoLocalDb),
    );
    final syncKey = await hkdf.deriveKey(
      secretKey: master,
      info: utf8.encode(kHkdfInfoSyncPayload),
    );
    return (localDbKey: localDbKey, syncKey: syncKey);
  }

  /// AAD binding: envelope format + row kind + row id. A ciphertext captured
  /// for one row cannot be replayed as another row, and a payload re-sealed
  /// under a different kind or id fails authentication.
  static List<int> _aad(String kind, String id) =>
      utf8.encode('$kSealPrefix$kind$kSealSeparator$id');

  /// Encrypts [plaintext] into `enc1:` + base64(nonce | ciphertext | tag),
  /// authenticated against AAD = prefix + kind + separator + id.
  ///
  /// The library generates a fresh random nonce on every call; callers must
  /// not pass one.
  static Future<String> seal(
    SecretKey key,
    List<int> plaintext, {
    required String kind,
    required String id,
  }) async {
    final secretBox = await _aesGcm.encrypt(
      plaintext,
      secretKey: key,
      aad: _aad(kind, id),
    );
    return '$kSealPrefix${base64Encode(secretBox.concatenation())}';
  }

  /// Opens a payload produced by [seal] and returns the plaintext bytes.
  ///
  /// Failure contract:
  ///  - structural garbage — unknown prefix, invalid base64, or fewer bytes
  ///    than nonce + tag — throws [FormatException];
  ///  - wrong key, or kind/id other than the ones the payload was sealed
  ///    with, fails GCM authentication and throws
  ///    [SecretBoxAuthenticationError]; the error is deliberately not
  ///    swallowed, because treating an unauthenticated payload as valid or
  ///    empty would corrupt or destroy data.
  static Future<Uint8List> open(
    SecretKey key,
    String sealed, {
    required String kind,
    required String id,
  }) async {
    if (!sealed.startsWith(kSealPrefix)) {
      throw FormatException('missing "$kSealPrefix" prefix', sealed);
    }
    final bytes = base64Decode(sealed.substring(kSealPrefix.length));
    if (bytes.length < _sealedOverhead) {
      throw FormatException(
        'sealed payload shorter than nonce + tag ($_sealedOverhead bytes)',
        sealed,
      );
    }
    final secretBox = SecretBox.fromConcatenation(
      bytes,
      nonceLength: _aesGcm.nonceLength,
      macLength: _aesGcm.macAlgorithm.macLength,
    );
    return Uint8List.fromList(
      await _aesGcm.decrypt(secretBox, secretKey: key, aad: _aad(kind, id)),
    );
  }

  /// Seals the fixed canary plaintext under the payload key.
  static Future<String> sealCanary(SecretKey key) => seal(
    key,
    utf8.encode(kCanaryPlaintext),
    kind: kCanaryKind,
    id: kCanaryId,
  );

  /// Verifies a canary produced by [sealCanary].
  ///
  /// Returns true only if [sealed] opens, under [key], to the exact canary
  /// plaintext. Null (no canary stored yet), structural garbage
  /// ([FormatException]) and authentication failure
  /// ([SecretBoxAuthenticationError]) all return false; anything else
  /// propagates. The Phase 3 startup gate must treat false as "do not touch
  /// encrypted data".
  static Future<bool> verifyCanary(SecretKey key, String? sealed) async {
    if (sealed == null) return false;
    try {
      final opened = await open(key, sealed, kind: kCanaryKind, id: kCanaryId);
      return _bytesEqual(opened, utf8.encode(kCanaryPlaintext));
    } on FormatException {
      return false;
    } on SecretBoxAuthenticationError {
      return false;
    }
  }
}

// ---------------------------------------------------------------------------
// Self-check (assert-based, no test framework). Fixture literals below are
// check-case data and stay inline on purpose.
// ---------------------------------------------------------------------------

const String kSelfCheckKind = 'task';
const String kSelfCheckOtherKind = 'other';
const String kSelfCheckId = 'self-check';
const String kSelfCheckPlaintext = 'self-check payload';

/// Half the recovery key, used to build the paste-split and the half-key
/// rejection fixtures.
const int kSelfCheckHalfKeyLength = kRecoveryKeyHexLength ~/ 2;

/// The mask that flips the lowest bit of a byte in the bit-flip fixture.
const int kBitFlipMask = 0x01;

/// Asserts that [run] threw exactly [type]. No-op when asserts are stripped,
/// which the guard in main() makes unreachable for this self-check.
Future<void> _expectThrow(
  FutureOr<void> Function() run,
  Type type,
  String what,
) async {
  Object? caught;
  try {
    await run();
  } catch (error) {
    caught = error;
  }
  assert(caught.runtimeType == type, '$what: expected $type, got $caught');
}

Future<void> main() async {
  // Fail loudly rather than printing "passed" with every assert stripped.
  var assertsEnabled = false;
  assert(() {
    assertsEnabled = true;
    return true;
  }());
  if (!assertsEnabled) {
    throw StateError(
      'self-check ran without asserts; use: '
      'dart --enable-asserts lib/services/crypto_service.dart',
    );
  }

  // Master key generation.
  final master = CryptoService.generateMasterKey();
  assert(master.length == kMasterKeyLength);
  final otherMaster = CryptoService.generateMasterKey();
  assert(!_bytesEqual(master, otherMaster)); // secure RNG sanity

  // Hex round trip.
  final recoveryKey = hexEncode(master);
  assert(recoveryKey.length == kRecoveryKeyHexLength);
  assert(_bytesEqual(CryptoService.parseRecoveryKey(recoveryKey), master));
  assert(
    _bytesEqual(
      CryptoService.parseRecoveryKey(recoveryKey.toUpperCase()),
      master,
    ),
  );

  // A pasted key with a stray newline (password-manager style) still parses.
  final pastedKey =
      '${recoveryKey.substring(0, kSelfCheckHalfKeyLength)}\n'
      '${recoveryKey.substring(kSelfCheckHalfKeyLength)}';
  assert(_bytesEqual(CryptoService.parseRecoveryKey(pastedKey), master));

  // parseRecoveryKey rejections: one char short, half a key, '+' at the
  // right length, empty string.
  await _expectThrow(
    () => CryptoService.parseRecoveryKey(
      recoveryKey.substring(0, kRecoveryKeyHexLength - 1),
    ),
    FormatException,
    'recovery key missing one character',
  );
  await _expectThrow(
    () => CryptoService.parseRecoveryKey(
      recoveryKey.substring(kSelfCheckHalfKeyLength),
    ),
    FormatException,
    'second half of recovery key only',
  );
  await _expectThrow(
    () =>
        CryptoService.parseRecoveryKey('a' * (kRecoveryKeyHexLength - 1) + '+'),
    FormatException,
    '64 characters containing +',
  );
  await _expectThrow(
    () => CryptoService.parseRecoveryKey(''),
    FormatException,
    'empty recovery key',
  );

  // hexDecode rejections: odd length, and a sign a naive int.parse accepts.
  await _expectThrow(() => hexDecode('abc'), FormatException, 'odd-length hex');
  await _expectThrow(
    () => hexDecode('-abc'),
    FormatException,
    'signed hex a naive int.parse would accept',
  );

  // Derived keys, deterministic through the recovery path: re-derive from
  // the recovery-key hex, exactly what a user-typed key does in Phase 3.
  final keys = await CryptoService.deriveKeys(master);
  final rederived = await CryptoService.deriveKeys(
    CryptoService.parseRecoveryKey(recoveryKey),
  );
  final plaintext = utf8.encode(kSelfCheckPlaintext);
  final originalSealed = await CryptoService.seal(
    keys.syncKey,
    plaintext,
    kind: kSelfCheckKind,
    id: kSelfCheckId,
  );
  final rederivedOpened = await CryptoService.open(
    rederived.syncKey,
    originalSealed,
    kind: kSelfCheckKind,
    id: kSelfCheckId,
  );
  assert(_bytesEqual(rederivedOpened, plaintext));

  // A different master key derives a different payload key.
  final otherKeys = await CryptoService.deriveKeys(otherMaster);
  await _expectThrow(
    () => CryptoService.open(
      otherKeys.syncKey,
      originalSealed,
      kind: kSelfCheckKind,
      id: kSelfCheckId,
    ),
    SecretBoxAuthenticationError,
    'payload sealed under another master key',
  );

  // Key separation: the local-db key must not open payload-key ciphertexts.
  final localDbSealed = await CryptoService.seal(
    keys.localDbKey,
    plaintext,
    kind: kSelfCheckKind,
    id: kSelfCheckId,
  );
  await _expectThrow(
    () => CryptoService.open(
      keys.syncKey,
      localDbSealed,
      kind: kSelfCheckKind,
      id: kSelfCheckId,
    ),
    SecretBoxAuthenticationError,
    'payload sealed with the local-db key',
  );

  // Seal/open round trip; every seal uses a fresh random nonce.
  final sealed = await CryptoService.seal(
    keys.syncKey,
    plaintext,
    kind: kSelfCheckKind,
    id: kSelfCheckId,
  );
  assert(sealed.startsWith(kSealPrefix));
  assert(sealed != originalSealed); // fresh nonce -> different bytes
  final reopened = await CryptoService.open(
    keys.syncKey,
    sealed,
    kind: kSelfCheckKind,
    id: kSelfCheckId,
  );
  assert(_bytesEqual(reopened, plaintext));

  // Failure contract, structural garbage -> FormatException.
  final raw = base64Decode(sealed.substring(kSealPrefix.length));
  final truncated = base64Encode(
    raw.sublist(0, CryptoService._sealedOverhead - 1),
  );
  await _expectThrow(
    () => CryptoService.open(
      keys.syncKey,
      '$kSealPrefix$truncated',
      kind: kSelfCheckKind,
      id: kSelfCheckId,
    ),
    FormatException,
    'truncated payload',
  );
  await _expectThrow(
    () => CryptoService.open(
      keys.syncKey,
      '$kSealPrefix!!!not-base64!!!',
      kind: kSelfCheckKind,
      id: kSelfCheckId,
    ),
    FormatException,
    'invalid base64',
  );
  await _expectThrow(
    () => CryptoService.open(
      keys.syncKey,
      'plain:123',
      kind: kSelfCheckKind,
      id: kSelfCheckId,
    ),
    FormatException,
    'wrong prefix',
  );

  // Failure contract, AAD binding -> SecretBoxAuthenticationError.
  await _expectThrow(
    () => CryptoService.open(
      keys.syncKey,
      sealed,
      kind: kSelfCheckKind,
      id: 'other-id',
    ),
    SecretBoxAuthenticationError,
    'wrong id (AAD mismatch)',
  );
  await _expectThrow(
    () => CryptoService.open(
      keys.syncKey,
      sealed,
      kind: kSelfCheckOtherKind,
      id: kSelfCheckId,
    ),
    SecretBoxAuthenticationError,
    'wrong kind (AAD mismatch)',
  );

  // Flipping one bit inside the ciphertext region must fail authentication;
  // the fixture plaintext is at least one byte, so index nonceLength is the
  // first ciphertext byte.
  final flipped = List<int>.of(raw);
  flipped[CryptoService._aesGcm.nonceLength] ^= kBitFlipMask;
  await _expectThrow(
    () => CryptoService.open(
      keys.syncKey,
      '$kSealPrefix${base64Encode(flipped)}',
      kind: kSelfCheckKind,
      id: kSelfCheckId,
    ),
    SecretBoxAuthenticationError,
    'flipped ciphertext bit',
  );

  // Canary round trip, including determinism through the recovery path.
  final canary = await CryptoService.sealCanary(keys.syncKey);
  final canaryOk = await CryptoService.verifyCanary(keys.syncKey, canary);
  assert(canaryOk);
  final rederivedCanaryOk = await CryptoService.verifyCanary(
    rederived.syncKey,
    canary,
  );
  assert(rederivedCanaryOk);
  final wrongKeyCanary = await CryptoService.verifyCanary(
    otherKeys.syncKey,
    canary,
  );
  assert(!wrongKeyCanary); // wrong key -> false, not a throw
  final garbageCanary = await CryptoService.verifyCanary(
    keys.syncKey,
    'plain:123',
  );
  assert(!garbageCanary); // structural garbage -> false, not a throw
  final nullCanary = await CryptoService.verifyCanary(keys.syncKey, null);
  assert(!nullCanary); // no canary stored yet -> false, not a throw

  // ignore: avoid_print
  print('crypto_service self-check passed');
}
