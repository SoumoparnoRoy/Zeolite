import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_theme.dart';
import '../domain/attendance_stats.dart';
import '../domain/term_outlook.dart';

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

/// A skip-budget line's colour: grey while there is room, like the subject
/// cards' headlines, so the colour is kept for the classes that cannot be
/// spared.
Color outlookColor(TermOutlook outlook, AppPalette palette) =>
    outlook.health == AttendanceHealth.safe
        ? palette.textTertiary
        : healthColor(outlook.health, palette);

/// Takes the keyboard down for good. `FocusScope.unfocus()` leaves the field
/// in the scope's history, so the next sheet or page to close hands focus back
/// to it and the keyboard rises over whatever screen is showing.
void dropFocus() => FocusManager.instance.primaryFocus
    ?.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);

/// `shortText` in `firestore.rules`: a longer name is refused as
/// `permission-denied`, which fails the whole sync as a sign-in problem.
const int shortTextLimit = 500;

final List<TextInputFormatter> shortTextFormatters = <TextInputFormatter>[
  const _Utf16Limit(shortTextLimit),
];

/// Flutter's own limit counts what reads as one character, which can be
/// several of the UTF-16 units the rules count: an emoji is two. This cuts at
/// the last whole character that fits, so nothing is left half drawn.
class _Utf16Limit extends TextInputFormatter {
  const _Utf16Limit(this.most);

  final int most;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final int length = newValue.text.length;
    final int before = oldValue.text.length;
    // Never refused: a name imported over the cap has to be shortenable.
    if (length <= most || length <= before) return newValue;
    if (before == most) return oldValue;
    final StringBuffer kept = StringBuffer();
    int used = 0;
    for (final String character in newValue.text.characters) {
      used += character.length;
      if (used > most) break;
      kept.write(character);
    }
    final String text = kept.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// Times, dates, room codes and counts.
///
/// Anything the eye scans down a column rather than reads as a sentence goes
/// in the mono face, which is the whole reason it is bundled.
TextStyle monoStyle({
  required Color color,
  double size = AppType.captionLarge,
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
            // Otherwise every header on a page folds into one stop that reads
            // them all in a row.
            child: Semantics(
              container: true,
              header: true,
              child: Text(
                title.toUpperCase(),
                style: TextStyle(
                  color: context.palette.textTertiary,
                  fontSize: AppType.captionLarge,
                  height: 1,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.05,
                ),
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
                    fontSize: AppType.captionLarge,
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
                fontSize: AppType.headingLarge,
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
                fontSize: AppType.bodyMedium,
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

/// Stands where a screen's empty state would when its data could not be read.
/// Without it a failed read looks exactly like a fresh install and offers to
/// add a first class.
class LoadFailed extends StatelessWidget {
  const LoadFailed({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.error_outline_rounded,
      title: 'Could not load your data',
      message: 'Zeolite could not read what is saved on this device. Try '
          'again, and restart the app if this keeps happening.',
      action: FilledButton(onPressed: onRetry, child: const Text('Try again')),
    );
  }
}

/// A slider over a stored setting that saves once, when the drag ends.
///
/// Saving a setting writes all of them, stamps the schedule and wakes sync,
/// which on every tick of a drag is dozens of writes for one decision.
/// [builder] lays out the slider together with whatever shows its value, and
/// is handed the value under the thumb so that still follows the drag.
class SettledSlider extends StatefulWidget {
  const SettledSlider({
    super.key,
    required this.value,
    required this.onSettled,
    required this.builder,
  });

  final double value;
  final ValueChanged<double> onSettled;
  final Widget Function(
    BuildContext context,
    double shown,
    ValueChanged<double> onChanged,
    ValueChanged<double> onChangeEnd,
  ) builder;

  @override
  State<SettledSlider> createState() => _SettledSliderState();
}

class _SettledSliderState extends State<SettledSlider> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    return widget.builder(
      context,
      _dragging ?? widget.value,
      (double value) => setState(() => _dragging = value),
      (double value) {
        widget.onSettled(value);
        setState(() => _dragging = null);
      },
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
          Flexible(
            child: Text(
              label.toUpperCase(),
              style: TextStyle(
                color: fg,
                fontSize: AppType.microMedium,
                height: 1,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.45,
              ),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
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
    this.mergeTrailing = false,
    this.semanticsIdentifier,
    this.enabled = true,
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

  /// Reads [trailing] as part of the row: one stop that says the switch's
  /// state. Off for a trailing button, which needs its own stop.
  final bool mergeTrailing;

  /// For UI tests to find the row by.
  final String? semanticsIdentifier;

  /// False while [onTap] is unavailable for now; it reads as a disabled button.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    // Each row is its own node. Without the boundary, a row's texts and tap
    // fold into the nearest ancestor, and after a sync the whole Account page
    // read as one node.
    if (mergeTrailing) {
      return MergeSemantics(
        child: Semantics(
          identifier: semanticsIdentifier,
          child: _row(context),
        ),
      );
    }
    return Semantics(
      container: true,
      button: onTap != null,
      enabled: onTap == null ? null : enabled,
      identifier: semanticsIdentifier,
      child: _row(context),
    );
  }

  Widget _row(BuildContext context) {
    final AppPalette p = context.palette;
    final Color tone = tint ?? p.accent;
    final String? sub = value;
    final VoidCallback? tap = enabled ? onTap : null;

    return InkWell(
      onTap: tap,
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
                      fontSize: AppType.bodyMedium,
                      height: 1.15,
                      fontWeight: FontWeight.w700,
                      color: p.textPrimary,
                    ),
                  ),
                  if (sub != null && sub.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      sub,
                      // A phone-width row cannot hold a subtitle like "A Notion
                      // export of what you have attended" on one line.
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      // Proportional: these are sentences, and mono is this
                      // app's voice for data — times, codes, dates, counts.
                      style: TextStyle(
                        fontSize: AppType.captionLarge,
                        height: 1.35,
                        color: p.textTertiary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null)
              trailing!
            else if (tap != null)
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
      child: Semantics(
        container: true,
        child: Text(
          text,
          style: TextStyle(
            fontSize: AppType.captionLarge,
            height: 1.4,
            fontWeight: FontWeight.w400,
            color: context.palette.textTertiary,
          ),
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
    this.keyboardType,
    this.inputFormatters,
    this.selectInitial = false,
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
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  /// Starts with [initial] selected, for a figure that is usually typed over
  /// rather than edited.
  final bool selectInitial;

  /// Popped when the field is left empty. Without one, submitting an empty
  /// field does nothing rather than saving a blank name.
  final String? emptyFallback;

  @override
  State<SheetTextForm> createState() => _SheetTextFormState();
}

class _SheetTextFormState extends State<SheetTextForm> {
  late final TextEditingController _input = TextEditingController.fromValue(
    TextEditingValue(
      text: widget.initial,
      selection: widget.selectInitial
          ? TextSelection(baseOffset: 0, extentOffset: widget.initial.length)
          : TextSelection.collapsed(offset: widget.initial.length),
    ),
  );

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
          keyboardType: widget.keyboardType,
          inputFormatters: widget.inputFormatters ?? shortTextFormatters,
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

/// [showDialog] with the screen covered while the dialog fades out, so the
/// second tap of a double tap on one of its buttons goes nowhere.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) async {
  final OverlayState? overlay =
      Navigator.of(context, rootNavigator: true).overlay;
  ModalRoute<Object?>? dialog;
  final T? result = await showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (BuildContext context) {
      dialog ??= ModalRoute.of(context);
      return builder(context);
    },
  );
  if (overlay != null && dialog != null) _coverWhileClosing(overlay, dialog!);
  return result;
}

/// A closing dialog's or sheet's barrier stops taking taps as soon as it
/// starts to fade, so the second tap of a double tap on its last button would
/// land on whatever is underneath: a row, a switch, or a button on the page it
/// came from. This covers the screen until the route has gone, however it was
/// closed.
///
/// [TransitionRoute.completed] fires when the route is disposed, including
/// when it is removed before its animation finishes. The timer is a backstop so
/// the cover can never outlast a route that somehow never completes.
void _coverWhileClosing(OverlayState overlay, ModalRoute<Object?> route) {
  if (!overlay.mounted) return;
  final OverlayEntry cover = OverlayEntry(
    builder: (BuildContext context) => const ModalBarrier(dismissible: false),
  );
  overlay.insert(cover);
  bool removed = false;
  late final Timer backstop;
  void remove() {
    if (removed) return;
    removed = true;
    backstop.cancel();
    cover.remove();
    cover.dispose();
  }

  backstop = Timer(const Duration(seconds: 1), remove);
  route.completed.whenComplete(remove);
}

/// Standard bottom-sheet wrapper: drag handle, title, scrollable body. Covered
/// while it closes, like [showAppDialog].
///
/// [enableDrag] is off for a sheet that asks before discarding: Flutter closes
/// a dragged sheet with a plain pop, which a `PopScope` inside never sees.
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required String title,
  required Widget child,
  bool enableDrag = true,
}) async {
  final OverlayState? overlay =
      Navigator.of(context, rootNavigator: true).overlay;
  ModalRoute<Object?>? sheet;
  final T? result = await showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    // Without the drag handle above it, a sheet tall enough to fill the
    // screen draws its title under the status bar.
    useSafeArea: true,
    enableDrag: enableDrag,
    backgroundColor: context.palette.canvas,
    builder: (BuildContext context) {
      sheet ??= ModalRoute.of(context);
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
                    fontSize: AppType.headlineLarge,
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
  if (overlay != null && sheet != null) _coverWhileClosing(overlay, sheet!);
  return result;
}
