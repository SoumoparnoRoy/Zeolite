import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/report_error.dart';
import '../../core/words.dart';
import '../../data/models/attendance_status.dart';
import '../../data/models/subject.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/attendance_stats.dart';
import '../../domain/subject_counts.dart';
import '../../state/providers.dart';
import '../../state/timetable_image_reader.dart';
import '../../widgets/common.dart';
import '../subjects/totals_import_screen.dart';
import 'stats_page_list.dart';

/// Attendance kept as three numbers per subject, for anyone who would rather
/// count than put their classes on a timetable.
class CountsPage extends ConsumerStatefulWidget {
  const CountsPage({super.key});

  @override
  ConsumerState<CountsPage> createState() => _CountsPageState();
}

class _CountsPageState extends ConsumerState<CountsPage> {
  static const double _pad = StatsPageList.sidePad;

  bool _reading = false;

  /// The same reader as the timetable import, which already tells a portal
  /// page from a timetable. Only the portal page is taken here.
  Future<void> _readPortal() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final TimetableImageReader reader = ref.read(timetableImageReaderProvider);
    setState(() => _reading = true);
    try {
      final Uint8List? bytes = await reader.pickImage();
      if (bytes == null) return;
      final SheetRead read = await reader.read(bytes);
      if (!mounted) return;
      switch (read) {
        case TotalsSheet():
          await openTotalsRead(context, read);
        case TimetableSheet():
          messenger.showSnackBar(const SnackBar(
            content: Text('That looks like a timetable. Import it from '
                'Settings → Import timetable.'),
          ));
        case NoClassesFound():
          messenger.showSnackBar(const SnackBar(
            content: Text('Could not find an attendance table in that image.'),
          ));
      }
    } catch (error, stack) {
      reportError(error, stack, where: 'portal image read');
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not read that image.')),
      );
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();
    final List<SubjectCounts> rows = ref.watch(subjectCountsProvider);

    return StatsPageList(
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(_pad, 0, _pad, 16),
          sliver: SliverToBoxAdapter(
            child: OutlinedButton.icon(
              onPressed: _reading ? null : _readPortal,
              icon: _reading
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.document_scanner_outlined, size: 18),
              label: Text(
                _reading ? 'Reading the photo…' : 'Update from a portal photo',
              ),
            ),
          ),
        ),
        if (rows.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: EdgeInsets.only(top: 24, bottom: 80),
              child: EmptyState(
                icon: Icons.exposure_plus_1_rounded,
                title: 'No subjects yet',
                message: 'Add a subject, or read your portal page above, and '
                    'count its classes here.',
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(_pad, 0, _pad, 88),
            sliver: SliverList.separated(
              itemCount: rows.length,
              separatorBuilder: (_, __) => const SizedBox(height: 11),
              itemBuilder: (BuildContext context, int index) => _CountsCard(
                counts: rows[index],
                cancelledCounts: settings.cancelledCountsAsAttended,
              ),
            ),
          ),
      ],
    );
  }
}

class _CountsCard extends StatelessWidget {
  const _CountsCard({required this.counts, required this.cancelledCounts});

  final SubjectCounts counts;
  final bool cancelledCounts;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final SubjectStats stats = counts.stats;
    final Subject subject = counts.subject;
    final int cancelled = counts.totalOf(AttendanceStatus.cancelled);
    // Only worth saying once there is a cancelled class to explain.
    final String cancelledNote = cancelled == 0
        ? ''
        : cancelledCounts
            ? ' · cancelled classes count as attended'
            : " · cancelled classes aren't counted";

    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(14, 13, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              SubjectAvatar(
                initials: subject.initials,
                color: subject.color,
                size: 34,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  subject.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.bodyMedium,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    color: p.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  stats.hasData ? Words.percent(stats.percent) : '—',
                  style: TextStyle(
                    fontSize: AppType.headingLarge,
                    height: 1,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                    color: stats.hasData
                        ? healthColor(stats.health, p)
                        : p.textFaint,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final AttendanceStatus status in AttendanceStatus.values)
            _CountLine(counts: counts, status: status),
          const SizedBox(height: 4),
          Text(
            'Held ${stats.held}$cancelledNote',
            style:
                monoStyle(color: p.textTertiary, size: AppType.captionMedium),
          ),
        ],
      ),
    );
  }
}

/// One of the three figures, with a step either side. The figure itself opens
/// a field for the whole total, for catching up from a portal at once.
class _CountLine extends ConsumerWidget {
  const _CountLine({required this.counts, required this.status});

  final SubjectCounts counts;
  final AttendanceStatus status;

  String get _label => switch (status) {
        AttendanceStatus.present => 'Attended',
        AttendanceStatus.absent => 'Missed',
        AttendanceStatus.cancelled => 'Cancelled',
      };

  String get _noun => switch (status) {
        AttendanceStatus.present => 'an attended class',
        AttendanceStatus.absent => 'a missed class',
        AttendanceStatus.cancelled => 'a cancelled class',
      };

  Future<void> _type(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final int marked = counts.markedOf(status);
    final String? typed = await showAppSheet<String>(
      context: context,
      title: '$_label in ${counts.subject.name}',
      child: SheetTextForm(
        submitLabel: 'Save',
        initial: '${counts.totalOf(status)}',
        labelText: _label,
        keyboardType: TextInputType.number,
        selectInitial: true,
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.digitsOnly,
        ],
        header: marked == 0
            ? null
            : Text(
                '$marked of these ${marked == 1 ? 'is' : 'are'} marked in '
                'the app, so the total cannot go below $marked.',
                style: TextStyle(
                  fontSize: AppType.bodySmall,
                  height: 1.4,
                  color: context.palette.textTertiary,
                ),
              ),
      ),
    );
    final int? total = typed == null ? null : int.tryParse(typed);
    final int? subjectId = counts.subject.id;
    if (total == null || subjectId == null) return;
    final bool saved =
        await ref.read(countActionsProvider).setTotal(subjectId, status, total);
    if (!saved) {
      messenger.showSnackBar(SnackBar(
        content: Text('$_label cannot go below $marked — that many are '
            'marked in the app.'),
      ));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppPalette p = context.palette;
    final Color tint = status.colorIn(p);
    final CountActions actions = ref.read(countActionsProvider);
    final int? subjectId = counts.subject.id;

    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            _label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppType.bodySmall,
              fontWeight: FontWeight.w600,
              color: p.textSecondary,
            ),
          ),
        ),
        _StepButton(
          icon: Icons.remove_rounded,
          tooltip: 'Remove $_noun',
          tint: tint,
          onTap: subjectId != null && counts.canRemove(status)
              ? () => actions.remove(subjectId, status)
              : null,
        ),
        Tooltip(
          message: 'Type the ${_label.toLowerCase()} total',
          child: InkWell(
            onTap: () => _type(context, ref),
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            child: Container(
              constraints: const BoxConstraints(minWidth: 52, minHeight: 44),
              alignment: Alignment.center,
              child: Text(
                '${counts.totalOf(status)}',
                style: TextStyle(
                  fontFamily: AppFonts.mono,
                  fontSize: AppType.headingMedium,
                  fontWeight: FontWeight.w700,
                  color: p.textPrimary,
                ),
              ),
            ),
          ),
        ),
        _StepButton(
          icon: Icons.add_rounded,
          tooltip: 'Add $_noun',
          tint: tint,
          onTap:
              subjectId == null ? null : () => actions.add(subjectId, status),
        ),
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.tooltip,
    required this.tint,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final Color tint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onTap != null;
    final Color color = enabled ? tint : context.palette.textFaint;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox.square(
            dimension: 44,
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: SizedBox.square(
                  dimension: 34,
                  child: Icon(icon, size: 18, color: color),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
