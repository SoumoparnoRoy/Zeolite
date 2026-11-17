import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/core/endpoints.dart';
import 'package:zeolite/features/settings/help_screen.dart';
import 'package:zeolite/features/settings/help_topics.dart';
import 'package:zeolite/state/providers.dart';

const MethodChannel _urls = MethodChannel('plugins.flutter.io/url_launcher');
const MethodChannel _device = MethodChannel('zeolite/device');

Widget _screen({String? openQuestion, ThemeData? theme}) => ProviderScope(
      overrides: [
        appVersionProvider.overrideWith((Ref ref) async => '1.0.1'),
        appBuildProvider.overrideWith((Ref ref) async => 6),
      ],
      child: MaterialApp(
        theme: theme ?? AppTheme.light(),
        home: HelpScreen(openQuestion: openQuestion),
      ),
    );

HelpQuestion _byId(String id) =>
    helpQuestions.firstWhere((HelpQuestion q) => q.id == id);

void main() {
  late List<String> launched;

  setUp(() {
    launched = <String>[];
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_urls, (MethodCall call) async {
      launched.add((call.arguments as Map<Object?, Object?>)['url']! as String);
      return true;
    });
    messenger.setMockMethodCallHandler(
      _device,
      (MethodCall call) async => '16 (API 36)',
    );
  });

  Future<void> phoneSize(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  testWidgets('a question reads as collapsed, then expanded with its answer',
      (WidgetTester tester) async {
    await phoneSize(tester);
    final SemanticsHandle semantics = tester.ensureSemantics();
    final HelpQuestion q = _byId('skip-now');
    await tester.pumpWidget(_screen());
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.text(q.question)),
      matchesSemantics(
        label: q.question,
        isButton: true,
        hasExpandedState: true,
        isExpanded: false,
        hasTapAction: true,
        hasFocusAction: true,
        isFocusable: true,
      ),
    );
    expect(find.text(q.answer), findsNothing);

    await tester.tap(find.text(q.question));
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.text(q.question)),
      matchesSemantics(
        label: q.question,
        isButton: true,
        hasExpandedState: true,
        isExpanded: true,
        hasTapAction: true,
        hasFocusAction: true,
        isFocusable: true,
      ),
    );
    expect(find.text(q.answer), findsOneWidget);

    await tester.tap(find.text(q.question));
    await tester.pumpAndSettle();
    expect(find.text(q.answer), findsNothing);
    semantics.dispose();
  });

  testWidgets('a search result opens its question, expanded and on screen',
      (WidgetTester tester) async {
    await phoneSize(tester);
    // The last question, so the screen has to scroll to show it.
    final HelpQuestion last = helpSections.last.questions.last;
    await tester.pumpWidget(_screen(openQuestion: last.id));
    await tester.pumpAndSettle();

    expect(find.text(last.answer).hitTestable(), findsOneWidget);
    expect(find.text(_byId('skip-now').answer), findsNothing);
  });

  testWidgets('a question near the top opens without hiding the title',
      (WidgetTester tester) async {
    await phoneSize(tester);
    final HelpQuestion q = _byId('skip-budget');
    await tester.pumpWidget(_screen(openQuestion: q.id));
    await tester.pumpAndSettle();

    expect(find.text(q.answer).hitTestable(), findsOneWidget);
    expect(find.text('Help and FAQ').hitTestable(), findsOneWidget);
  });

  testWidgets('Send feedback reads at 4.5:1 on its card in every accent',
      (WidgetTester tester) async {
    await phoneSize(tester);
    for (final AccentColour accent in AccentColour.values) {
      for (final ThemeData theme in <ThemeData>[
        AppTheme.light(accent),
        AppTheme.dark(accent),
      ]) {
        await tester.pumpWidget(_screen(theme: theme));
        await tester.pumpAndSettle();

        final BuildContext context = tester.element(find.text('Send feedback'));
        final AppPalette p = context.palette;
        final Color ink = DefaultTextStyle.of(context).style.color!;
        expect(
          AppColors.contrast(ink, p.accentSoft),
          greaterThanOrEqualTo(4.5),
          reason: '${accent.label}, ${theme.brightness.name}',
        );
      }
    }
  });

  testWidgets('Send feedback at the bottom opens the feedback draft',
      (WidgetTester tester) async {
    await phoneSize(tester);
    await tester.pumpWidget(_screen());
    await tester.pumpAndSettle();

    final Finder link = find.text('Send feedback');
    await tester.ensureVisible(link);
    await tester.pumpAndSettle();
    await tester.tap(link);
    await tester.pumpAndSettle();

    final Uri draft = Uri.parse(launched.single);
    expect(draft.scheme, 'mailto');
    expect(draft.path, Endpoints.support);
    expect(draft.queryParameters['body'], contains('Zeolite 1.0.1 (6)'));
  });
}
