import 'package:flutter/material.dart';

import '../models/category.dart';
import '../constants.dart';

class CategoryTile extends StatefulWidget {
  final TaskCategory category;
  final VoidCallback onTap;
  final VoidCallback onEditTap;
  final VoidCallback onDeleteTap;
  const CategoryTile({
    super.key,
    required this.category,
    required this.onTap,
    required this.onEditTap,
    required this.onDeleteTap,
  });

  @override
  State<CategoryTile> createState() => _CategoryTileState();
}

class _CategoryTileState extends State<CategoryTile> {
  // Same generation-key pattern as TaskTile: a dismissed Dismissible can
  // never be rebuilt by the framework, so a swipe whose delete dialog gets
  // cancelled must remount under a fresh key instead of tripping Flutter's
  // "dismissed Dismissible is still part of the tree" assertion.
  int _dismissGeneration = 0;

  @override
  Widget build(BuildContext context) {
    final isQuickTasks = widget.category.id == kQuickTasksCategoryId;
    final tile = Card(
      color: Color(widget.category.colorValue),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        key: ValueKey(widget.category.id),
        onTap: widget.onTap,
        textColor: Colors.white,
        iconColor: Colors.white,
        title: Text(widget.category.name),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit, size: 20),
              onPressed: widget.onEditTap,
              tooltip: 'Edit category',
            ),
            if (!isQuickTasks) // §20: Cannot delete Quick Tasks
              IconButton(
                icon: const Icon(Icons.delete, size: 20),
                onPressed: widget.onDeleteTap,
                tooltip: 'Delete category',
              ),
          ],
        ),
      ),
    );
    // §20: Quick Tasks is not deletable, so it gets no swipe at all.
    if (isQuickTasks) return tile;
    return Dismissible(
      key: ValueKey('${widget.category.id}-$_dismissGeneration'),
      direction: DismissDirection.endToStart, // drag right → left to delete
      dismissThresholds: const {DismissDirection.endToStart: kSwipeThreshold},
      onDismissed: (_) {
        setState(() => _dismissGeneration++);
        widget.onDeleteTap();
      },
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20.0),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      child: tile,
    );
  }
}
