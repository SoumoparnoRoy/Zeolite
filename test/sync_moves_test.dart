import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/domain/sync/sync_moves.dart';
import 'package:zeolite/domain/sync/sync_target.dart';

RemoteLink _link(String key, String page) => RemoteLink(
      target: 'notion',
      kind: SyncKind.attendance,
      localKey: key,
      remoteId: page,
      localHash: 'h',
      remoteHash: 'h',
      origin: SyncOrigin.remote,
    );

RemoteState _page(String key, String page, String type) => RemoteState(
      kind: SyncKind.attendance,
      localKey: key,
      remoteId: page,
      hash: 'h',
      category: type,
    );

SyncItem _mark(String key, String? type) => SyncItem(
      kind: SyncKind.attendance,
      localKey: key,
      fields: <String, Object?>{'status': 'present', 'category': type},
    );

void main() {
  test('a lecture and a tutorial moved on one day keep their own pages', () {
    // The tutorial was imported first, so it sits at -1, but the timetable
    // puts the lecture earlier. The lecture keeps the subject's type.
    const String day = 'course-1:20260818';
    final SyncMoves moves = SyncMoves.find(
      local: <SyncItem>[_mark('$day:530', null), _mark('$day:580', 'Tutorial')],
      links: <RemoteLink>[
        _link('$day:-1', 'tutorial-page'),
        _link('$day:-2', 'lecture-page'),
      ],
      remote: <RemoteState>[
        _page('$day:-1', 'tutorial-page', 'tutorial'),
        _page('$day:-2', 'lecture-page', 'lecture'),
      ],
    );

    expect(
      <String, String>{
        for (final RemoteLink link in moves.moved) link.remoteId: link.localKey,
      },
      <String, String>{
        'tutorial-page': '$day:580',
        'lecture-page': '$day:530',
      },
    );
    expect(moves.forget, unorderedEquals(<String>['$day:-1', '$day:-2']));
  });
}
