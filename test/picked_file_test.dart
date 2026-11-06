import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/features/settings/subjects_section.dart';
import 'package:zeolite/services/picked_file.dart';
import 'package:zeolite/state/timetable_image_reader.dart';

final class _Picked extends PlatformFile {
  _Picked(this.bytes);

  /// Null makes the read fail, as a file gone from the cache does.
  final Uint8List? bytes;

  @override
  String get name => 'sheet.png';

  @override
  Uri get uri => Uri.file('/cache/file_picker/1/sheet.png');

  @override
  Future<Uint8List> readAsBytes() async =>
      bytes ?? (throw const FileSystemException('gone'));

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Stands in for the system picker. `picked` null is the student backing out.
class _Platform extends FilePickerPlatform {
  _Platform({this.picked, this.clearFails = false});

  final PlatformFile? picked;
  final bool clearFails;
  int cleared = 0;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    dynamic Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async =>
      picked;

  @override
  Future<void> clearTemporaryFiles() async {
    cleared++;
    if (clearFails) throw const FileSystemException('busy');
  }
}

void main() {
  final FilePickerPlatform real = FilePickerPlatform.instance;
  tearDown(() => FilePickerPlatform.instance = real);

  _Platform using(_Platform platform) {
    FilePickerPlatform.instance = platform;
    return platform;
  }

  TimetableImageReader reader() {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    return container.read(timetableImageReaderProvider);
  }

  final Uint8List bytes = Uint8List.fromList(<int>[1, 2, 3]);

  group('a photo for the import and counts screens', () {
    test('leaves no copy once it has been read', () async {
      final _Platform platform = using(_Platform(picked: _Picked(bytes)));

      expect(await reader().pickImage(), bytes);
      expect(platform.cleared, 1);
    });

    test('leaves no copy when the read fails', () async {
      final _Platform platform = using(_Platform(picked: _Picked(null)));

      await expectLater(
        reader().pickImage(),
        throwsA(isA<FileSystemException>()),
      );
      expect(platform.cleared, 1);
    });

    test('leaves no copy when the picker is cancelled', () async {
      final _Platform platform = using(_Platform());

      expect(await reader().pickImage(), isNull);
      expect(platform.cleared, 1);
    });

    test('still returns the photo when clearing fails', () async {
      using(_Platform(picked: _Picked(bytes), clearFails: true));

      expect(await reader().pickImage(), bytes);
    });
  });

  group('a class log', () {
    Future<void> pick(WidgetTester tester) async {
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) => TextButton(
                onPressed: () => importClassLogFile(context, ref),
                child: const Text('Pick'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Pick'));
      await tester.pumpAndSettle();
    }

    testWidgets('leaves no copy when the file holds no rows',
        (WidgetTester tester) async {
      final _Platform platform =
          using(_Platform(picked: _Picked(Uint8List(0))));

      await pick(tester);

      expect(find.textContaining('No rows could be found'), findsOneWidget);
      expect(platform.cleared, 1);
    });

    testWidgets('leaves no copy when the picker is cancelled',
        (WidgetTester tester) async {
      final _Platform platform = using(_Platform());

      await pick(tester);

      expect(platform.cleared, 1);
    });
  });

  test('starting the app clears what earlier versions left', () {
    final String main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('PickedFile.clearAtStart()'));
  });

  test('start-up also removes a copy an interrupted read left for ML Kit',
      () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final Directory temp = Directory.systemTemp.createTempSync('zeolite_ocr');
    addTearDown(() => temp.deleteSync(recursive: true));
    const MethodChannel channel =
        MethodChannel('plugins.flutter.io/path_provider');
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => temp.path);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final _Platform platform = using(_Platform());

    final File left = File('${temp.path}/ocr_input')..writeAsBytesSync(bytes);
    await PickedFile.clearAtStart();

    expect(left.existsSync(), isFalse);
    expect(platform.cleared, 1);
  });
}
