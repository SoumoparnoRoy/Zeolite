import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/endpoints.dart';
import '../../widgets/gradient_header.dart';

/// Shown in place of the app when the server says this build is too old.
///
/// No way past it on purpose: the server only raises its minimum when older
/// builds have stopped working with it, so carrying on would mean failures
/// with no explanation.
class UpdateRequiredScreen extends StatelessWidget {
  const UpdateRequiredScreen({super.key});

  static const String title = 'Update Zeolite';
  static const String button = 'Open the Play Store';

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: GradientScaffold(
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
                  Icons.system_update_rounded,
                  color: Colors.white,
                  size: 26,
                ),
              ),
              const SizedBox(height: 18),
              Semantics(header: true, child: const HeaderTitle(title)),
              const SizedBox(height: 8),
              const HeaderCaption(
                'This version no longer works with Zeolite\'s server. Update '
                'it to keep going. Your timetable and attendance stay on this '
                'device.',
                emphasis: 0.8,
              ),
            ],
          ),
        ),
        bottom: FilledButton(
          onPressed: () => launchUrl(
            Endpoints.playStore,
            mode: LaunchMode.externalApplication,
          ),
          child: const Text(button),
        ),
      ),
    );
  }
}
