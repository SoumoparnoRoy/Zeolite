import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../data/settings/app_settings.dart';
import '../../services/launcher_icon_service.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';

import 'settings_rows.dart';

class AppearanceSection extends ConsumerWidget {
  const AppearanceSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();
    final SettingsController controller = ref.read(settingsProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHeader('Appearance'),
        SurfaceCard(
          child: _SegmentedRow(
            count: AppThemeMode.values.length,
            itemBuilder: (BuildContext context, int i) => _ThemeOption(
              mode: AppThemeMode.values[i],
              selected: settings.themeMode == AppThemeMode.values[i],
              onTap: () => controller.save(
                settings.copyWith(themeMode: AppThemeMode.values[i]),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        SettingsHint(
          settings.themeMode == AppThemeMode.system
              ? 'Follows your device setting, switching automatically when '
                  'it does.'
              : 'Always ${settings.themeMode.label.toLowerCase()}, whatever '
                  'your device is set to.',
        ),
        const SizedBox(height: AppSpacing.md),
        SurfaceCard(
          child: _SegmentedRow(
            count: AccentColour.values.length,
            phoneColumns: 4,
            itemBuilder: (BuildContext context, int i) => _AccentOption(
              accent: AccentColour.values[i],
              selected: settings.accentColour == AccentColour.values[i],
              onTap: () => controller.save(
                settings.copyWith(accentColour: AccentColour.values[i]),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        SettingsHint('${settings.accentColour.label} tints the headers, the '
            'buttons and every highlight. It stays on this device.'),
        const SizedBox(height: AppSpacing.md),
        SurfaceCard(
          child: _SegmentedRow(
            count: LaunchAnimation.values.length,
            itemBuilder: (BuildContext context, int i) => _LaunchOption(
              animation: LaunchAnimation.values[i],
              selected: settings.launchAnimation == LaunchAnimation.values[i],
              onTap: () => controller.save(
                settings.copyWith(
                  launchAnimation: LaunchAnimation.values[i],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        // Not a switch reading "Skip launch animation": it skips
        // nothing, and a control that lies about what it does is worse
        // than a longer label.
        const SettingsHint('The launch animation. Short plays the wordmark '
            'only, about a second.'),
        const SizedBox(height: AppSpacing.sm),
        SurfaceCard(
          padding: EdgeInsets.zero,
          child: SettingsRow(
            icon: Icons.apps_rounded,
            title: 'Launcher icon',
            value: ref.watch(launcherIconProvider).value?.label ??
                LauncherIcon.standard.label,
            onTap: () => _pickLauncherIcon(context, ref),
          ),
        ),
      ],
    );
  }

  /// Deliberately its own picker rather than following the accent: swapping
  /// the alias can take the app down with it, and the accent swatches are
  /// tapped through freely.
  Future<void> _pickLauncherIcon(BuildContext context, WidgetRef ref) async {
    final LauncherIcon inForce =
        ref.read(launcherIconProvider).value ?? LauncherIcon.standard;
    final LauncherIcon? chosen = await showDialog<LauncherIcon>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: context.palette.surfaceHigh,
        title: const Text('Launcher icon'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.sm,
              children: <Widget>[
                for (final LauncherIcon icon in LauncherIcon.values)
                  _LauncherIconOption(
                    icon: icon,
                    selected: icon == inForce,
                    onTap: () => Navigator.of(context).pop(icon),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Zeolite may close while the icon changes, and your home screen '
              'can take a moment to catch up. A shortcut you pinned to the old '
              'icon stops working.',
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: context.palette.textTertiary,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (chosen == null) return;
    await ref.read(launcherIconProvider.notifier).select(chosen);
  }
}

class DisplaySection extends ConsumerWidget {
  const DisplaySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();
    final SettingsController controller = ref.read(settingsProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHeader('Display'),
        SurfaceCard(
          padding: EdgeInsets.zero,
          child: SettingsSwitchRow(
            icon: Icons.schedule_rounded,
            title: '24-hour time',
            subtitle: settings.use24HourTime ? '14:30' : '2:30 PM',
            value: settings.use24HourTime,
            onChanged: (bool v) =>
                controller.save(settings.copyWith(use24HourTime: v)),
          ),
        ),
      ],
    );
  }
}

/// One of the three theme choices, shown as a tappable tile.
class _LauncherIconOption extends StatelessWidget {
  const _LauncherIconOption({
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final LauncherIcon icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Semantics(
      label: icon.label,
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xs),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                  border: Border.all(
                    color: selected ? p.accent : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                  child: Image.asset(
                    icon.preview,
                    width: 52,
                    height: 52,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                icon.label,
                style: TextStyle(
                  fontSize: 11,
                  color: selected ? p.accent : p.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Slow enough to read as the fill rising, and the curve the tab bar uses.
const Duration _toggleDuration = Duration(milliseconds: 220);
const Curve _toggleCurve = Curves.easeOutCubic;

/// A row of equal cells, the same size on a phone and on a tablet — left to
/// stretch, three across a tablet's content column stop reading as buttons.
class _SegmentedRow extends StatelessWidget {
  const _SegmentedRow({
    required this.count,
    required this.itemBuilder,
    this.phoneColumns,
  });

  static const double _maxWidth = 400;

  static const double _maxWrappedCell = 56;

  final int count;
  final Widget Function(BuildContext, int) itemBuilder;

  /// Wraps into this many columns under [AppScale.phoneWidth].
  final int? phoneColumns;

  @override
  Widget build(BuildContext context) {
    final MediaQueryData mq = MediaQuery.of(context);
    final TextScaler scaler = mq.textScaler;
    final bool wrapped =
        phoneColumns != null && mq.size.shortestSide <= AppScale.phoneWidth;
    final int columns = wrapped ? phoneColumns! : count;
    final double maxWidth = wrapped
        ? columns * _maxWrappedCell + (columns - 1) * AppSpacing.sm
        : _maxWidth;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: MediaQuery(
          // The viewer's own scaling still applies; only our ramp comes off.
          data: mq.copyWith(
            textScaler: scaler is ScaledText ? scaler.inner : scaler,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (int first = 0; first < count; first += columns) ...<Widget>[
                if (first > 0) const SizedBox(height: AppSpacing.sm),
                Row(
                  children: <Widget>[
                    for (int c = 0; c < columns; c++) ...<Widget>[
                      if (c > 0) const SizedBox(width: AppSpacing.sm),
                      // Empty columns keep the short last row lined up.
                      Expanded(
                        child: first + c < count
                            ? itemBuilder(context, first + c)
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One cell: the tint sits below it when off and rises to fill it when picked.
class _SegmentedCell extends StatelessWidget {
  const _SegmentedCell({
    required this.selected,
    required this.onTap,
    required this.child,
    this.semanticsLabel,
    this.square = false,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget child;
  final String? semanticsLabel;

  /// Squared off, so a round swatch is inset the same on all four sides.
  final bool square;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    Widget cell = ClipRRect(
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Stack(
        children: <Widget>[
          Positioned.fill(child: ColoredBox(color: p.surfaceHigh)),
          Positioned.fill(
            child: AnimatedFractionallySizedBox(
              duration: _toggleDuration,
              curve: _toggleCurve,
              alignment: Alignment.bottomCenter,
              heightFactor: selected ? 1 : 0,
              child: ColoredBox(color: p.accentSoft),
            ),
          ),
          // An unpositioned stack child is laid out loose, so without this
          // the cell is only tappable at its left edge.
          SizedBox(
            width: double.infinity,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                child: square
                    ? child
                    : Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.lg,
                        ),
                        child: child,
                      ),
              ),
            ),
          ),
        ],
      ),
    );

    if (square) cell = AspectRatio(aspectRatio: 1, child: cell);

    if (semanticsLabel == null) return cell;
    return Semantics(
      label: semanticsLabel,
      selected: selected,
      button: true,
      child: cell,
    );
  }
}

/// Below this the tick stops reading; above it the swatch reads as a button.
const double _minSwatch = 22;
const double _maxSwatch = 36;

class _AccentOption extends StatelessWidget {
  const _AccentOption({
    required this.accent,
    required this.selected,
    required this.onTap,
  });

  final AccentColour accent;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    // The swatch has to show the accent being offered, not the one in force,
    // so it is drawn from that accent's own palette at the current brightness.
    final AppPalette sample =
        (p.brightness == Brightness.dark ? AppPalette.dark : AppPalette.light)
            .withAccent(accent);

    return _SegmentedCell(
      selected: selected,
      onTap: onTap,
      semanticsLabel: accent.label,
      square: true,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          final double swatch =
              (c.maxWidth - AppSpacing.sm * 2).clamp(_minSwatch, _maxSwatch);
          return Center(
            child: AnimatedContainer(
              duration: _toggleDuration,
              curve: _toggleCurve,
              width: swatch,
              height: swatch,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: sample.accentGradient,
                // Slate on a dark card is barely a shape without the ring.
                border: Border.all(
                  color: selected ? sample.accent : p.outline,
                  width: 2,
                ),
              ),
              child: AnimatedScale(
                duration: _toggleDuration,
                curve: Curves.easeOutBack,
                scale: selected ? 1 : 0.4,
                child: AnimatedOpacity(
                  duration: _toggleDuration,
                  opacity: selected ? 1 : 0,
                  child: Icon(Icons.check_rounded,
                      size: swatch * 0.55, color: Colors.white),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _LaunchOption extends StatelessWidget {
  const _LaunchOption({
    required this.animation,
    required this.selected,
    required this.onTap,
  });

  final LaunchAnimation animation;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return _SegmentedCell(
      selected: selected,
      onTap: onTap,
      child: Column(
        children: <Widget>[
          TweenAnimationBuilder<Color?>(
            duration: _toggleDuration,
            curve: _toggleCurve,
            tween: ColorTween(end: selected ? p.accent : p.textSecondary),
            builder: (BuildContext context, Color? tone, Widget? _) => Icon(
              animation == LaunchAnimation.full
                  ? Icons.auto_awesome_rounded
                  : Icons.bolt_rounded,
              size: 22,
              color: tone,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          AnimatedDefaultTextStyle(
            duration: _toggleDuration,
            curve: _toggleCurve,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              color: selected ? p.accent : p.textTertiary,
            ),
            child: Text(animation.label),
          ),
        ],
      ),
    );
  }
}

class _ThemeOption extends StatelessWidget {
  const _ThemeOption({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final AppThemeMode mode;
  final bool selected;
  final VoidCallback onTap;

  IconData get _icon => switch (mode) {
        AppThemeMode.system => Icons.brightness_auto_rounded,
        AppThemeMode.light => Icons.light_mode_rounded,
        AppThemeMode.dark => Icons.dark_mode_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return _SegmentedCell(
      selected: selected,
      onTap: onTap,
      child: Column(
        children: <Widget>[
          TweenAnimationBuilder<Color?>(
            duration: _toggleDuration,
            curve: _toggleCurve,
            tween: ColorTween(end: selected ? p.accent : p.textSecondary),
            builder: (BuildContext context, Color? tone, Widget? _) =>
                Icon(_icon, size: 22, color: tone),
          ),
          const SizedBox(height: AppSpacing.sm),
          AnimatedDefaultTextStyle(
            duration: _toggleDuration,
            curve: _toggleCurve,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              color: selected ? p.accent : p.textTertiary,
            ),
            child: Text(
              // "Match system" is too wide for a third of the row.
              mode == AppThemeMode.system ? 'System' : mode.label,
            ),
          ),
        ],
      ),
    );
  }
}
