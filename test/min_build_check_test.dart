import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/features/launch/update_required_screen.dart';
import 'package:zeolite/services/server/min_build_check.dart';
import 'package:zeolite/state/providers.dart';

MinBuildCheck _answering(Future<http.Response> Function() reply) =>
    MinBuildCheck(
      httpClient: MockClient((_) => reply()),
      baseUri: Uri.parse('https://service.invalid'),
    );

MinBuildCheck _saying(int minBuild) =>
    _answering(() async => http.Response('{"minBuild": $minBuild}', 200));

class _Stored extends SettingsController {
  _Stored(this.initial);

  final AppSettings initial;

  @override
  Future<AppSettings> build() async => initial;
}

void main() {
  group('the answer', () {
    test('blocks only a build below the minimum', () async {
      expect(await _saying(5).isTooOld(4), isTrue);
      expect(await _saying(5).isTooOld(5), isFalse);
      expect(await _saying(5).isTooOld(6), isFalse);
      expect(await _saying(0).isTooOld(1), isFalse);
    });

    test('a refusal, a failure or a garbled reply lets the app open', () async {
      expect(await _answering(() async => http.Response('', 503)).isTooOld(1),
          isFalse);
      expect(
          await _answering(() async => throw http.ClientException('offline'))
              .isTooOld(1),
          isFalse);
      expect(
          await _answering(() async => http.Response('<html>', 200))
              .isTooOld(1),
          isFalse);
      expect(
          await _answering(() async => http.Response('{"minBuild": "9"}', 200))
              .isTooOld(1),
          isFalse);
    });

    test('so does a server that takes more than ten seconds', () {
      expect(MinBuildCheck.timeout, const Duration(seconds: 10));
      fakeAsync((FakeAsync async) {
        bool? tooOld;
        _answering(() => Completer<http.Response>().future)
            .isTooOld(1)
            .then((bool v) => tooOld = v);
        async.elapse(const Duration(seconds: 9));
        expect(tooOld, isNull, reason: 'still waiting');
        async.elapse(const Duration(seconds: 2));
        expect(tooOld, isFalse);
      });
    });
  });

  group('who is asked', () {
    Future<bool> askedWith(AppSettings settings, List<Uri> calls) async {
      final ProviderContainer container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(() => _Stored(settings)),
          appBuildProvider.overrideWith((Ref ref) async => 3),
          minBuildCheckProvider.overrideWithValue(MinBuildCheck(
            httpClient: MockClient((http.Request request) async {
              calls.add(request.url);
              return http.Response('{"minBuild": 4}', 200);
            }),
            baseUri: Uri.parse('https://service.invalid'),
          )),
        ],
      );
      addTearDown(container.dispose);
      container.listen(buildTooOldProvider, (_, __) {});
      await container.read(settingsProvider.future);
      return container.read(buildTooOldProvider.future);
    }

    test('an adult with an old build is told to update', () async {
      final List<Uri> calls = <Uri>[];
      expect(
        await askedWith(
          const AppSettings(
              adult: true, shareUsage: false, sendCrashReports: false),
          calls,
        ),
        isTrue,
      );
      expect(calls.single.path, '/version');
    });

    test('an under-18 is never asked, since nothing goes to the server',
        () async {
      final List<Uri> calls = <Uri>[];
      expect(await askedWith(const AppSettings(adult: false), calls), isFalse);
      expect(calls, isEmpty);
    });

    test('nobody is asked before the first-run answers are in', () async {
      final List<Uri> calls = <Uri>[];
      expect(await askedWith(const AppSettings(), calls), isFalse);
      expect(calls, isEmpty);
    });
  });

  testWidgets('the update screen has no way past it but the store',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      home: const UpdateRequiredScreen(),
    ));

    expect(find.text(UpdateRequiredScreen.title), findsOneWidget);
    expect(find.text(UpdateRequiredScreen.button), findsOneWidget);
    final PopScope<Object?> scope = tester.widget(find.byType(PopScope));
    expect(scope.canPop, isFalse);
  });
}
