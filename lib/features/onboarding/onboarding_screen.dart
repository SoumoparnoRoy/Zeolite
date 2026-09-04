import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../data/settings/app_settings.dart';
import '../../services/notification_service.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';

/// First-run setup: semester dates and the attendance requirement.
///
/// Kept to a single screen deliberately — the app is useful the moment these
/// two things are known, and everything else can be changed later in Settings.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  late DateTime _start;
  late DateTime _end;
  double _target = 75;
  bool _notifications = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final DateTime today = Dates.today();
    _start = today;
    // A typical term is about four months.
    _end = Dates.addDays(today, 120);
  }

  Future<void> _pick({required bool isStart}) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: isStart ? _start : _end,
      firstDate: DateTime(DateTime.now().year - 1),
      lastDate: DateTime(DateTime.now().year + 4),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isStart) {
        _start = Dates.dayOf(picked);
        if (Dates.keyOf(_end) <= Dates.keyOf(_start)) {
          _end = Dates.addDays(_start, 120);
        }
      } else {
        _end = Dates.dayOf(picked);
        if (Dates.keyOf(_end) <= Dates.keyOf(_start)) {
          _start = Dates.addDays(_end, -120);
        }
      }
    });
  }

  Future<void> _finish() async {
    setState(() => _saving = true);

    if (_notifications) {
      await NotificationService.instance.requestPermissions();
    }

    // Merged, not a fresh object: the welcome screen has already run, and a
    // bare `AppSettings(...)` would default its answer away and ask again.
    final AppSettings current =
        ref.read(settingsProvider).value ?? const AppSettings();

    await ref.read(settingsProvider.notifier).save(
          current.copyWith(
            semesterStart: _start,
            semesterEnd: _end,
            targetPercent: _target,
            notifyBeforeClass: _notifications,
            notifyEveningReminder: _notifications,
            notifyAttendanceDanger: _notifications,
            onboarded: true,
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    final int weeks = (Dates.daysBetween(_start, _end) / 7).round();

    return GradientScaffold(
      headerGap: 22,
      header: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 52,
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(17),
              ),
              child: const Icon(
                Icons.school_rounded,
                color: Colors.white,
                size: 26,
              ),
            ),
            const SizedBox(height: 18),
            const HeaderTitle('Zeolite', size: 30),
            const SizedBox(height: 8),
            const HeaderCaption(
              'Your timetable and attendance, in one place. '
              'Two quick answers and you are set up.',
              emphasis: 0.8,
            ),
          ],
        ),
      ),
      bottom: FilledButton(
        onPressed: _saving ? null : _finish,
        child: _saving
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Start tracking'),
      ),
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          sliver: SliverList.list(
            children: <Widget>[
              const SectionHeader('When is your term?'),
              GroupedRows(
                children: <Widget>[
                  AppRow(
                    icon: Icons.play_circle_outline_rounded,
                    title: 'Starts',
                    value: Dates.formatFull(_start),
                    onTap: () => _pick(isStart: true),
                  ),
                  AppRow(
                    icon: Icons.stop_circle_outlined,
                    title: 'Ends',
                    value: Dates.formatFull(_end),
                    onTap: () => _pick(isStart: false),
                  ),
                ],
              ),
              GroupNote('About $weeks weeks. You can change this any time.'),
              const SizedBox(height: 24),
              const SectionHeader('Attendance you need'),
              SurfaceCard(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: <Widget>[
                        Text(
                          '${_target.round()}%',
                          style: TextStyle(
                            fontSize: 40,
                            height: 1,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -2,
                            color: context.palette.accent,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 5),
                            child: Text(
                              'Most universities require 75%.',
                              style: TextStyle(
                                fontSize: 10.5,
                                height: 1.35,
                                fontWeight: FontWeight.w500,
                                color: context.palette.textTertiary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: _target,
                      min: 40,
                      max: 100,
                      divisions: 60,
                      label: '${_target.round()}%',
                      onChanged: (double v) => setState(() => _target = v),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              SurfaceCard(
                padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: context.palette.accent.withValues(
                          alpha: context.palette.isDark ? 0.18 : 0.12,
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.notifications_active_outlined,
                        size: 16,
                        color: AppColors.inkOn(
                          context.palette.accent,
                          context.palette,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Remind me about classes and unmarked attendance',
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.35,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Switch.adaptive(
                      value: _notifications,
                      onChanged: (bool v) => setState(() => _notifications = v),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
