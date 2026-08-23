import 'package:flutter/material.dart';

import '../state/providers.dart';

/// Reports [message] and offers to put the data back.
///
/// Takes the messenger and [actions] rather than a context and a `WidgetRef`
/// because most of these actions unmount the widget that raised them — a row
/// just deleted, or a sheet that pops first.
///
/// The token is read now rather than when the button is pressed, since by then
/// a second delete may have replaced what is pending.
void showUndoSnack(
  ScaffoldMessengerState messenger,
  TimetableActions actions,
  String message,
) {
  final int? token = actions.pendingUndoToken;

  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 6),
      action: token == null
          ? null
          : SnackBarAction(
              label: 'Undo',
              onPressed: () async {
                final bool restored = await actions.undo(token);
                messenger.hideCurrentSnackBar();
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      restored
                          ? 'Put back.'
                          : 'Too much has changed since — that can no longer '
                              'be undone.',
                    ),
                  ),
                );
              },
            ),
    ),
  );
}
