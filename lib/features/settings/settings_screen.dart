import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../data/settings/app_settings.dart';
import '../../state/providers.dart';
import '../../widgets/gradient_header.dart';

import 'appearance_section.dart';
import 'data_section.dart';
import 'notifications_section.dart';
import 'subjects_section.dart';
import 'sync_section.dart';
import 'term_section.dart';
import 'timetable_layout_section.dart';

/// Semester setup, attendance target, notifications, holidays and backup.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();
    final SettingsController controller = ref.read(settingsProvider.notifier);

    return GradientScaffold(
      headerGap: 22,
      header: _TargetHeader(
        target: settings.targetPercent,
        onChanged: controller.setTarget,
      ),
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
          sliver: SliverList.list(
            children: <Widget>[
              const TermSection(),
              const SizedBox(height: AppSpacing.xl),
              const CountingSection(),
              const SizedBox(height: AppSpacing.xl),
              const SubjectsSection(),
              const SizedBox(height: AppSpacing.xl),
              const DayGridSection(),
              const SizedBox(height: AppSpacing.xl),
              const RoomsSection(),
              const SizedBox(height: AppSpacing.xl),
              const TagsSection(),
              const SizedBox(height: AppSpacing.xl),
              const CategoriesSection(),
              const SizedBox(height: AppSpacing.xl),
              const AppearanceSection(),
              const SizedBox(height: AppSpacing.xl),
              const NotificationsSection(),
              const SizedBox(height: AppSpacing.xl),
              const HolidaysSection(),
              const SizedBox(height: AppSpacing.xl),
              const DisplaySection(),
              const SizedBox(height: AppSpacing.xl),
              const AccountSection(),
              const SizedBox(height: AppSpacing.xl),
              const NotionSection(),
              const SizedBox(height: AppSpacing.xl),
              const DataSection(),
              const SizedBox(height: AppSpacing.xl),
              Center(
                child: Text(
                  'Zeolite · 1.0.0\n'
                  'Your timetable and attendance stay on this device unless '
                  'you sign in, connect Notion, or check a sheet with AI. '
                  'Zeolite counts how the app is used either way.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: context.palette.textTertiary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The target lives in the header because everything below is computed
/// against it.
class _TargetHeader extends StatelessWidget {
  const _TargetHeader({required this.target, required this.onChanged});

  final double target;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              HeaderEyebrow('Settings'),
              SizedBox(height: 7),
              HeaderTitle('Minimum required'),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              HeaderNumber('${target.round()}', size: 46),
              const SizedBox(width: 12),
              const Expanded(
                child: Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: HeaderCaption(
                    'Any subject can override this from its own page.',
                    emphasis: 0.78,
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
          child: SliderTheme(
            data: SliderThemeData(
              activeTrackColor: Colors.white,
              inactiveTrackColor: Colors.white.withValues(alpha: 0.24),
              thumbColor: Colors.white,
              overlayColor: Colors.white.withValues(alpha: 0.16),
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            ),
            child: Slider(
              value: target.clamp(40, 100),
              min: 40,
              max: 100,
              divisions: 60,
              label: '${target.round()}%',
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}
