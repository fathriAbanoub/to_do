import 'package:flutter/material.dart';

import '../models/category.dart';
import '../constants.dart';

class CategoryDialog extends StatefulWidget {
  final TaskCategory? category;

  /// If [category] is provided, edits it. Otherwise creates a new one.
  const CategoryDialog({super.key, this.category});

  @override
  State<CategoryDialog> createState() => _CategoryDialogState();
}

class _CategoryDialogState extends State<CategoryDialog> {
  late final TextEditingController _nameController;
  late int _selectedColorValue;

  late double _h;
  late double _s;
  late double _v;

  bool _canSave = false;

  @override
  void initState() {
    super.initState();

    _nameController = TextEditingController(text: widget.category?.name);
    _selectedColorValue =
        widget.category?.colorValue ?? kCategoryPalette.first.toARGB32();

    final hsv = HSVColor.fromColor(Color(_selectedColorValue));
    _h = hsv.hue;
    _s = hsv.saturation;
    _v = hsv.value;

    _nameController.addListener(_validate);
    _validate();
  }

  void _validate() {
    final canSave = _nameController.text.trim().isNotEmpty;
    if (canSave != _canSave) {
      setState(() => _canSave = canSave);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _selectPaletteColor(Color color) {
    final hsv = HSVColor.fromColor(color);

    setState(() {
      _selectedColorValue = color.toARGB32();
      _h = hsv.hue;
      _s = hsv.saturation;
      _v = hsv.value;
    });
  }

  void _updateHsv({double? h, double? s, double? v}) {
    setState(() {
      _h = h ?? _h;
      _s = s ?? _s;
      _v = v ?? _v;

      // ponytail: Cartesian SV panel + hue bar (see _SaturationValuePanel),
      // not a wheel. Ceiling: none in picking accuracy — a wheel is the
      // same surface in polar coordinates; it costs atan2/arc-gradient
      // math for identical colors. Upgrade path: CustomPainter wheel if
      // the look ever matters more than the code.
      _selectedColorValue = HSVColor.fromAHSV(
        1,
        _h % 360,
        _s.clamp(0, 1),
        _v.clamp(0, 1),
      ).toColor().toARGB32();
    });
  }

  void _submit() {
    if (_canSave) {
      Navigator.of(context).pop((
        name: _nameController.text.trim(),
        colorValue: _selectedColorValue,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.category == null ? 'New Category' : 'Edit Category'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameController,
              autofocus: widget.category == null,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(hintText: 'Category Name'),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Text('Color', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: Color(_selectedColorValue),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: kCategoryPalette.map((color) {
                final isSelected = color.toARGB32() == _selectedColorValue;

                return GestureDetector(
                  onTap: () => _selectPaletteColor(color),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: isSelected
                          ? Border.all(
                              color: Theme.of(context).colorScheme.primary,
                              width: 3,
                            )
                          : null,
                    ),
                    child: isSelected
                        ? const Icon(Icons.check, color: Colors.white)
                        : null,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 24),
            Text('Custom color', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),

            // ponytail: Cartesian SV panel + hue bar, not a wheel. Ceiling:
            // none in picking accuracy — a wheel is the same surface in
            // polar coordinates; it costs atan2/arc-gradient math for
            // identical colors. Upgrade path: CustomPainter wheel if the
            // look ever matters more than the code.
            SizedBox(
              height: kColorPanelHeight,
              child: _SaturationValuePanel(
                hue: _h,
                saturation: _s,
                value: _v,
                onChanged: (s, v) => _updateHsv(s: s, v: v),
              ),
            ),
            const SizedBox(height: 16),
            _HueBar(
              hue: _h,
              onChanged: (h) => _updateHsv(h: h),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('CANCEL'),
        ),
        FilledButton(
          onPressed: _canSave ? _submit : null,
          child: const Text('SAVE'),
        ),
      ],
    );
  }
}

/// Saturation/value panel: drag the circle anywhere in the box. Left/right
/// is saturation, up/down is brightness. Two stacked gradients ARE the HSV
/// surface — white→pureHue horizontally, transparent→black vertically.
// ponytail: Align places the thumb by FRACTION (2*s-1, 1-2*v) instead of a
// LayoutBuilder measuring pixels — LayoutBuilder throws when the dialog's
// layout asks for intrinsic dimensions. Ceiling: none; upgrade path: none
// needed, this is the simpler version.
class _SaturationValuePanel extends StatelessWidget {
  final double hue;
  final double saturation;
  final double value;
  final void Function(double saturation, double value) onChanged;

  const _SaturationValuePanel({
    required this.hue,
    required this.saturation,
    required this.value,
    required this.onChanged,
  });

  void _pick(Offset local, Size size) {
    if (size.isEmpty) return; // not laid out yet — can't map a tap
    final s = (local.dx / size.width).clamp(0.0, 1.0);
    final v = 1.0 - (local.dy / size.height).clamp(0.0, 1.0);
    onChanged(s, v);
  }

  @override
  Widget build(BuildContext context) {
    final pureHue = HSVColor.fromAHSV(1, hue % 360, 1, 1).toColor();

    return GestureDetector(
      onTapDown: (d) => _pick(d.localPosition, context.size ?? Size.zero),
      onPanUpdate: (d) => _pick(d.localPosition, context.size ?? Size.zero),
      child: Stack(
        clipBehavior: Clip.none, // thumb may overhang the edge
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [Colors.white, pureHue]),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black],
              ),
            ),
          ),
          Align(
            // s=0 → left edge (-1), s=1 → right edge (+1);
            // v=1 → top (-1), v=0 → bottom (+1). Thumb CENTER tracks the
            // exact picked point, same as the old pixel math.
            alignment: Alignment(saturation * 2 - 1, 1 - value * 2),
            child: _ColorThumb(
              color: HSVColor.fromAHSV(
                1,
                hue % 360,
                saturation,
                value,
              ).toColor(),
            ),
          ),
        ],
      ),
    );
  }
}

/// Horizontal rainbow bar: drag the thumb left/right to change hue.
class _HueBar extends StatelessWidget {
  final double hue;
  final ValueChanged<double> onChanged;

  const _HueBar({required this.hue, required this.onChanged});

  void _pick(Offset local, Size size) {
    if (size.isEmpty) return;
    onChanged((local.dx / size.width).clamp(0.0, 1.0) * 360);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (d) => _pick(d.localPosition, context.size ?? Size.zero),
      onPanUpdate: (d) => _pick(d.localPosition, context.size ?? Size.zero),
      child: SizedBox(
        height: kHueBarHeight,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(kHueBarHeight / 2),
                  gradient: const LinearGradient(
                    colors: [
                      Color(0xFFFF0000), // red
                      Color(0xFFFFFF00), // yellow
                      Color(0xFF00FF00), // green
                      Color(0xFF00FFFF), // cyan
                      Color(0xFF0000FF), // blue
                      Color(0xFFFF00FF), // magenta
                      Color(0xFFFF0000), // red again closes the loop
                    ],
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment(hue / 360 * 2 - 1, 0),
              child: _ColorThumb(
                color: HSVColor.fromAHSV(1, hue % 360, 1, 1).toColor(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The draggable circle shared by the panel and the hue bar: current color
/// fill, white ring, small shadow so it stays visible on white and black.
class _ColorThumb extends StatelessWidget {
  final Color color;

  const _ColorThumb({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: kColorThumbSize,
      height: kColorThumbSize,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)],
      ),
    );
  }
}
