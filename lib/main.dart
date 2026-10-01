import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:hive_ce/hive.dart' show HiveAesCipher;
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

import 'constants.dart';
import 'hive_registrar.g.dart';
import 'screens/key_entry_screen.dart';
import 'screens/key_setup_screen.dart';
import 'screens/login_screen.dart';
import 'screens/task_screen.dart';
import 'services/crypto_service.dart';
import 'services/key_service.dart';
import 'services/storage_service.dart';
import 'services/sync_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  Hive.registerAdapters();

  // Checkbox dings are short UI sounds, not media playback: skip the
  // OS audio-focus handshake entirely. See the previous version for the
  // full MIUI rationale.
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS)) {
    await AudioPlayer.global.setAudioContext(
      AudioContextConfig(focus: AudioContextConfigFocus.mixWithOthers).build(),
    );
  }

  if (SyncService.enabled) {
    await Supabase.initialize(url: kSupabaseUrl, anonKey: kSupabaseAnonKey);
  }

  runApp(const ToDoApp());
}

class ToDoApp extends StatefulWidget {
  const ToDoApp({super.key});

  @override
  State<ToDoApp> createState() => _ToDoAppState();
}

class _ToDoAppState extends State<ToDoApp> {
  bool get _signedIn =>
      SyncService.enabled && Supabase.instance.client.auth.currentUser != null;

  Uint8List? _masterKey;
  SecretKey? _syncKey;
  bool _keyLoaded = false;
  bool _keyLoadFailed = false;
  bool _initFailed = false;
  bool _keyEntryMode = false;

  Future<void> _syncLifecycle() async {
    if (!_signedIn) {
      await SyncService.stop();
      return;
    }
    final syncKey = _syncKey;
    if (syncKey == null) return;
    await SyncService.start(syncKey: syncKey);
  }

  @override
  void initState() {
    super.initState();
    if (SyncService.enabled) {
      Supabase.instance.client.auth.onAuthStateChange.listen((_) {
        if (mounted) setState(() {});
        _syncLifecycle();
      });
    }
    _loadMasterKey();
  }

  Future<void> _loadMasterKey() async {
    Uint8List? masterKey;
    var failed = false;
    try {
      masterKey = await KeyService.load();
      if (masterKey == null && !SyncService.enabled) {
        masterKey = CryptoService.generateMasterKey();
        await KeyService.save(masterKey);
      }
    } catch (e) {
      failed = true;
      debugPrint('master key custody failed: ${e.runtimeType}');
    }
    if (!mounted) return;
    if (failed || masterKey == null) {
      setState(() {
        _keyLoaded = true;
        _keyLoadFailed = failed;
      });
      return;
    }
    await _adoptMasterKey(masterKey);
  }

  Future<void> _adoptMasterKey(Uint8List masterKey) async {
    final keys = await CryptoService.deriveKeys(masterKey);
    final cipher = HiveAesCipher(await keys.localDbKey.extractBytes());
    try {
      await StorageService.init(cipher);
      // Purge hard-deleted rows from disk once per launch. Safe here
      // because no UI is mounted, no snackbar is in flight, and no
      // gesture is mid-edit — the 3.5s undo window (kSnackbarDuration)
      // belongs to a session that has not started yet.
      unawaited(StorageService.purgeDeleted());
    } catch (e) {
      debugPrint('storage init failed: ${e.runtimeType}');
      if (!mounted) return;
      setState(() {
        _keyLoaded = true;
        _initFailed = true;
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _keyLoaded = true;
      _masterKey = masterKey;
      _syncKey = keys.syncKey;
    });
    await _syncLifecycle();
  }

  Future<void> _onGateKeyReady(Uint8List masterKey) async {
    setState(() => _keyEntryMode = false);
    await _adoptMasterKey(masterKey);
  }

  Future<void> _retryKeyLoad() async {
    setState(() {
      _keyLoaded = false;
      _keyLoadFailed = false;
    });
    await _loadMasterKey();
  }

  Future<void> _confirmReset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text(kResetConfirmTitle),
        content: const Text(kResetConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text(kResetCancelButton),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text(kResetConfirmButton),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await StorageService.resetLocalData();
    } catch (e) {
      debugPrint('local data reset failed: ${e.runtimeType}');
      return;
    }
    if (!mounted) return;
    setState(() {
      _initFailed = false;
      _keyLoaded = false;
    });
    await _loadMasterKey();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: kAppTitle,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: kCategoryPalette.first,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
      ),
      home: _home(),
    );
  }

  Widget _home() {
    if (_keyLoadFailed) return _keyLoadErrorHome();
    if (_initFailed) return _initErrorHome();
    if (!_keyLoaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!SyncService.enabled) return _taskHome();
    if (!_signedIn) return const LoginScreen();
    if (_masterKey == null) {
      return _keyEntryMode
          ? KeyEntryScreen(
              onKeyReady: _onGateKeyReady,
              onBack: () => setState(() => _keyEntryMode = false),
            )
          : KeySetupScreen(
              onKeyReady: _onGateKeyReady,
              onUseRecoveryKey: () => setState(() => _keyEntryMode = true),
            );
    }
    return _taskHome();
  }

  Widget _blockingHome(
    String message,
    String actionLabel,
    VoidCallback action,
  ) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: kGatePadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: kGateGap),
              FilledButton(onPressed: action, child: Text(actionLabel)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _keyLoadErrorHome() =>
      _blockingHome(kKeyGateLoadError, kKeyGateRetryButton, _retryKeyLoad);

  Widget _initErrorHome() =>
      _blockingHome(kInitErrorMessage, kInitErrorResetButton, _confirmReset);

  Widget _taskHome() {
    return Column(
      children: [
        Expanded(
          child: TaskScreen(categoryId: StorageService.getInitialCategoryId()),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: SyncService.keyMismatch,
          builder: (context, mismatch, _) =>
              mismatch ? const _KeyMismatchBanner() : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class _KeyMismatchBanner extends StatelessWidget {
  const _KeyMismatchBanner();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.errorContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(kGateGap),
          child: Row(
            children: [
              Icon(Icons.sync_problem, color: colors.onErrorContainer),
              const SizedBox(width: kGateGap),
              Expanded(
                child: Text(
                  kKeyMismatchBannerText,
                  style: TextStyle(color: colors.onErrorContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
