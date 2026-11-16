import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_theme.dart';
import '../../core/endpoints.dart';
import '../../services/feedback_mail.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';

/// Opens a draft in the email app. Nothing is sent from here; with no email
/// app to take it, the address is shown so it can be copied.
Future<void> sendFeedback(BuildContext context, WidgetRef ref) async {
  final String version = await ref.read(appVersionProvider.future);
  final int build = await ref.read(appBuildProvider.future);
  final Uri draft = FeedbackMail.draft(
    app: '$version ($build)',
    android: await FeedbackMail.androidVersion(),
  );
  bool opened;
  try {
    opened = await launchUrl(draft);
  } on PlatformException {
    opened = false;
  }
  if (opened || !context.mounted) return;
  await showAppDialog<void>(
    context: context,
    builder: (BuildContext context) => const NoEmailAppDialog(),
  );
}

class NoEmailAppDialog extends StatelessWidget {
  const NoEmailAppDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('No email app found'),
      content: SelectableText(
        'Write to ${Endpoints.support} from any email app.',
        style: const TextStyle(fontSize: AppType.bodyLarge, height: 1.4),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        TextButton(
          onPressed: () async {
            final ScaffoldMessengerState? messenger =
                ScaffoldMessenger.maybeOf(context);
            final NavigatorState navigator = Navigator.of(context);
            await Clipboard.setData(
              const ClipboardData(text: Endpoints.support),
            );
            navigator.pop();
            messenger?.showSnackBar(
              const SnackBar(content: Text('Address copied')),
            );
          },
          child: const Text('Copy address'),
        ),
      ],
    );
  }
}
