import 'package:flutter/material.dart';

import '../models/task.dart';
import '../constants.dart';

class TaskTile extends StatefulWidget {
  final Task task;
  final ValueChanged<bool?> onCheckboxChanged;
  final ValueChanged<String> onEditTap; // Changed from VoidCallback
  final VoidCallback onDeleteTap;
  final VoidCallback onDismissed;

  const TaskTile({
    super.key,
    required this.task,
    required this.onCheckboxChanged,
    required this.onEditTap,
    required this.onDeleteTap,
    required this.onDismissed,
  });

  @override
  State<TaskTile> createState() => _TaskTileState();
}

class _TaskTileState extends State<TaskTile> {
  // Incremented only when a swipe actually fires Dismissible.onDismissed —
  // NOT when `task.completed` merely changes (e.g. a checkbox tap). This is
  // what the Dismissible below is keyed on.
  //
  // ponytail: a dismissed Dismissible can never be rebuilt by the framework
  // ("A dismissed Dismissible widget is still part of the tree"), so a swipe
  // toggling completion — which does not remove the row, just moves it to
  // the other section under the same task.id — needs a fresh Dismissible
  // element afterward. Keying on this generation counter (an event) instead
  // of on task.completed (a value) means a plain checkbox tap, which never
  // touches Dismissible.onDismissed, leaves the key untouched — so
  // AnimatedDefaultTextStyle's in-flight strikethrough animation survives a
  // checkbox tap and only remounts after an actual swipe. Do not key this on
  // task.completed again; that was tried and regressed the checkbox
  // animation (see worklog).
  int _dismissGeneration = 0;

  /// Tap the row to edit the title directly in a bottom sheet.
  void _showFullTitle() async {
    final newTitle = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _TaskEditSheet(
        initialTitle: widget.task.title,
        textStyle: Theme.of(context).textTheme.titleLarge,
      ),
    );

    if (newTitle != null && newTitle != widget.task.title) {
      widget.onEditTap(newTitle);
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;

    // §5: Swipe right to complete. §6: Swipe left to delete.
    // Swiping right on completed task is a no-op (enforced by the direction limitation).
    return Dismissible(
      key: ValueKey('${task.id}-$_dismissGeneration'),
      direction: task.completed
          ? DismissDirection.endToStart
          : DismissDirection.horizontal,
      dismissThresholds: const {
        DismissDirection.startToEnd: kSwipeThreshold,
        DismissDirection.endToStart: kSwipeThreshold,
      },
      onDismissed: (direction) {
        setState(() => _dismissGeneration++);
        if (direction == DismissDirection.startToEnd) {
          widget.onCheckboxChanged(!task.completed);
        } else if (direction == DismissDirection.endToStart) {
          widget.onDismissed();
        }
      },
      background: Container(
        color: Colors.green,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20.0),
        child: const Icon(Icons.check, color: Colors.white),
      ),
      secondaryBackground: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20.0),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      child: ListTile(
        onTap: _showFullTitle,
        leading: Checkbox(
          value: task.completed,
          onChanged: widget.onCheckboxChanged,
        ),
        title: AnimatedDefaultTextStyle(
          duration: kAnimationDuration,
          style: Theme.of(context).textTheme.titleMedium!.copyWith(
            decoration: task.completed
                ? TextDecoration.lineThrough
                : TextDecoration.none,
            color: task.completed
                ? Theme.of(context).disabledColor
                : Theme.of(context).textTheme.titleMedium?.color,
          ),
          child: Text(
            task.title,
            maxLines: kTaskTitleMaxLines,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete, size: 20),
          onPressed: widget.onDeleteTap,
          tooltip: 'Delete task',
        ),
      ),
    );
  }
}

/// The direct-edit bottom sheet. Replaces the old EditTaskDialog.
class _TaskEditSheet extends StatefulWidget {
  final String initialTitle;
  final TextStyle? textStyle;
  const _TaskEditSheet({required this.initialTitle, this.textStyle});

  @override
  State<_TaskEditSheet> createState() => _TaskEditSheetState();
}

class _TaskEditSheetState extends State<_TaskEditSheet> {
  late final TextEditingController _controller;
  bool _canSave = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialTitle);
    _canSave = _controller.text.trim().isNotEmpty;
    _controller.addListener(() {
      final canSave = _controller.text.trim().isNotEmpty;
      if (canSave != _canSave) {
        setState(() => _canSave = canSave);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_canSave) {
      Navigator.of(context).pop(_controller.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    // Pushes the sheet up when the keyboard appears so the text field isn't hidden.
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        width: double.infinity,
        child: DraggableScrollableSheet(
          expand: false,
          builder: (context, scrollController) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  icon: const Icon(Icons.check),
                  tooltip: 'Save task',
                  onPressed: _canSave ? _submit : null,
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: TextField(
                    controller: _controller,
                    autofocus: true,
                    maxLines: null,
                    textAlign: TextAlign.start,
                    style: widget.textStyle,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: 'Task title',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
