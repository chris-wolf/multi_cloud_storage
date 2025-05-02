import 'dart:io';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/auth_io.dart';
import 'package:path/path.dart' as p; // avoid clash with 'path' param
import 'cloud_storage_provider.dart';

class GoogleDriveProvider extends CloudStorageProvider {
  late drive.DriveApi driveApi;
  bool _isAuthenticated = false;
  static const List<String> _scopes = [
    drive.DriveApi.driveFileScope,
    drive.DriveApi.driveScope,
  ];

  GoogleDriveProvider._create();

  static Future<GoogleDriveProvider?> connect() async {
    final client = await clientViaApplicationDefaultCredentials(
      scopes: _scopes,
    );

    final provider =  GoogleDriveProvider._create();
    provider.driveApi = drive.DriveApi(client);
    return provider;
  }

  void _checkAuth() {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }
  }

  static final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [
      'https://www.googleapis.com/auth/drive.file', // or 'drive' for full access
    ],
  );

  @override
  Future<String> uploadFile({
    required String localPath,
    required String remotePath,
    Map<String, dynamic>? metadata,
  }) async {
    _checkAuth();

    final file = File(localPath);
    final fileName = p.basename(remotePath);
    final folder = await _getOrCreateFolder(p.dirname(remotePath));

    final driveFile = drive.File()
      ..name = fileName
      ..parents = [folder.id!];

    final media = drive.Media(file.openRead(), await file.length());
    final uploadedFile = await driveApi.files.create(driveFile, uploadMedia: media);

    return uploadedFile.id!;
  }

  @override
  Future<String> downloadFile({
    required String remotePath,
    required String localPath,
  }) async {
    _checkAuth();

    final file = await _getFileByPath(remotePath);
    if (file == null) {
      throw Exception('File not found');
    }

    final output = File(localPath);
    final sink = output.openWrite();

    final mediaStream = await driveApi.files.get(
      file.id!,
      downloadOptions: drive.DownloadOptions.fullMedia,
    );

    if (mediaStream is drive.Media) {
      await mediaStream.stream.pipe(sink);
      await sink.close();
    } else {
      await sink.close();
      throw Exception('Unexpected response type while downloading file.');
    }

    return localPath;
  }

  @override
  Future<List<CloudFile>> listFiles({
    required String path,
    bool recursive = false,
  }) async {
    _checkAuth();

    final folder = await _getFolderByPath(path);
    if (folder == null) return [];

    final files = await driveApi.files.list(
      q: "'${folder.id}' in parents",
      $fields: 'files(id, name, size, modifiedTime, mimeType)',
    );

    return files.files?.map((file) {
      return CloudFile(
        path: p.join(path, file.name ?? ''),
        name: file.name ?? '',
        size: int.tryParse(file.size ?? '0') ?? 0,
        modifiedTime: file.modifiedTime != null
            ? file.modifiedTime!
            : DateTime.now(),
        isDirectory: file.mimeType == 'application/vnd.google-apps.folder',
        metadata: {
          'id': file.id,
          'mimeType': file.mimeType,
        },
      );
    }).toList() ??
        [];
  }

  Future<drive.File?> _getFolderByPath(String folderPath) async {
    final parts = p.split(folderPath);
    drive.File currentFolder = await _getRootFolder();

    for (final part in parts) {
      if (part.isEmpty) continue;

      final folder = await _getFolderByName(currentFolder.id!, part);
      if (folder == null) {
        return null; // Folder does not exist
      }
      currentFolder = folder;
    }

    return currentFolder;
  }

  @override
  Future<void> deleteFile(String path) async {
    _checkAuth();

    final file = await _getFileByPath(path);
    if (file != null) {
      await driveApi.files.delete(file.id!);
    }
  }

  @override
  Future<void> createDirectory(String path) async {
    _checkAuth();
    await _getOrCreateFolder(path);
  }

  @override
  Future<CloudFile> getFileMetadata(String path) async {
    _checkAuth();

    final file = await _getFileByPath(path);
    if (file == null) {
      throw Exception('File not found');
    }

    return CloudFile(
      path: path,
      name: file.name ?? '',
      size: int.tryParse(file.size ?? '0') ?? 0,
      modifiedTime: file.modifiedTime != null
          ? file.modifiedTime!
          : DateTime.now(),
      isDirectory: file.mimeType == 'application/vnd.google-apps.folder',
      metadata: {
        'id': file.id,
        'mimeType': file.mimeType,
      },
    );
  }

  Future<drive.File?> _getFileByPath(String filePath) async {
    final parts = p.split(filePath);
    drive.File currentFolder = await _getRootFolder();

    for (var i = 0; i < parts.length - 1; i++) {
      final folder = await _getFolderByName(currentFolder.id!, parts[i]);
      if (folder == null) return null;
      currentFolder = folder;
    }

    final fileName = parts.last;
    final files = await driveApi.files.list(
      q: "'${currentFolder.id}' in parents and name = '$fileName' and trashed = false",
      $fields: 'files(id, name, size, modifiedTime, mimeType)',
    );

    return files.files?.isNotEmpty == true ? files.files!.first : null;
  }

  Future<drive.File> _getOrCreateFolder(String folderPath) async {
    final parts = p.split(folderPath);
    drive.File currentFolder = await _getRootFolder();

    for (final part in parts) {
      if (part.isEmpty) continue;

      var folder = await _getFolderByName(currentFolder.id!, part);
      if (folder == null) {
        folder = await _createFolder(currentFolder.id!, part);
      }
      currentFolder = folder;
    }

    return currentFolder;
  }

  Future<drive.File> _getRootFolder() async {
    // In Drive API, the root folder ID is always 'root'
    return drive.File()..id = 'root';
  }

  Future<drive.File?> _getFolderByName(String parentId, String name) async {
    final files = await driveApi.files.list(
      q: "'$parentId' in parents and name = '$name' and mimeType = 'application/vnd.google-apps.folder' and trashed = false",
      $fields: 'files(id, name)',
    );
    return files.files?.isNotEmpty == true ? files.files!.first : null;
  }

  Future<drive.File> _createFolder(String parentId, String name) async {
    final folder = drive.File()
      ..name = name
      ..mimeType = 'application/vnd.google-apps.folder'
      ..parents = [parentId];

    return await driveApi.files.create(folder);
  }
}
