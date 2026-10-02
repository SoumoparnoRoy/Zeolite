import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../services/launcher_icon_service.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';

import 'settings_rows.dart';

/// Deliberately its own choice rather than following the accent: swapping the
/// alias can take the app down with it, and the accent swatches are tapped
/// through freely.
class LauncherIconScreen extends ConsumerWidget {
  const LauncherIconScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final LauncherIcon inForce =
        ref.watch(launcherIconProvider).value ?? LauncherIcon.standard;

    return PushScaffold(
      title: 'Launcher icon',
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
          sliver: SliverToBoxAdapter(
            child: SettingsNoted(
              note: 'Zeolite may close while the icon changes, and your home '
                  'screen can take a moment to catch up. A shortcut you '
                  'pinned to the old icon stops working.',
              child: SurfaceCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: <Widget>[
                    for (final LauncherIcon icon in LauncherIcon.values) ...[
                      if (icon.index > 0) const Divider(indent: 72),
                      SettingsRadioRow(
                        leading: ClipRRect(
                          borderRadius:
                              BorderRadius.circular(AppSpacing.radiusSm + 2),
                          child: Image.asset(
                            icon.preview,
                            width: 46,
                            height: 46,
                            filterQuality: FilterQuality.medium,
                          ),
                        ),
                        title: icon.label,
                        selected: icon == inForce,
                        onTap: () {
                          if (icon == inForce) return;
                          unawaited(ref
                              .read(launcherIconProvider.notifier)
                              .select(icon));
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
