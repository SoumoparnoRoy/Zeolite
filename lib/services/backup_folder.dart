import 'dart:convert';
import 'dart:typed_data';

import 'package:saf_stream/saf_stream.dart';
import 'package:saf_stream/saf_stream_platform_interface.dart';
import 'package:saf_util/saf_util.dart';
import 'package:saf_util/saf_util_platform_interface.dart';

/// One file in the chosen folder. The SAF types stop here.
class BackupFile {
  const BackupFile({required this.name, required this.uri});

  final String name;
  final String uri;
}

/// A folder the user chose once, that the app can still write to days later.
///
/// The save dialog grants access for that dialog only, so an unattended backup
/// cannot use it. This takes a *persistable* grant instead, which survives
/// reboots and updates and costs no manifest permission — the user's own pick
/// is what authorises it.
class BackupFolder {
  BackupFolder({SafUtil? util, SafStream? stream})
      : _util = util ?? SafUtil(),
        _stream = stream ?? SafStream();

  final SafUtil _util;
  final SafStream _stream;

  /// Our own folder inside the user's pick, so choosing Documents does not
  /// scatter files through it.
  static const String folderName = 'Zeolite';

  /// Opens the folder picker and keeps the grant. Null if the user backed out.
  ///
  /// [initialUri] is where it opens, and only a hint: some pickers ignore it.
  Future<BackupFile?> choose({String? initialUri}) async {
    final SafDocumentFile? picked = await _util.pickDirectory(
      initialUri: initialUri,
      writePermission: true,
      persistablePermission: true,
    );
    if (picked == null) return null;
    return BackupFile(name: picked.name, uri: picked.uri);
  }

  /// Both halves are needed: a grant survives in the system's list after the
  /// folder behind it is deleted, so the permission alone points at nothing.
  Future<bool> isUsable(String treeUri) async {
    try {
      final bool granted = await _util.hasPersistedPermission(
        treeUri,
        checkRead: true,
        checkWrite: true,
      );
      return granted && await _util.exists(treeUri, true);
    } catch (_) {
      return false;
    }
  }

  /// The `Zeolite` folder inside [treeUri], created if it is not there. Not
  /// stored, so deleting it from a file manager heals on the next backup.
  ///
  /// A tree that is already ours is taken as the destination: the picker
  /// reopens inside it, so otherwise every re-pick nests another `Zeolite`.
  Future<String> resolveFolder(String treeUri) async {
    // Its own uri, not the tree's: a bare tree uri is not a document, and the
    // pickers take the folder to open in as one.
    final SafDocumentFile? ours = await _ourFolder(treeUri);
    if (ours != null) return ours.uri;
    final SafDocumentFile dir = await _util.mkdirp(treeUri, <String>[folderName]);
    return dir.uri;
  }

  /// [treeUri] when it is a `Zeolite` folder in its own right. By name, which
  /// is what the user reads in the picker.
  Future<SafDocumentFile?> _ourFolder(String treeUri) async {
    try {
      final SafDocumentFile? dir = await _util.documentFileFromUri(treeUri, true);
      return dir?.name == folderName ? dir : null;
    } catch (_) {
      return null;
    }
  }

  /// A backup to restore, chosen from [initialUri].
  Future<BackupFile?> pickFile({String? initialUri}) async {
    final SafDocumentFile? picked = await _util.pickFile(initialUri: initialUri);
    if (picked == null) return null;
    return BackupFile(name: picked.name, uri: picked.uri);
  }

  Future<Uint8List> readBytes(String uri) => _stream.readFileBytes(uri);

  Future<String> writeJson(String folderUri, String fileName, String json) async {
    final Uint8List bytes = Uint8List.fromList(utf8.encode(json));
    final SafNewFile written = await _stream.writeFileBytes(
      folderUri,
      fileName,
      'application/json',
      bytes,
      overwrite: true,
    );
    return written.uri.toString();
  }

  Future<List<BackupFile>> list(String folderUri) async {
    final List<SafDocumentFile> found = await _util.list(folderUri);
    return <BackupFile>[
      for (final SafDocumentFile f in found)
        if (!f.isDir) BackupFile(name: f.name, uri: f.uri),
    ];
  }

  Future<void> delete(String uri) => _util.delete(uri, false);

  Future<void> release(String treeUri) =>
      _util.releasePersistedPermission(treeUri, read: true, write: true);
}
