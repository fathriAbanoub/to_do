import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants.dart';
import '../services/crypto_service.dart';
import '../services/key_service.dart';
import '../services/sync_service.dart';

/// First adoption: generates the master key in memory, shows the 64-hex
/// recovery key exactly once, and only after the user confirms it is saved
/// verifies the key against the server canary and persists it — in that
/// order. Nothing touches KeyService.save before the canary check, so a
/// device that loses the adoption race (another device on the same account
/// already adopted a key) never ends up with a stored-but-useless key.
class KeySetupScreen extends StatefulWidget {
  const KeySetupScreen({
    super.key,
    required this.onKeyReady,
    required this.onUseRecoveryKey,
  });

  /// Called with the master key after it verified against the server canary
  /// AND was persisted.
  final ValueChanged<Uint8List> onKeyReady;

  /// Switches the gate to the recovery-key entry screen.
  final VoidCallback onUseRecoveryKey;

  @override
  State<KeySetupScreen> createState() => _KeySetupScreenState();
}

class _KeySetupScreenState extends State<KeySetupScreen> {
  Uint8List? _masterKey;
  bool _confirmedSaved = false;
  bool _busy = false;
  String? _error;

  void _createKey() {
    setState(() {
      _masterKey = CryptoService.generateMasterKey();
      _confirmedSaved = false;
      _error = null;
    });
  }

  Future<void> _copyRecoveryKey() async {
    final masterKey = _masterKey;
    if (masterKey == null) return;
    await Clipboard.setData(ClipboardData(text: hexEncode(masterKey)));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(kRecoveryKeyCopiedText),
        duration: kSnackbarDuration,
      ),
    );
  }

  /// Verify-before-save: the canary check runs against the server BEFORE
  /// KeyService.save, and only a verified key is stored. Every failure path
  /// leaves secure storage untouched.
  Future<void> _continue() async {
    final masterKey = _masterKey;
    if (masterKey == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final syncKey = (await CryptoService.deriveKeys(masterKey)).syncKey;
      final check = await SyncService.checkCanary(syncKey);
      if (!mounted) return;

      if (check == SyncKeyCheck.mismatch) {
        // The server already carries a canary sealed under a different key
        // for this user (another device on this account, or an earlier
        // adoption whose local save never happened). Never overwrite,
        // never store this key.
        setState(() => _error = kKeySetupAlreadyActiveError);
        return;
      }
      if (check == SyncKeyCheck.unavailable) {
        setState(() => _error = kKeyGateOfflineError);
        return;
      }

      try {
        await KeyService.save(masterKey);
      } catch (e) {
        debugPrint('key save failed: ${e.runtimeType}');
        if (mounted) setState(() => _error = kKeyGateStoredError);
        return;
      }
      widget.onKeyReady(masterKey);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final masterKey = _masterKey;
    return Scaffold(
      appBar: AppBar(title: const Text(kKeySetupTitle)),
      body: SingleChildScrollView(
        padding: kGatePadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(kKeySetupExplain),
            const SizedBox(height: kGateGap),
            if (masterKey == null)
              FilledButton(
                onPressed: _busy ? null : _createKey,
                child: const Text(kKeySetupCreateButton),
              )
            else ...[
              Text(
                kKeySetupWarning,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: kGateGap),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: SelectableText(
                      hexEncode(masterKey),
                      style: const TextStyle(
                        fontFamily: kRecoveryKeyFontFamily,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _busy ? null : _copyRecoveryKey,
                    tooltip: kRecoveryKeyCopyTooltip,
                    icon: const Icon(Icons.copy),
                  ),
                ],
              ),
              CheckboxListTile(
                value: _confirmedSaved,
                onChanged: _busy
                    ? null
                    : (saved) =>
                          setState(() => _confirmedSaved = saved ?? false),
                title: const Text(kKeySetupSavedLabel),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const SizedBox(height: kGateGap),
              SizedBox(
                width: double.infinity,
                height: kGateButtonHeight,
                child: FilledButton(
                  onPressed: _confirmedSaved && !_busy ? _continue : null,
                  child: _busy
                      ? const SizedBox(
                          width: kGateSpinnerSize,
                          height: kGateSpinnerSize,
                          child: CircularProgressIndicator(
                            strokeWidth: kGateSpinnerStroke,
                          ),
                        )
                      : const Text(kKeySetupContinueButton),
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: kGateGap),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: kGateGap),
            TextButton(
              onPressed: _busy ? null : widget.onUseRecoveryKey,
              child: const Text(kKeySetupHaveKeyButton),
            ),
          ],
        ),
      ),
    );
  }
}
