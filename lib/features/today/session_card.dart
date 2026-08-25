import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../data/models/attendance_status.dart';
import '../../data/models/class_session.dart';
import '../../widgets/common.dart';

/// One class on the Today screen, as a row on a timeline: times in a gutter, a
/// spine in the subject's colour, and the class on a card.
///
/// Tapping the status a class already has clears it, so a mis-tap is undone
/// with the same button. The three buttons collapse to a one-line verdict once
/// the class is marked; tapping the card brings them back to correct it.
class SessionCard extends StatefulWidget {
  const SessionCard({
    super.key,
    required this.session,
    required this.onMark,
    required this.use24Hour,
    this.onLongPress,
    this.showDate = false,
    this.categoryName,
    this.tagName,
    this.onTag,
    this.isNext = false,
    this.nextColor,
  });

  /// Also how far each spine paints past its own card, so the two cannot drift.
  static const double gap = 14;

  /// Shared so a card and the one above it cannot disagree.
  static Color spineColorOf(ClassSession session, AppPalette palette) =>
      session.status == AttendanceStatus.cancelled
          ? palette.textFaint
          : session.subject.color;

  final ClassSession session;
  final void Function(AttendanceStatus status) onMark;
  final bool use24Hour;
  final VoidCallback? onLongPress;
  final bool showDate;

  /// Category label (Lab, Theory, ...), when the subject has one.
  final String? categoryName;

  /// The mark's tag, already resolved to a name. Passed in rather than looked
  /// up here for the same reason as [categoryName] — the card stays a plain
  /// widget with no data layer behind it.
  final String? tagName;

  final Color? nextColor;

  /// Opens the tag picker. Null when there are no tags to choose from, which
  /// is how the control stays invisible until Settings has one.
  final VoidCallback? onTag;

  /// The next class still to happen, which earns the one badge on the screen.
  final bool isNext;

  @override
  State<SessionCard> createState() => _SessionCardState();
}

class _SessionCardState extends State<SessionCard> {
  bool _expanded = false;

  bool get _showControls => _expanded || !widget.session.isMarked;

  @override
  void didUpdateWidget(covariant SessionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Clearing a mark from the expanded controls returns the card to its
    // unmarked state; leaving it flagged as expanded would then keep a card
    // open for no reason once it is marked again.
    if (!widget.session.isMarked) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final ClassSession session = widget.session;
    final Color spine = SessionCard.spineColorOf(session, p);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            // 12-hour times are half again as wide as "10:50", and a gutter
            // sized for the short form wraps every one of them. Scaled with
            // the type, since that is what it has to fit.
            width: (widget.use24Hour ? 40.0 : 58.0) *
                AppScale.of(MediaQuery.sizeOf(context)),
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text(
                    Clock.format(
                      session.startMinutes,
                      use24Hour: widget.use24Hour,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.visible,
                    softWrap: false,
                    style: monoStyle(
                      color: p.textPrimary,
                      size: 10.5,
                      weight: FontWeight.w700,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    Clock.format(
                      session.endMinutes,
                      use24Hour: widget.use24Hour,
                    ),
                    maxLines: 1,
                    softWrap: false,
                    style: monoStyle(
                      color: p.textFaint,
                      size: 9,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          _Spine(color: spine, next: widget.nextColor),
          const SizedBox(width: 12),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    final AppPalette p = context.palette;
    final ClassSession session = widget.session;
    final AttendanceStatus? status = session.status;
    final bool isCancelled = status == AttendanceStatus.cancelled;

    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
      onTap: session.isMarked
          ? () => setState(() => _expanded = !_expanded)
          : null,
      onLongPress: widget.onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(
                  session.subject.name,
                  maxLines: 3,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.25,
                    fontWeight: FontWeight.w700,
                    color: isCancelled ? p.textTertiary : p.textPrimary,
                    decoration: isCancelled ? TextDecoration.lineThrough : null,
                    decorationColor: p.textFaint,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _badge(context),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            _meta(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.5,
              height: 1.3,
              fontWeight: FontWeight.w500,
              color: p.textTertiary,
            ),
          ),
          if (_showControls) _controls(context) else _verdict(context, status!),
        ],
      ),
    );
  }

  /// One line under the name: everything the class *is*, in reading order.
  /// A single sentence rather than a row of icon chips — the icons repeated
  /// the same three shapes on every card and said nothing the words did not.
  String _meta() {
    final ClassSession session = widget.session;
    final String? room = session.room;
    final String? teacher = session.subject.teacher;
    return <String>[
      if (widget.showDate) Dates.relativeLabel(session.date),
      if (room != null && room.isNotEmpty) room,
      if (teacher != null && teacher.isNotEmpty) teacher,
      if (widget.categoryName != null && widget.categoryName!.isNotEmpty)
        widget.categoryName!,
      if (session.isExtra) 'One-off',
    ].join(' · ');
  }

  Widget _badge(BuildContext context) {
    final AppPalette p = context.palette;
    final ClassSession session = widget.session;
    final AttendanceStatus? status = session.status;

    if (session.isOngoing) {
      return Pill(label: 'Now', color: p.accent);
    }
    if (status != null) {
      return StatusDot(color: status.colorIn(p));
    }
    if (widget.isNext) {
      return Pill(label: 'Next', color: p.accent);
    }
    return const SizedBox.shrink();
  }

  Widget _verdict(BuildContext context, AttendanceStatus status) {
    final AppPalette p = context.palette;
    final Color color = status.colorIn(p);
    final String? tag = widget.tagName;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              'Marked ${status.label.toLowerCase()}',
              style: TextStyle(
                fontSize: 10,
                height: 1,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
          if (tag != null && tag.isNotEmpty) Pill(label: tag, color: p.cyan),
        ],
      ),
    );
  }

  Widget _controls(BuildContext context) {
    final AttendanceStatus? status = widget.session.status;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: <Widget>[
          for (final AttendanceStatus option
              in AttendanceStatus.values) ...<Widget>[
            Expanded(
              child: _StatusButton(
                status: option,
                selected: status == option,
                onTap: () => widget.onMark(option),
              ),
            ),
            if (option != AttendanceStatus.values.last)
              const SizedBox(width: 6),
          ],
          // Only once the class is marked: a tag labels a mark, so offering
          // one on an unmarked class would have nothing to attach to.
          if (widget.onTag != null && widget.session.isMarked) ...<Widget>[
            const SizedBox(width: 6),
            _TagButton(active: widget.tagName != null, onTap: widget.onTag!),
          ],
        ],
      ),
    );
  }
}

/// The vertical rule, painted through the gap below so a day is one line.
class _Spine extends StatelessWidget {
  const _Spine({required this.color, this.next});

  final Color color;
  final Color? next;

  /// Late, or no part of the card reads as its own colour.
  static const double _hold = 0.62;

  @override
  Widget build(BuildContext context) {
    final Color? below = next;
    return SizedBox(
      width: 8,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned(
            left: 3,
            top: 0,
            bottom: below == null ? 0 : -SessionCard.gap,
            width: 2,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: below == null
                      ? <Color>[color, color.withValues(alpha: 0.12)]
                      : <Color>[color, color, below],
                  stops: below == null ? null : const <double>[0, _hold, 1],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 4,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusButton extends StatelessWidget {
  const _StatusButton({
    required this.status,
    required this.selected,
    required this.onTap,
  });

  final AttendanceStatus status;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final Color color = status.colorIn(p);
    return Material(
      color: selected ? color.withValues(alpha: 0.12) : p.surfaceHigh,
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            status.label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.5,
              height: 1,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              color: selected ? color : p.textTertiary,
            ),
          ),
        ),
      ),
    );
  }
}

class _TagButton extends StatelessWidget {
  const _TagButton({required this.active, required this.onTap});

  /// Whether a tag is already set. Kept to an icon either way: the tag's name
  /// shows on the collapsed card, and repeating it here would push the three
  /// status buttons into ellipsis on a narrow phone.
  final bool active;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final Color accent = p.cyan;
    return Material(
      color: active ? accent.withValues(alpha: 0.14) : p.surfaceHigh,
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Icon(
            Icons.sell_outlined,
            size: 14,
            color: active ? accent : p.textTertiary,
          ),
        ),
      ),
    );
  }
}
