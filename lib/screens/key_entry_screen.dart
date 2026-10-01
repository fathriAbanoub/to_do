import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../constants.dart';
import '../services/crypto_service.dart';
import '../services/key_service.dart';
import '../services/sync_service.dart';

/// Recovery path: parses a user-typed 64-hex recovery key, verifies it
/// against the server canary and only then persists it. The raw input is
/// never echoed back — parse failures show a generic message (the input is
/// key material).
class KeyEntryScreen extends StatefulWidget {
  const KeyEntryScreen({
    super.key,
    required this.onKeyReady,
    required this.onBack,
  });

  /// Called with the master key after it verified against the server canary
  /// AND was persisted.
  final ValueChanged<Uint8List> onKeyReady;

  /// Returns to the key-creation screen.
  final VoidCallback onBack;

  @override
  State<KeyEntryScreen> createState() => _KeyEntryScreenState();
}

class _KeyEntryScreenState extends State<KeyEntryScreen> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Verify-before-save: parse (generic failure message — never the input),
  /// verify against the server canary, and only then KeyService.save. Every
  /// failure path leaves secure storage untouched.
  Future<void> _restore() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Uint8List masterKey;
      try {
        masterKey = CryptoService.parseRecoveryKey(_controller.text);
      } on FormatException {
        // Generic message on purpose: never echo the input, it is key
        // material.
        if (!mounted) return;
        setState(() => _error = kKeyEntryInvalidError);
        return;
      }
      final syncKey = (await CryptoService.deriveKeys(masterKey)).syncKey;
      final check = await SyncService.checkCanary(syncKey);
      if (!mounted) return;
      if (check == SyncKeyCheck.mismatch) {
        // Not the key the server canary was sealed with. Never store it.
        setState(() => _error = kKeyEntryMismatchError);
        return;
      }
      if (check == SyncKeyCheck.unavailable) {
        setState(() => _error = kKeyGateOfflineError);
        return;
      }
      try {
        await KeyService.save(masterKey);
      } catch (e) {
        // StateError (key already stored) or a storage-layer failure;
        // runtimeType only — the message could relate to key material.
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
    return Scaffold(
      appBar: AppBar(title: const Text(kKeyEntryTitle)),
      body: SingleChildScrollView(
        padding: kGatePadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _controller,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              // No maxLength on purpose: a paste carrying the whitespace or
              // hyphens that parseRecoveryKey strips must not be blocked by
              // the field before parsing sees it.
              autofocus: false,
              onSubmitted: (_) => _restore(),
              decoration: InputDecoration(
                labelText: kKeyEntryLabel,
                border: const OutlineInputBorder(),
                errorText: _error,
                errorMaxLines: kKeyEntryErrorMaxLines,
              ),
            ),
            const SizedBox(height: kGateGap),
            SizedBox(
              width: double.infinity,
              height: kGateButtonHeight,
              child: FilledButton(
                onPressed: _busy ? null : _restore,
                child: _busy
                    ? const SizedBox(
                        width: kGateSpinnerSize,
                        height: kGateSpinnerSize,
                        child: CircularProgressIndicator(
                          strokeWidth: kGateSpinnerStroke,
                        ),
                      )
                    : const Text(kKeyEntryButton),
              ),
            ),
            const SizedBox(height: kGateGap),
            TextButton(
              onPressed: _busy ? null : widget.onBack,
              child: const Text(kKeyEntryBackButton),
            ),
          ],
        ),
      ),
    );
  }
}
