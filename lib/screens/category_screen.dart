import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

import '../constants.dart';
import '../models/category.dart';
import '../services/storage_service.dart';
import '../widgets/category_dialog.dart';
import '../widgets/category_tile.dart';

class CategoryScreen extends StatefulWidget {
  const CategoryScreen({super.key});

  @override
  State<CategoryScreen> createState() => _CategoryScreenState();
}

class _CategoryScreenState extends State<CategoryScreen> {
  // Mirrors TaskScreen's left-edge strip: a right-edge drag left pops back
  // to the task screen with NO result, which is what keeps the previously
  // selected category untouched (TaskScreen only switches on a non-null id).
  double _edgeDragDx = 0;

  Future<void> _addCategory() async {
    final result = await showDialog<({String name, int colorValue})>(
      context: context,
      builder: (_) => const CategoryDialog(),
    );
    if (result != null) {
      await StorageService.addCategory(result.name, result.colorValue);
    }
  }

  Future<void> _editCategory(TaskCategory category) async {
    final result = await showDialog<({String name, int colorValue})>(
      context: context,
      builder: (_) => CategoryDialog(category: category),
    );
    if (result != null) {
      await StorageService.updateCategory(
        category.id,
        name: result.name,
        colorValue: result.colorValue,
      );
    }
  }

  Future<void> _deleteCategory(TaskCategory category) async {
    if (category.id == kQuickTasksCategoryId) return;
    final taskCount = StorageService.getTaskCountForCategory(category.id);
    bool moveTasks = false;
    if (taskCount > 0) {
      final choice = await showDialog<bool>(
        context: context,
        builder: (context) {
          bool localMoveTasks = true;
          return StatefulBuilder(
            builder: (context, setState) {
              return AlertDialog(
                title: Text('Delete "${category.name}"?'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('This category contains $taskCount task(s).'),
                    const SizedBox(height: 16),
                    InkWell(
                      onTap: () => setState(() => localMoveTasks = true),
                      child: Row(
                        children: [
                          Radio<bool>(
                            value: true,
                            groupValue: localMoveTasks,
                            onChanged: (val) =>
                                setState(() => localMoveTasks = val!),
                          ),
                          const Text('Move tasks to Quick Tasks'),
                        ],
                      ),
                    ),
                    InkWell(
                      onTap: () => setState(() => localMoveTasks = false),
                      child: Row(
                        children: [
                          Radio<bool>(
                            value: false,
                            groupValue: localMoveTasks,
                            onChanged: (val) =>
                                setState(() => localMoveTasks = val!),
                          ),
                          const Text('Delete tasks permanently'),
                        ],
                      ),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(null),
                    child: const Text('CANCEL'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(localMoveTasks),
                    style: FilledButton.styleFrom(backgroundColor: Colors.red),
                    child: const Text('DELETE'),
                  ),
                ],
              );
            },
          );
        },
      );
      if (choice == null) return; // Cancelled
      moveTasks = choice;
    }
    // Snapshot tasks + positions before deleteCategory mutates/moves them;
    // this record list is exactly what UNDO puts back.
    final snapshot = StorageService.getTasksForCategory(category.id)
        .map((t) => (task: t, position: t.position))
        .toList();
    await StorageService.deleteCategory(category.id, moveTasks: moveTasks);
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Category "${category.name}" deleted'),
        duration: kSnackbarDuration,
        action: SnackBarAction(
          label: 'UNDO',
          onPressed: () => StorageService.restoreCategory(category, snapshot),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(kDefaultCategoryColorValue),
            foregroundColor: Colors.white,
            title: const Text('Categories'),
            // Back button is automatic (top-left per §22)
          ),
          body: ValueListenableBuilder(
            valueListenable: Hive.box<TaskCategory>(kCategoryBoxName)
                .listenable(),
            builder: (context, _, child) {
              final categories = StorageService.getCategories();
              return ReorderableListView.builder(
                padding: const EdgeInsets.only(bottom: 80),
                itemCount: categories.length,
                onReorder: (oldIndex, newIndex) async {
                  if (oldIndex < newIndex) newIndex -= 1;
                  final item = categories.removeAt(oldIndex);
                  categories.insert(newIndex, item);
                  await StorageService.reorderCategories(categories);
                },
                itemBuilder: (context, index) {
                  final cat = categories[index];
                  return CategoryTile(
                    key: ValueKey(cat.id),
                    category: cat,
                    // On tap, pop the screen and pass the ID back to TaskScreen
                    onTap: () => Navigator.of(context).pop(cat.id),
                    onEditTap: () => _editCategory(cat),
                    onDeleteTap: () => _deleteCategory(cat),
                  );
                },
              );
            },
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: _addCategory,
            tooltip: 'Add Category',
            backgroundColor: const Color(kDefaultCategoryColorValue),
            foregroundColor: Colors.white,
            child: const Icon(Icons.add),
          ),
        ),

        // Right-edge drag left → back to the last-open category.
        //
        // Same pattern as TaskScreen's left-edge strip: translucent so taps
        // within the strip still reach the tiles underneath, and only
        // horizontal drags are claimed here.
        //
        // ponytail: this competes with CategoryTile's Dismissible
        // (right-to-left swipe to delete) for gestures starting inside the
        // rightmost 16px of a tile. The topmost widget wins, so a delete
        // swipe must start at least kEdgeSwipeWidth in from the right edge.
        // Ceiling: the strip eats the outermost few pixels of every delete
        // swipe. Upgrade path: shrink the strip, or move to a Drawer /
        // interactive route transition.
        Positioned(
          right: 0,
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
              // primaryDelta is negative for right-to-left movement.
              final shouldPop = _edgeDragDx <= -kEdgeSwipeDistance;
              _edgeDragDx = 0;
              if (shouldPop) {
                // Null result → TaskScreen keeps the previously selected
                // category. Contrast with a tile tap, which pops a non-null
                // id and switches.
                Navigator.of(context).pop();
              }
            },
            child: const ColoredBox(color: Colors.transparent),
          ),
        ),
      ],
    );
  }
}
