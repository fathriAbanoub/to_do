import 'dart:async';
import 'dart:math' show pi, Random;

import 'package:audioplayers/audioplayers.dart';
import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

import '../constants.dart';
import '../models/category.dart';
import '../models/task.dart';
import '../services/storage_service.dart';
import '../widgets/add_task_dialog.dart';
import '../widgets/task_tile.dart';
import 'category_screen.dart';

// ── Celebration & greeting helpers (tested in test/celebration_test.dart) ───

/// Time-of-day greeting. 22:00–04:59 are night-owl hours. An empty name
/// counts as none (SKIP stores ''), so the unnamed variants are used in
/// that case too. `random` is injectable so tests can pass a seeded Random
/// and assert a specific pick; real callers omit it and get a different
/// combination most launches.
///
/// The named and unnamed variants are separate lists on purpose: a name
/// grafted onto an unnamed greeting with a comma produces "Hello, night
/// owl, Bob" — two greetings stapled together. Picking from the right list
/// first means every output reads like one sentence.
String greetingFor(int hour, String? name, {Random? random}) {
  final rng = random ?? Random();
  final hasName = name != null && name.isNotEmpty;

  final List<String> variants;
  if (hour >= 22 || hour < 5) {
    variants = hasName ? kGreetingNightOwlNamed : kGreetingNightOwlUnnamed;
  } else if (hour < 12) {
    variants = hasName ? kGreetingMorningNamed : kGreetingMorningUnnamed;
  } else if (hour < 17) {
    variants = hasName ? kGreetingAfternoonNamed : kGreetingAfternoonUnnamed;
  } else {
    variants = hasName ? kGreetingEveningNamed : kGreetingEveningUnnamed;
  }

  final pick = variants[rng.nextInt(variants.length)];
  return hasName ? pick.replaceAll(kGreetingNamePlaceholder, name) : pick;
}

/// Round-robin cursor for [_SoundPool]. Top-level (not a closure or a
/// private method) so it can be exercised by a plain unit test alongside
/// the other pure helpers in this file.
int _nextIndex(int current, int size) => (current + 1) % size;

class TaskScreen extends StatefulWidget {
  final String categoryId;

  const TaskScreen({super.key, required this.categoryId});

  @override
  State<TaskScreen> createState() => _TaskScreenState();
}

class _TaskScreenState extends State<TaskScreen> {
  late String _currentCategoryId;

  // Task ids currently animating out after a delete.
  final Set<String> _removingTaskIds = {};

  // Task ids added this session that should play the entry animation.
  // Invariant: a flag lives exactly one kFastAnimationDuration — just long
  // enough for the new tile's first build to catch it — so re-entering a
  // category or reopening the app never replays the animation for
  // pre-existing tasks.
  final Set<String> _justAddedTaskIds = {};

  /// Accumulated horizontal drag distance from the left-edge strip. Reset on
  /// gesture start and after every end/cancel.
  double _edgeDragDx = 0;

  // One pool per sound. The pool holds kSoundPoolSize independent
  // AudioPlayers and rotates through them, so two consecutive checks land
  // on two different instances — no single player is ever asked to start a
  // second play() before its previous reset -> prepare -> start cycle has
  // settled. That racing was the "1st tap plays, 2nd doesn't, 3rd sometimes
  // does" bug: audioplayers' MediaPlayer path re-runs the whole prepare on
  // every play(), and a second call mid-sequence is sometimes dropped
  // silently.
  //
  // PlayerMode.lowLatency is deliberately NOT used: on Android it hits an
  // open audioplayers bug where a reused player plays once and then goes
  // silent (github.com/luanpotter/audioplayers/issues/1193, #1176). Default
  // mediaPlayer mode + a preloaded source + the focus:none AudioContext in
  // main.dart gets the same "no delay" result without touching the buggy path.
  final _SoundPool _checkPool = _SoundPool(kCheckSoundAsset);

  final ConfettiController _confettiController = ConfettiController(
    duration: kConfettiBurstDuration,
  );

  // ── Greeting state ───────────────────────────────────────────────────
  bool _showGreeting = false;
  Timer? _greetingTimer;

  // Computed once in _bootGreeting so the debug log and the on-screen text
  // can never disagree across an hour boundary; build() reads this field,
  // it does not recompute.
  String _greetingText = '';

  @override
  void initState() {
    super.initState();
    _currentCategoryId = widget.categoryId;

    // Preload and greeting both wait for the first frame. The preload is
    // kSoundPoolSize native setSource round-trips; the greeting needs a
    // mounted context for its dialog. Running either from initState would
    // put them in direct competition with first paint. Preload stays
    // fire-and-forget: _SoundPool.play() falls back to load-on-demand, and
    // swallows asset errors so a bad file can never break a check-in.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_checkPool.preload());
      _bootGreeting();
    });
  }

  @override
  void dispose() {
    _greetingTimer?.cancel();
    _checkPool.dispose();
    _confettiController.dispose();
    super.dispose();
  }

  /// Ask the name once (first launch), then show the greeting until the
  /// fade timer fires.
  Future<void> _bootGreeting() async {
    if (!mounted) return;
    await _ensureUserName();
    if (!mounted) return;

    _greetingText = greetingFor(
      DateTime.now().hour,
      StorageService.getUserName(),
    );
    debugPrint('SHOWING GREETING: $_greetingText');
    setState(() => _showGreeting = true);

    _greetingTimer = Timer(kGreetingVisibleDuration, () {
      if (mounted) setState(() => _showGreeting = false);
    });
  }

  /// One-shot name prompt. The settings key is tri-state: null = never
  /// asked, '' = skipped (or saved empty), otherwise the display name.
  // No TextEditingController on purpose: showDialog's future completes when
  // the pop STARTS, not when the exit animation ends, so disposing a
  // controller here hits a still-mounted TextField and corrupts the element
  // teardown (_dependents.isEmpty assertion). onChanged leaves nothing to dispose.
  Future<void> _ensureUserName() async {
    if (StorageService.getUserName() != null) return;
    String entered = '';

    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => Theme(
        data: _categoryTheme(dialogContext),
        child: AlertDialog(
          title: const Text(kNameDialogTitle),
          content: TextField(
            autofocus: true,
            textInputAction: TextInputAction.done,
            onChanged: (value) => entered = value.trim(),
            onSubmitted: (_) => Navigator.of(dialogContext).pop(entered),
            decoration: const InputDecoration(hintText: kNameDialogHint),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text(kNameDialogSkip),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(entered),
              child: const Text(kNameDialogSave),
            ),
          ],
        ),
      ),
    );
    await StorageService.setUserName(name ?? '');
  }

  /// Single choke point for checkbox taps AND swipe-complete. Fires the
  /// check sound on every completion, and confetti when the toggle left
  /// the category with zero active tasks — the "list cleared" moment.
  Future<void> _onToggle(Task task) async {
    final completing = !task.completed;
    await StorageService.toggleTaskCompleted(task);
    if (!completing) return; // Unchecking gets neither sound nor confetti.

    // Read the split AFTER the toggle: the task just completed is now in
    // the completed list, so an empty active list with a non-empty
    // completed list means this tap cleared the last one.
    final split = StorageService.getTasksSplit(_currentCategoryId);
    final clearedList = split.active.isEmpty && split.completed.isNotEmpty;
    if (clearedList) _confettiController.play();

    // Sound is fire-and-forget for the caller but awaited here so a bad
    // asset cannot leave an unhandled rejection dangling; _SoundPool.play
    // swallows the failure internally.
    await _checkPool.play();
  }

  /// Opens the Categories screen and, if the user picked one, switches the
  /// task list to it and persists the choice for the next launch. Shared by
  /// the Categories FAB and the left-edge drag handler.
  Future<void> _openCategories() async {
    final selectedCategoryId = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const CategoryScreen()));

    if (!mounted || selectedCategoryId == null) return;

    setState(() {
      _currentCategoryId = selectedCategoryId;
    });

    await StorageService.setLastSelectedCategoryId(selectedCategoryId);
  }

  /// Seeded with the current category's color so every M3 accent below the
  /// Scaffold (checkboxes, text-field focus, filled buttons, radios, reorder
  /// handles) follows the category instead of the app's blue seed.
  // NOTE: Routes that mount ABOVE this wrapper cannot inherit it — dialogs
  // (root navigator), snackbars (ScaffoldMessenger), popup menu (overlay).
  // Dialogs and snackbars get the scheme handed to them explicitly below;
  // the popup menu stays app-neutral on purpose.
  ThemeData _categoryTheme(BuildContext context) => Theme.of(context).copyWith(
    colorScheme: ColorScheme.fromSeed(
      seedColor: Color(
        StorageService.getCategory(_currentCategoryId)?.colorValue ??
            kDefaultCategoryColorValue,
      ),
      brightness: Brightness.light,
    ),
  );

  void _showSnackbar(String message, {VoidCallback? onUndo}) {
    // SnackBar mounts on the ScaffoldMessenger, above the Theme wrapper, so
    // it gets the category color handed to it explicitly.
    final colorValue =
        StorageService.getCategory(_currentCategoryId)?.colorValue ??
        kDefaultCategoryColorValue;

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Color(colorValue),
        duration: kSnackbarDuration,
        action: onUndo != null
            ? SnackBarAction(
                label: 'UNDO',
                textColor: Colors.white,
                onPressed: onUndo,
              )
            : null,
      ),
    );
  }

  Future<void> _addTask() async {
    while (true) {
      if (!mounted) break;
      final title = await showDialog<String>(
        context: context,
        builder: (dialogContext) => Theme(
          data: _categoryTheme(dialogContext),
          child: const AddTaskDialog(),
        ),
      );
      if (title == null || title.isEmpty || !mounted) break;

      final task = await StorageService.addTask(title, _currentCategoryId);

      // Flag the new tile for the entry animation; cleared after one
      // animation duration (fire-and-forget so the fast-entry loop below is
      // never stalled) — see the invariant on _justAddedTaskIds.
      setState(() => _justAddedTaskIds.add(task.id));
      unawaited(
        Future<void>.delayed(kFastAnimationDuration)
            .then((_) => _justAddedTaskIds.remove(task.id)),
      );

      // Deliberate: dialog reopens after each add for fast entry — do not "fix" into single-shot.
    }
  }

  Future<void> _deleteTask(Task task, {bool animate = true}) async {
    // Trash-icon deletes (animate: true) fade/scale the tile out first
    // and only then commit the deletion, so the next rebuild removes it.
    // Swipe deletes (animate: false) must commit immediately: Dismissible has
    // already run its own exit animation and its contract requires the widget
    // to be gone from the list on the next build after onDismissed fires —
    // keeping it mounted for a second fade throws Flutter's "dismissed
    // Dismissible is still part of the tree" assertion.
    if (animate) {
      setState(() => _removingTaskIds.add(task.id));
      await Future<void>.delayed(kFastAnimationDuration);
    }

    await StorageService.deleteTask(task.id);
    if (animate) _removingTaskIds.remove(task.id);

    if (!mounted) return;
    _showSnackbar(
      'Task deleted',
      onUndo: () async {
        await StorageService.restoreTask(task);
      },
    );
  }

  Future<void> _clearCompleted() async {
    final count = StorageService.getCompletedCount(_currentCategoryId);
    if (count == 0) return; // Nothing to confirm.

    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Theme(
        data: _categoryTheme(dialogContext),
        child: AlertDialog(
          title: const Text('Clear completed tasks?'),
          content: Text(
            'Remove $count completed task(s)? This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('CANCEL'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('CLEAR'),
            ),
          ],
        ),
      ),
    );

    if (confirm == true) {
      // clearCompleted's return value is the source of truth for how many
      // tasks were actually removed; the pre-dialog count only gates and
      // words the confirmation.
      final removed = await StorageService.clearCompleted(_currentCategoryId);
      _showSnackbar('Cleared $removed completed tasks');
    }
  }

  Future<void> _deleteAll() async {
    final cat = StorageService.getCategory(_currentCategoryId);
    if (cat == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Theme(
        data: _categoryTheme(dialogContext),
        child: AlertDialog(
          title: const Text('Delete all tasks?'),
          content: Text(
            'Remove all tasks in "${cat.name}"? This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('CANCEL'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('DELETE ALL'),
            ),
          ],
        ),
      ),
    );

    if (confirm == true) {
      await StorageService.deleteAllTasks(_currentCategoryId);
      _showSnackbar('All tasks deleted');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      // Rebuild on ANY category change (name/color edits) or task change
      valueListenable: Hive.box<TaskCategory>(kCategoryBoxName).listenable(),
      builder: (context, _, child) {
        final category =
            StorageService.getCategory(_currentCategoryId) ??
            StorageService.getCategory(kQuickTasksCategoryId)!;
        _currentCategoryId = category.id; // self-heal if current was deleted

        return Theme(
          data: _categoryTheme(context),
          child: Stack(
            children: [
              Scaffold(
                appBar: AppBar(
                  // Every palette entry is a Material 800-level shade, so a
                  // white foreground is safe for all of them.
                  backgroundColor: Color(category.colorValue),
                  foregroundColor: Colors.white,
                  title: Text(category.name),
                  actions: [
                    PopupMenuButton<String>(
                      onSelected: (value) {
                        if (value == 'clear_completed') {
                          _clearCompleted();
                        } else if (value == 'delete_all') {
                          _deleteAll();
                        }
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: 'clear_completed',
                          child: Text('Clear Completed'),
                        ),
                        const PopupMenuItem(
                          value: 'delete_all',
                          child: Text(
                            'Delete All Tasks',
                            style: TextStyle(color: Colors.red),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                body: Column(
                  children: [
                    // Time-of-day greeting; fades out and folds its space
                    // away after kGreetingVisibleDuration. AnimatedOpacity
                    // gives the fade-in; AnimatedSize collapses the vacated
                    // slot so the task list slides up instead of jumping.
                    AnimatedSize(
                      duration: kAnimationDuration,
                      alignment: Alignment.topCenter,
                      child: AnimatedOpacity(
                        duration: kAnimationDuration,
                        opacity: _showGreeting ? 1 : 0,
                        child: !_showGreeting
                            ? const SizedBox.shrink()
                            : Container(
                                margin: const EdgeInsets.fromLTRB(
                                  16,
                                  12,
                                  16,
                                  0,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                                decoration: BoxDecoration(
                                  color: Color(category.colorValue)
                                      .withAlpha(30),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  _greetingText,
                                  style: Theme.of(context).textTheme.titleLarge
                                      ?.copyWith(
                                        fontWeight: FontWeight.w600,
                                        color: Color(category.colorValue),
                                      ),
                                ),
                              ),
                      ),
                    ),
                    Expanded(
                      child: ValueListenableBuilder(
                        valueListenable: Hive.box<Task>(kTaskBoxName)
                            .listenable(),
                        builder: (context, _, child) {
                          final split = StorageService.getTasksSplit(
                            _currentCategoryId,
                          );
                          final active = split.active;
                          final completed = split.completed;

                          if (active.isEmpty && completed.isEmpty) {
                            return Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    kEmptyStateTitle,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    kEmptyStateSubtitle,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium,
                                  ),
                                ],
                              ),
                            );
                          }

                          // Active tasks first, completed below. Only active are reorderable.
                          return ReorderableListView.builder(
                            padding: const EdgeInsets.only(
                              bottom: 80,
                            ), // Fab space
                            itemCount:
                                active.length +
                                (completed.isNotEmpty
                                    ? completed.length + 1
                                    : 0),
                            onReorder: (oldIndex, newIndex) async {
                              // Only allow reordering within the active section
                              if (oldIndex >= active.length ||
                                  newIndex > active.length) {
                                return;
                              }
                              if (oldIndex < newIndex) newIndex -= 1;
                              final item = active.removeAt(oldIndex);
                              active.insert(newIndex, item);
                              await StorageService.reorderActiveTasks(
                                _currentCategoryId,
                                active,
                              );
                            },
                            itemBuilder: (context, index) {
                              if (index < active.length) {
                                final task = active[index];
                                return _AnimatedTaskTile(
                                  key: ValueKey(task.id),
                                  removing: _removingTaskIds.contains(task.id),
                                  animateIn: _justAddedTaskIds.contains(
                                    task.id,
                                  ),
                                  child: TaskTile(
                                    task: task,
                                    onCheckboxChanged: (_) => _onToggle(task),
                                    onEditTap: (newTitle) async {
                                      task.title = newTitle;
                                      await StorageService.updateTask(task);
                                    },
                                    onDeleteTap: () => _deleteTask(task),
                                    onDismissed: () =>
                                        _deleteTask(task, animate: false),
                                  ),
                                );
                              }

                              // Completed section header
                              if (index == active.length) {
                                return Padding(
                                  key: const ValueKey('completed_header'),
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    24,
                                    16,
                                    8,
                                  ),
                                  child: Text(
                                    kCompletedHeaderText,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall,
                                  ),
                                );
                              }

                              // Completed tasks (not draggable, muted)
                              final task = completed[index - active.length - 1];
                              return _AnimatedTaskTile(
                                key: ValueKey(task.id),
                                removing: _removingTaskIds.contains(task.id),
                                animateIn: _justAddedTaskIds.contains(task.id),
                                child: Opacity(
                                  opacity: kCompletedOpacity,
                                  child: TaskTile(
                                    task: task,
                                    onCheckboxChanged: (_) => _onToggle(task),
                                    onEditTap: (newTitle) async {
                                      task.title = newTitle;
                                      await StorageService.updateTask(task);
                                    },
                                    onDeleteTap: () => _deleteTask(task),
                                    onDismissed: () =>
                                        _deleteTask(task, animate: false),
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
                // Custom bottom bar instead of standard FAB placement.
                bottomNavigationBar: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        FloatingActionButton(
                          onPressed: _openCategories,
                          tooltip: 'Categories',
                          backgroundColor: Color(category.colorValue),
                          foregroundColor: Colors.white,
                          child: const Icon(Icons.home),
                        ),
                        FloatingActionButton(
                          onPressed: _addTask,
                          tooltip: 'Add Task',
                          backgroundColor: Color(category.colorValue),
                          foregroundColor: Colors.white,
                          child: const Icon(Icons.add),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // Left-edge drag to open Categories. Sits above the Scaffold in the Stack
              // so it wins hit-testing within its 16px strip, but translucent so taps on
              // that strip still reach the tile underneath (only horizontal drags are claimed).
              //
              // TRADE-OFF: This competes with the TaskTile Dismissible's horizontal drag
              // recognizer for gestures starting within the strip. The topmost widget wins
              // the gesture arena. If edge swipes interfere with dismissing, shrink
              // kEdgeSwipeWidth or use a Drawer.
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: kEdgeSwipeWidth,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragStart: (_) => _edgeDragDx = 0,
                  onHorizontalDragUpdate: (details) {
                    _edgeDragDx += details.primaryDelta ?? 0;
                  },
                  onHorizontalDragCancel: () => _edgeDragDx = 0,
                  onHorizontalDragEnd: (_) {
                    final shouldOpen = _edgeDragDx >= kEdgeSwipeDistance;
                    _edgeDragDx = 0;
                    if (shouldOpen) _openCategories();
                  },
                  child: const ColoredBox(color: Colors.transparent),
                ),
              ),

              // Celebration rain over everything, app bar included. Colors
              // are the existing category palette — no new list.
              //
              // IgnorePointer is load-bearing, not cosmetic: ConfettiWidget
              // renders a CustomPaint whose painter does not override
              // hitTest, so the framework falls back to "point is within
              // bounds" — meaning the full-area confetti layer captures
              // every tap in its slot for the duration of the burst. Without
              // this wrapper, tapping a task tile while confetti falls
              // registers the tap on the confetti layer instead of the tile,
              // and the user sees a 1s window where taps on the covered region do nothing.
              Align(
                alignment: Alignment.topCenter,
                child: IgnorePointer(
                  child: ConfettiWidget(
                    confettiController: _confettiController,
                    blastDirection: pi / 2, // down
                    numberOfParticles: kConfettiParticles,
                    emissionFrequency: 0.05,
                    maxBlastForce: 40,
                    minBlastForce: 15,
                    gravity: 0.3,
                    colors: kCategoryPalette,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A tiny round-robin pool of AudioPlayers for one sound asset. A single
/// AudioPlayer's play() re-runs Android's reset -> prepare -> start
/// sequence every call; firing a second play() on the same instance before
/// that async sequence settles is a race the plugin sometimes drops
/// silently — observed as "1st tap plays, 2nd doesn't, 3rd sometimes does."
/// Each pool member is an independent player with its own state machine, so
/// consecutive taps land on different instances and never contend for the
/// same one.
// NOTE: Fixed-size pool. Taps faster than kSoundPoolSize within one ding's
// ~200ms duration will wrap around onto a still-busy player and can drop a
// sound. Bump kSoundPoolSize if needed.
class _SoundPool {
  _SoundPool(this._asset, {int size = kSoundPoolSize})
    : _players = List.generate(size, (_) => AudioPlayer());

  final String _asset;
  final List<AudioPlayer> _players;
  int _next = 0;

  /// Loads every pool member's source concurrently. Future.wait hands them
  /// all to the platform channel at once.
  Future<void> preload() =>
      Future.wait(_players.map((p) => p.setSource(AssetSource(_asset))));

  Future<void> play() async {
    final player = _players[_next];
    _next = _nextIndex(_next, _players.length);
    try {
      await player.play(AssetSource(_asset));
    } catch (e) {
      // A missing/unplayable asset must never break a check-in.
      debugPrint('check sound failed: ${e.runtimeType}');
    }
  }

  void dispose() {
    for (final player in _players) {
      player.dispose();
    }
  }
}

/// Fades/scales a task tile in on insert and back out on delete, giving
/// button-driven add/delete the same visual polish as the swipe gestures.
/// Runs at kFastAnimationDuration to stay subtle and fast. Tiles not
/// flagged [animateIn] mount fully visible, so merely populating a list never
/// plays the insert animation.
// NOTE: TweenAnimationBuilder animates the tile itself, not the list slot,
// and composes with ReorderableListView. A true AnimatedList would also
// collapse the vacated slot but cannot host reorderable items.
class _AnimatedTaskTile extends StatelessWidget {
  final bool removing;
  final bool animateIn;
  final Widget child;

  const _AnimatedTaskTile({
    super.key,
    required this.removing,
    required this.animateIn,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // Tween.begin is only read on the first build: a tile flagged as just
    // added animates 0 → 1 (insert); any other tile starts at 1.0, fully
    // visible. Flipping [removing] drops the target to 0 and
    // TweenAnimationBuilder animates back down from the current value
    // (delete). Rebuilds with no target change simply hold, so toggling,
    // reordering, or clearing the animate-in flag never re-animates a tile.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: animateIn ? 0.0 : 1.0, end: removing ? 0.0 : 1.0),
      duration: kFastAnimationDuration,
      curve: Curves.easeOut,
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.scale(
          scale: kTileEntryMinScale + (1 - kTileEntryMinScale) * t,
          child: child,
        ),
      ),
    );
  }
}
