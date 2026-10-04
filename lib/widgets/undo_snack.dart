import 'dart:async';

import 'package:flutter/material.dart';

import '../state/actions/action_core.dart';
import '../state/app_providers.dart';

/// Reports [message] and offers to put the data back.
///
/// Takes the messenger and [core] rather than a context and a `WidgetRef`
/// because most of these actions unmount the widget that raised them — a row
/// just deleted, or a sheet that pops first.
///
/// The token is read now rather than when the button is pressed, since by then
/// a second delete may have replaced what is pending.
void showUndoSnack(
  ScaffoldMessengerState messenger,
  ActionCore core,
  String message,
) {
  final int? token = core.pendingUndoToken;
  final Completer<void> restoring = Completer<void>();

  messenger.hideCurrentSnackBar();
  final ScaffoldFeatureController<SnackBar, SnackBarClosedReason> shown =
      messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 6),
      // Flutter keeps a snackbar with an action up until it is tapped, and
      // this one follows the user onto every screen they open next.
      persist: false,
      action: token == null
          ? null
          : SnackBarAction(
              label: 'Undo',
              onPressed: () async {
                final bool restored =
                    await core.undo(token).whenComplete(restoring.complete);
                messenger.hideCurrentSnackBar();
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      restored
                          ? 'Put back'
                          : 'Too much has changed since — that can no longer '
                              'be undone.',
                    ),
                  ),
                );
              },
            ),
    ),
  );
  if (token == null) return;
  final UndoOnScreen onScreen = core.ref.read(undoOnScreenProvider.notifier);
  onScreen.shown();
  // A tap closes the bar at once, but the alert must judge the data the
  // restore leaves, not what it is about to remove.
  unawaited(shown.closed.then((SnackBarClosedReason reason) async {
    if (reason == SnackBarClosedReason.action) await restoring.future;
    onScreen.closed();
  }));
}
