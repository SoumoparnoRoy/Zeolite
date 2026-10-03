import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/words.dart';
import '../../data/settings/app_settings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';

import 'settings_pages.dart';
import 'settings_rows.dart';
import 'settings_search.dart';

/// The menu: the attendance target, then a row per page, grouped the way a
/// student would guess where something lives.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
              SettingsSearchField(controller: _search, hint: 'Search settings'),
              const SizedBox(height: AppSpacing.xl),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _search,
                builder: (BuildContext context, TextEditingValue value, _) =>
                    value.text.trim().isEmpty
                        ? const _Menu()
                        : _Results(
                            query: value.text,
                            onTarget: () {
                              _search.clear();
                              FocusScope.of(context).unfocus();
                            },
                          ),
              ),
              const SizedBox(height: AppSpacing.xl),
              Center(
                child: Text(
                  'Zeolite · 1.0.0\n'
                  'Your timetable and attendance stay on this device unless '
                  'you sign in, connect Notion, or check a sheet with AI. '
                  'Zeolite counts how the app is used either way.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: AppType.bodySmall,
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

class _Menu extends StatelessWidget {
  const _Menu();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final SettingsGroup group in SettingsGroup.values) ...<Widget>[
          if (group.index > 0) const SizedBox(height: AppSpacing.xl),
          SectionHeader(group.label),
          GroupedRows(
            children: <Widget>[
              for (final SettingsItem item in SettingsItem.values)
                if (item.group == group) SettingsItemRow(item),
            ],
          ),
        ],
      ],
    );
  }
}

class _Results extends ConsumerWidget {
  const _Results({required this.query, required this.onTarget});

  final String query;
  final VoidCallback onTarget;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<SettingsTopic> found = searchSettings(query);
    if (found.isEmpty) {
      return SurfaceCard(
        child: SettingsHint('Nothing in Settings matches "${query.trim()}".'),
      );
    }
    return GroupedRows(
      children: <Widget>[
        for (final SettingsTopic topic in found)
          SettingsRow(
            icon: topic.item?.icon ?? Icons.percent_rounded,
            title: topic.title,
            // Where it lives, so the next visit can go straight there.
            value: switch (topic.item) {
              null => 'Top of Settings',
              final SettingsItem item when item.title == topic.title =>
                item.group.label,
              final SettingsItem item => item.title,
            },
            onTap: () {
              FocusScope.of(context).unfocus();
              topic.item == null ? onTarget() : topic.item!.open(context, ref);
            },
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
              HeaderNumber('${target.round()}', size: AppType.figureLarge),
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
              label: Words.percent(target),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}
