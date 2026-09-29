import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/features/settings/licences_screen.dart';

void main() {
  test('an entry naming two packages is listed under both, in name order',
      () async {
    final List<PackageLicences> grouped =
        await groupLicences(Stream<LicenseEntry>.fromIterable(<LicenseEntry>[
      const LicenseEntryWithLineBreaks(<String>['sqflite'], 'BSD'),
      const LicenseEntryWithLineBreaks(<String>['Plus Jakarta Sans'], 'OFL'),
      const LicenseEntryWithLineBreaks(
        <String>['angle', 'sqflite'],
        'shared',
      ),
    ]));

    expect(
      grouped.map((PackageLicences p) => p.package),
      <String>['angle', 'Plus Jakarta Sans', 'sqflite'],
    );
    expect(grouped.last.entries, hasLength(2));
  });
}
