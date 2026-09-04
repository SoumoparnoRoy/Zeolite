import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../domain/attendance_stats.dart';

/// The colour a subject's attendance is drawn in, shared by every screen that
/// shows a percentage so they never disagree.
Color healthColor(AttendanceHealth health, AppPalette palette) {
  switch (health) {
    case AttendanceHealth.safe:
      return palette.present;
    case AttendanceHealth.tight:
      return palette.warning;
    case AttendanceHealth.atRisk:
    case AttendanceHealth.lost:
      return palette.absent;
    case AttendanceHealth.empty:
      return palette.textFaint;
  }
}

/// The same colour softened for large filled areas such as the meter bar.
///
/// Text and icons keep the full-strength [healthColor] because they need the
/// contrast; a full-width slab of it reads as an alarm rather than as
/// information. Blending toward the track keeps the bar in the same family
/// instead of just making it translucent over whatever is behind it.
Color healthFill(AttendanceHealth health, AppPalette palette) {
  final Color base = healthColor(health, palette);
  return Color.alphaBlend(
    base.withValues(alpha: palette.isDark ? 0.82 : 0.72),
    palette.surfaceHigher,
  );
}

/// Times, dates, room codes and counts.
///
/// Anything the eye scans down a column rather than reads as a sentence goes
/// in the mono face, which is the whole reason it is bundled.
TextStyle monoStyle({
  required Color color,
  double size = 10.5,
  FontWeight weight = FontWeight.w500,
  double height = 1,
}) {
  return TextStyle(
    fontFamily: AppFonts.mono,
    fontSize: size,
    height: height,
    fontWeight: weight,
    color: color,
  );
}

/// A rounded panel lifted off the canvas — the base surface used everywhere.
/// Elevation is a shadow, not an outline; dark has no shadow at all, since a
/// shadow does nothing against near-black and the lighter fill carries it.
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.color,
    this.radius = AppSpacing.radiusMd,
    this.onTap,
    this.onLongPress,
    this.elevated = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final double radius;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Off for a card that already sits inside another one.
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final BorderRadius shape = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: elevated ? p.cardElevation : const <BoxShadow>[],
      ),
      child: Material(
        color: color ?? p.surface,
        borderRadius: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// Small uppercase heading used above list groups on the sheet.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: TextStyle(
                color: context.palette.textTertiary,
                fontSize: 10.5,
                height: 1,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.05,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// The hairline-ruled heading that separates one day from the next in a list.
///
/// A rule rather than a card: a day is a divider between things, not a thing
/// itself, and boxing each one was most of what made the old week look busy.
class DayRule extends StatelessWidget {
  const DayRule({
    super.key,
    required this.label,
    this.highlighted = false,
    this.onAdd,
  });

  final String label;

  /// Today, which is the one day worth colouring.
  final bool highlighted;

  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final Color ink = highlighted ? p.accent : p.textTertiary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: p.hairline)),
        ),
        child: Padding(
          padding: EdgeInsets.only(bottom: onAdd == null ? 9 : 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: ink,
                    fontSize: 10.5,
                    height: 1,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
              ),
              if (onAdd != null)
                // The glyph stays small so the rule reads as a rule, but the
                // target underneath it is a full 44px.
                Semantics(
                  button: true,
                  label: 'Add a class on this day',
                  child: InkResponse(
                    onTap: onAdd,
                    radius: 24,
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: Icon(
                        Icons.add_rounded,
                        size: 16,
                        color: p.accent,
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

/// Friendly placeholder for screens with nothing to show yet.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                color: p.accent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Icon(icon, size: 28, color: p.accent),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
                color: p.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.45,
                fontWeight: FontWeight.w500,
                color: p.textTertiary,
              ),
            ),
            if (action != null) ...<Widget>[
              const SizedBox(height: AppSpacing.xl),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Thin horizontal meter with an optional target marker.
class TargetBar extends StatelessWidget {
  const TargetBar({
    super.key,
    required this.value,
    required this.color,
    this.target,
    this.height = 6,
  });

  final double value;
  final Color color;
  final double? target;
  final double height;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final double clamped = value.clamp(0.0, 1.0);
        return SizedBox(
          height: height + 6,
          child: Stack(
            alignment: Alignment.centerLeft,
            children: <Widget>[
              Container(
                height: height,
                decoration: BoxDecoration(
                  color: context.palette.surfaceHigher,
                  borderRadius: BorderRadius.circular(height),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 450),
                curve: Curves.easeOutCubic,
                height: height,
                width: width * clamped,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(height),
                ),
              ),
              if (target != null && target! > 0 && target! < 1)
                Positioned(
                  left: (width * target!).clamp(0.0, width - 2),
                  child: Container(
                    width: 2,
                    height: height + 6,
                    decoration: BoxDecoration(
                      color: context.palette.textPrimary,
                      borderRadius: BorderRadius.circular(2),
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

/// The rounded tinted tile carrying a subject's two-letter code. Replaces the
/// colour spine: it carries the same colour and names the subject as well,
/// which is what long course titles needed.
class SubjectAvatar extends StatelessWidget {
  const SubjectAvatar({
    super.key,
    required this.initials,
    required this.color,
    this.size = 36,
  });

  final String initials;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: p.isDark ? 0.2 : 0.16),
        borderRadius: BorderRadius.circular(size * 0.32),
      ),
      child: Text(
        initials,
        style: TextStyle(
          color: AppColors.inkOn(color, p),
          fontSize: size * 0.31,
          height: 1,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// The ring-in-a-circle that says how one class turned out, once it is marked.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, this.size = 20});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      child: Container(
        width: size * 0.35,
        height: size * 0.35,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

/// Compact pill used for statuses, rooms and counts.
class Pill extends StatelessWidget {
  const Pill({
    super.key,
    required this.label,
    this.icon,
    this.color,
    this.background,
  });

  final String label;
  final IconData? icon;
  final Color? color;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final Color fg = color ?? context.palette.textTertiary;
    return Container(
      padding: EdgeInsets.fromLTRB(icon == null ? 7 : 6, 3.5, 7, 3.5),
      decoration: BoxDecoration(
        color: background ?? fg.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 11, color: fg),
            const SizedBox(width: 3),
          ],
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: fg,
              fontSize: 8.5,
              height: 1,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.45,
            ),
          ),
        ],
      ),
    );
  }
}

/// One row inside a [GroupedRows] card: an icon tile, a title, a mono value
/// line, and a chevron when it leads somewhere.
class AppRow extends StatelessWidget {
  const AppRow({
    super.key,
    required this.icon,
    required this.title,
    this.value,
    this.tint,
    this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String title;

  /// The current setting, in mono — a date, a range, a count.
  final String? value;

  /// The icon tile's colour. Defaults to the accent.
  final Color? tint;

  final VoidCallback? onTap;

  /// Replaces the chevron — a switch, a value, nothing.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final Color tone = tint ?? p.accent;
    final String? sub = value;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        child: Row(
          children: <Widget>[
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: tone.withValues(alpha: p.isDark ? 0.18 : 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 16, color: AppColors.inkOn(tone, p)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.15,
                      fontWeight: FontWeight.w700,
                      color: p.textPrimary,
                    ),
                  ),
                  if (sub != null && sub.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      sub,
                      // A phone-width row cannot hold a value like "A Notion
                      // export of what you have attended" on one line, and the
                      // mono default of 1 sets the two it wraps solid.
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: monoStyle(color: p.textTertiary, height: 1.35),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null)
              trailing!
            else if (onTap != null)
              Icon(Icons.chevron_right_rounded, size: 18, color: p.textFaint),
          ],
        ),
      ),
    );
  }
}

/// A white sheet holding a run of [AppRow]s, divided by rules inset past the
/// icon tiles so the tiles read as one column.
class GroupedRows extends StatelessWidget {
  const GroupedRows({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final List<Widget> rows = <Widget>[];
    for (int i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          Padding(
            padding: const EdgeInsets.only(left: 58),
            child: Container(height: 1, color: p.outlineSoft),
          ),
        );
      }
      rows.add(children[i]);
    }

    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
  }
}

/// The explanatory line that belongs to the group above it.
///
/// It sits under its own card rather than floating between two, so it is
/// obvious which rows it is talking about.
class GroupNote extends StatelessWidget {
  const GroupNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 9, 2, 0),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          height: 1.4,
          fontWeight: FontWeight.w400,
          color: context.palette.textTertiary,
        ),
      ),
    );
  }
}

/// Sheet body for "type one thing and confirm": a text field and a submit button
/// that pops the sheet with what was typed.
///
/// It exists so the controller has an owner. Creating one at the call site and
/// disposing it after `showAppSheet` returns crashes the app: the route is popped
/// but its dismiss animation still has the field mounted, so the controller dies
/// while a live widget listens to it. A State disposes on unmount, which is after
/// the animation, so the ordering is right by construction rather than by every
/// call site remembering.
class SheetTextForm extends StatefulWidget {
  const SheetTextForm({
    super.key,
    required this.submitLabel,
    this.initial = '',
    this.header,
    this.labelText,
    this.hintText,
    this.maxLines = 1,
    this.textCapitalization = TextCapitalization.sentences,
    this.emptyFallback,
  });

  final String submitLabel;
  final String initial;

  /// Optional content above the field — a date, an explanation.
  final Widget? header;

  final String? labelText;
  final String? hintText;
  final int maxLines;
  final TextCapitalization textCapitalization;

  /// Popped when the field is left empty. Without one, submitting an empty
  /// field does nothing rather than saving a blank name.
  final String? emptyFallback;

  @override
  State<SheetTextForm> createState() => _SheetTextFormState();
}

class _SheetTextFormState extends State<SheetTextForm> {
  late final TextEditingController _input =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit() {
    final String value = _input.text.trim();
    if (value.isEmpty) {
      if (widget.emptyFallback == null) return;
      Navigator.of(context).pop(widget.emptyFallback);
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.header != null) ...<Widget>[
          widget.header!,
          const SizedBox(height: AppSpacing.md),
        ],
        TextField(
          controller: _input,
          autofocus: true,
          maxLines: widget.maxLines,
          textCapitalization: widget.textCapitalization,
          decoration: InputDecoration(
            labelText: widget.labelText,
            hintText: widget.hintText,
          ),
          // Only a single-line field gets a usable submit action; a multi-line
          // one needs the return key for newlines.
          onSubmitted: widget.maxLines == 1 ? (_) => _submit() : null,
        ),
        const SizedBox(height: AppSpacing.xl),
        FilledButton(onPressed: _submit, child: Text(widget.submitLabel)),
      ],
    );
  }
}

/// Standard bottom-sheet wrapper: drag handle, title, scrollable body.
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required String title,
  required Widget child,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.palette.canvas,
    builder: (BuildContext context) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl,
              AppSpacing.sm,
              AppSpacing.xl,
              AppSpacing.xl,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                child,
              ],
            ),
          ),
        ),
      );
    },
  );
}
