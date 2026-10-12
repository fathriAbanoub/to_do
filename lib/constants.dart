import 'package:flutter/material.dart';

// ── App identity ────────────────────────────────────────────────────────────
/// MaterialApp title — shown by the OS in the app switcher.
const kAppTitle = 'Todo';

// ── Timing ──────────────────────────────────────────────────────────────────
const kSnackbarDuration = Duration(milliseconds: 3500);
const kAnimationDuration = Duration(milliseconds: 250);
const kFastAnimationDuration = Duration(milliseconds: 150);

// ── Task tile entry/exit animation ─────────────────────────────────────────
/// Scale a task tile animates from when fading/scaling in on insert — and
/// back down to, while fading out, on delete.
const kTileEntryMinScale = 0.75;

// ── Swipe ───────────────────────────────────────────────────────────────────
/// Fraction of row width at which swipe commits.
const kSwipeThreshold = 0.3;

// ── Navigation gestures ────────────────────────────────────────────────────
/// Width of the invisible edge strips that navigate between screens:
/// left edge drag right opens Categories; right edge drag left pops back.
///
/// NOTE: reserves the first [kEdgeSwipeWidth] physical pixels on each side
/// for navigation. Shrink or move to Drawer if it ever blocks edge controls.
const kEdgeSwipeWidth = 16.0;

/// How far an edge drag must travel before it navigates.
const kEdgeSwipeDistance = 64.0;

// ── Hive ────────────────────────────────────────────────────────────────────
const kTaskBoxName = 'tasks_enc';
const kCategoryBoxName = 'categories_enc';
const kLegacyTaskBoxName = 'tasks';
const kLegacyCategoryBoxName = 'categories';
const kSettingsBoxName = 'settings';
const kTaskTypeId = 0;
const kCategoryTypeId = 1;

const kLastCategoryIdKey = 'lastCategoryId';
const kLegacyMigrationDoneKey = 'legacyMigrationDone';

// ── Default category ───────────────────────────────────────────────────────
const kQuickTasksCategoryId = 'quick-tasks';
const kQuickTasksCategoryName = 'Quick Tasks';
const kDefaultCategoryColorValue = 0xFF1565C0; // Material Blue 800

// ── Category color palette ─────────────────────────────────────────────────
const kCategoryPalette = <Color>[
  Color(0xFF1565C0), // Blue
  Color(0xFF2E7D32), // Green
  Color(0xFFC62828), // Red
  Color(0xFF6A1B9A), // Purple
  Color(0xFFEF6C00), // Orange
  Color(0xFF00838F), // Teal
  Color(0xFF4E342E), // Brown
  Color(0xFF37474F), // Blue Grey
  Color(0xFFAD1457), // Pink
  Color(0xFF558B2F), // Light Green
];

// ── Category color picker ──────────────────────────────────────────────────
const kColorPanelHeight = 200.0;
const kHueBarHeight = 16.0;
const kColorThumbSize = 20.0;

// ── Completed section ───────────────────────────────────────────────────────
const kCompletedHeaderText = 'Completed';
const kCompletedOpacity = 0.5;

// ── Empty state ─────────────────────────────────────────────────────────────
const kEmptyStateTitle = 'No tasks yet';
const kEmptyStateSubtitle = 'Tap + to add your first task';

// ── Task tile ───────────────────────────────────────────────────────────────
/// Max visible lines of a task title. Longer titles ellipsize; tapping the
/// row opens a bottom sheet with the full title.
const kTaskTitleMaxLines = 2;

/// Max visible lines for a task title that contains newlines (a pasted
/// multi-line list). Single-line titles keep [kTaskTitleMaxLines] so normal
/// tasks stay compact; multi-line lists expand so the user can read them
/// without opening the edit sheet.
const kTaskTitleMultilineMaxLines = 8;

// ── Quick-add bar ─────────────────────────────────────────────────────────
/// Placeholder shown in the persistent quick-add bar's TextField.
const kQuickAddHint = 'Add a task';

// ── Supabase sync ───────────────────────────────────────────────────────────
// Read from --dart-define or --dart-define-from-file=secrets.json at compile time.
// Empty strings gracefully disable sync (local-only mode).
const kSupabaseUrl = String.fromEnvironment('SUPABASE_URL');
const kSupabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
const kSyncPollInterval = Duration(seconds: 15);
const kSyncPushDebounce = Duration(milliseconds: 600);

const kSupabaseItemsTable = 'items';
const kSyncKindTask = 'task';
const kSyncKindCategory = 'category';

const kLastSyncWatermarkKey = 'lastSyncWatermark';
const kSettingsMarkerValue = '1';

/// Watermark meaning "nothing pulled yet" — a full pull from the beginning.
const kEpochWatermark = '1970-01-01T00:00:00.000Z';

/// Set once a device has uploaded its pre-sync backlog.
/// Bumped to '.enc1' to force a one-time re-upload when payload encryption
/// was introduced. Bump again if the payload format changes.
const kInitialPushDoneKey = 'initialPushDone.enc1';

// ── Encryption key gate ────────────────────────────────────────────────────
const kGatePadding = EdgeInsets.all(32);
const kGateGap = 16.0;
const kGateButtonHeight = 48.0;
const kGateSpinnerSize = 20.0;
const kGateSpinnerStroke = 2.0;
const kKeyEntryErrorMaxLines = 3;
const kRecoveryKeyFontFamily = 'monospace';

const kKeySetupTitle = 'Set up encryption';
const kKeySetupExplain =
    'Your tasks are encrypted before they sync. Create an encryption key, save the recovery key somewhere safe, and you can restore your data on any device.';
const kKeySetupCreateButton = 'Create encryption key';
const kKeySetupWarning =
    'Write this recovery key down and keep it safe. It is shown only once — without it, your encrypted data cannot be restored on a new device.';
const kKeySetupSavedLabel = 'I saved my recovery key';
const kKeySetupContinueButton = 'Continue';
const kKeySetupHaveKeyButton = 'I already have a recovery key';
const kKeySetupAlreadyActiveError =
    'A different encryption key is already active on the server. Restore with your recovery key instead.';

const kKeyEntryTitle = 'Restore with recovery key';
const kKeyEntryLabel = 'Recovery key';
const kKeyEntryButton = 'Restore';
const kKeyEntryBackButton = 'Back to key creation';
const kKeyEntryInvalidError =
    'That is not a valid recovery key. It must be 64 hex characters (0-9, a-f).';
const kKeyEntryMismatchError =
    'This recovery key does not match the encryption key active on the server.';

const kRecoveryKeyCopyTooltip = 'Copy recovery key';
const kRecoveryKeyCopiedText = 'Recovery key copied to the clipboard';
const kKeyGateOfflineError =
    'Could not reach the server. Check your connection and try again.';
const kKeyGateStoredError =
    'Could not store the encryption key securely. Nothing was changed — please try again.';
const kKeyGateLoadError =
    'The saved encryption key could not be read. Your tasks are still on this device; sync stays off until the key is available.';
const kKeyGateRetryButton = 'Retry';

const kKeyMismatchBannerText =
    'Sync is paused: the encryption key does not match the server. Your tasks on this device are unaffected.';

// ── Storage init failure / reset ───────────────────────────────────────────
const kInitErrorMessage =
    'Local data could not be opened. The encryption key may have changed, '
    'or the data on this device is damaged.';
const kInitErrorResetButton = 'Reset local data and re-sync';
const kResetConfirmTitle = 'Reset local data?';
const kResetConfirmBody =
    'Unsynced edits on this device will be lost. This cannot be undone.';
const kResetCancelButton = 'Cancel';
const kResetConfirmButton = 'Reset';

// ── Celebration ────────────────────────────────────────────────────────────
const kCheckSoundAsset = 'sounds/check.mp3';

/// Two AudioPlayer instances so consecutive taps land on different players
/// and don't race Android's reset→prepare→start sequence.
const kSoundPoolSize = 2;

/// Confetti fires on the toggle that leaves the current category with zero
/// active tasks.
const kConfettiParticles = 40;
const kConfettiBurstDuration = Duration(seconds: 1);

// ── Greeting ───────────────────────────────────────────────────────────────
const kGreetingVisibleDuration = Duration(seconds: 6);

/// Placeholder replaced with the user's name at runtime.
const kGreetingNamePlaceholder = '{name}';

const kGreetingMorningNamed = [
  'Good morning, {name}',
  'Morning, {name}',
  'Hey {name}',
  'Rise and shine, {name}',
];
const kGreetingMorningUnnamed = ['Good morning', 'Morning', 'Hey, early bird'];
const kGreetingAfternoonNamed = [
  'Good afternoon, {name}',
  'Afternoon, {name}',
  'Hey {name}',
  'Hi {name}',
];
const kGreetingAfternoonUnnamed = ['Good afternoon', 'Afternoon', 'Hey there'];
const kGreetingEveningNamed = [
  'Good evening, {name}',
  'Evening, {name}',
  'Hey {name}',
  'Hi {name}',
];
const kGreetingEveningUnnamed = ['Good evening', 'Evening', 'Hey'];
const kGreetingNightOwlNamed = [
  'Still up, {name}?',
  'Hello {name}',
  'Hey {name}',
  'Burning the midnight oil, {name}?',
];
const kGreetingNightOwlUnnamed = [
  'Still up?',
  'Hello, night owl',
  'Burning the midnight oil',
];

const kUserNameKey = 'userName';
const kNameDialogTitle = 'What should we call you?';
const kNameDialogHint = 'Your name';
const kNameDialogSave = 'SAVE';
const kNameDialogSkip = 'SKIP';

// ── Schema version / soft-delete migration ─────────────────────────────────
/// Written to the settings box on the first launch after the soft-delete
/// upgrade. StorageService.init clears false-positive `isDirty` flags that
/// Hive's constructor defaults produce for pre-existing rows, but only if
/// the device has already completed its initial push.
///
/// MUST run before `_migrateLegacyBoxes`: rows created by the legacy
/// migration need to stay dirty so they get sealed and pushed.
const kSchemaVersionKey = 'schemaVersion';
const kSchemaVersionSoftDeletes = '2';
