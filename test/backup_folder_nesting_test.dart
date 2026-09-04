import 'package:flutter_test/flutter_test.dart';
import 'package:saf_util/saf_util.dart';
import 'package:saf_util/saf_util_platform_interface.dart';
import 'package:zeolite/services/backup_folder.dart';

/// Answers about a tree without a device behind it: the picker hands back
/// whichever folder was showing, and everything here turns on its name.
class _Saf extends SafUtil {
  _Saf(this.name);

  /// What the chosen tree is called, or null for a tree that cannot be read.
  final String? name;

  final List<String> made = <String>[];

  @override
  Future<SafDocumentFile?> documentFileFromUri(String uri, bool? isDir) async {
    if (name == null) return null;
    return SafDocumentFile(
      uri: '$uri/document/${Uri.encodeComponent('primary:')}$name',
      name: name!,
      isDir: true,
      length: 0,
      lastModified: 0,
    );
  }

  @override
  Future<SafDocumentFile> mkdirp(String uri, List<String> path) async {
    made.add(path.join('/'));
    return SafDocumentFile(
      uri: '$uri/${path.join('/')}',
      name: path.last,
      isDir: true,
      length: 0,
      lastModified: 0,
    );
  }
}

void main() {
  test('choosing the backup folder again does not nest another inside it',
      () async {
    final _Saf saf = _Saf(BackupFolder.folderName);

    final String resolved = await BackupFolder(util: saf)
        .resolveFolder('content://tree/primary%3AZeolite');

    // The folder's own document uri, which is what a picker can open at.
    expect(resolved, 'content://tree/primary%3AZeolite/document/primary%3AZeolite');
    expect(saf.made, isEmpty);
  });

  test('any other folder still gets ours made inside it', () async {
    final _Saf saf = _Saf('Documents');

    final String resolved = await BackupFolder(util: saf)
        .resolveFolder('content://tree/primary%3ADocuments');

    expect(resolved, endsWith('/${BackupFolder.folderName}'));
    expect(saf.made, <String>[BackupFolder.folderName]);
  });

  test('a tree that cannot be read is treated as somewhere else', () async {
    final _Saf saf = _Saf(null);

    await BackupFolder(util: saf).resolveFolder('content://tree/gone');

    expect(saf.made, <String>[BackupFolder.folderName]);
  });
}
