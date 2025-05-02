import 'dart:io';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/auth_io.dart';
import 'package:path/path.dart' as path;
import 'cloud_storage_provider.dart';

class GoogleDriveProvider implements CloudStorageProvider {
  late drive.DriveApi _driveApi;
  bool _isAuthenticated = false;
  final String _clientId;
  final String _clientSecret;
  final List<String> _scopes = [
    drive.DriveApi.driveFileScope,
    drive.DriveApi.driveScope,
  ];

  GoogleDriveProvider({
    required String clientId,
    required String clientSecret,
  })  : _clientId = clientId,
        _clientSecret = clientSecret;

  @override
  Future<void> authenticate() async {
    final client = await clientViaUserConsent(
      ClientId(_clientId, _clientSecret),
      _scopes,
      prompt: (String url) async {
        // TODO: Implement proper OAuth2 flow with a web view or browser
        print('Please go to this URL and authorize: $url');
      },
    );

    _driveApi = drive.DriveApi(client);
    _isAuthenticated = true;
  }

  @override
  Future<String> uploadFile({
    required String localPath,
    required String remotePath,
    Map<String, dynamic>? metadata,
  }) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    final file = File(localPath);
    final fileName = path.basename(localPath);
    final parentFolder = await _getOrCreateFolder(path.dirname(remotePath));

    final drive.File driveFile = drive.File()
      ..name = fileName
      ..parents = [parentFolder.id!];

    final media = drive.Media(file.openRead(), file.lengthSync());
    final uploadedFile =
        await _driveApi.files.create(driveFile, uploadMedia: media);

    return uploadedFile.id!;
  }

  @override
  Future<String> downloadFile({
    required String remotePath,
    required String localPath,
  }) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    final file = await _getFileByPath(remotePath);
    if (file == null) {
      throw Exception('File not found');
    }

    final output = File(localPath);
    final sink = output.openWrite();
    await _driveApi.files
        .get(file.id!, downloadOptions: drive.DownloadOptions.FullMedia)
        .then((response) => response.stream.pipe(sink));

    return localPath;
  }

  @override
  Future<List<CloudFile>> listFiles({
    required String path,
    bool recursive = false,
  }) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    final folder = await _getFolderByPath(path);
    if (folder == null) {
      return [];
    }

    final files = await _driveApi.files.list(
      q: "'${folder.id}' in parents",
      fields: 'files(id, name, size, modifiedTime, mimeType)',
    );

    return files.files!
        .map((file) => CloudFile(
              path: path.join(path, file.name!),
              name: file.name!,
              size: int.parse(file.size ?? '0'),
              modifiedTime: DateTime.parse(file.modifiedTime!),
              isDirectory:
                  file.mimeType == 'application/vnd.google-apps.folder',
              metadata: {
                'id': file.id,
                'mimeType': file.mimeType,
              },
            ))
        .toList();
  }

  @override
  Future<void> deleteFile(String path) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    final file = await _getFileByPath(path);
    if (file != null) {
      await _driveApi.files.delete(file.id!);
    }
  }

  @override
  Future<void> createDirectory(String path) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    await _getOrCreateFolder(path);
  }

  @override
  Future<CloudFile> getFileMetadata(String path) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    final file = await _getFileByPath(path);
    if (file == null) {
      throw Exception('File not found');
    }

    return CloudFile(
      path: path,
      name: file.name!,
      size: int.parse(file.size ?? '0'),
      modifiedTime: DateTime.parse(file.modifiedTime!),
      isDirectory: file.mimeType == 'application/vnd.google-apps.folder',
      metadata: {
        'id': file.id,
        'mimeType': file.mimeType,
      },
    );
  }

  Future<drive.File?> _getFileByPath(String filePath) async {
    final parts = filePath.split('/');
    var currentFolder = await _getRootFolder();

    for (var i = 0; i < parts.length - 1; i++) {
      final folder = await _getFolderByName(currentFolder.id!, parts[i]);
      if (folder == null) {
        return null;
      }
      currentFolder = folder;
    }

    final fileName = parts.last;
    final files = await _driveApi.files.list(
      q: "'${currentFolder.id}' in parents and name = '$fileName'",
      fields: 'files(id, name, size, modifiedTime, mimeType)',
    );

    return files.files?.isNotEmpty == true ? files.files!.first : null;
  }

  Future<drive.File> _getOrCreateFolder(String folderPath) async {
    final parts = folderPath.split('/');
    var currentFolder = await _getRootFolder();

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
    final files = await _driveApi.files.list(
      q: "name = 'root' and mimeType = 'application/vnd.google-apps.folder'",
      fields: 'files(id, name)',
    );
    return files.files!.first;
  }

  Future<drive.File?> _getFolderByName(String parentId, String name) async {
    final files = await _driveApi.files.list(
      q: "'$parentId' in parents and name = '$name' and mimeType = 'application/vnd.google-apps.folder'",
      fields: 'files(id, name)',
    );
    return files.files?.isNotEmpty == true ? files.files!.first : null;
  }

  Future<drive.File> _createFolder(String parentId, String name) async {
    final folder = drive.File()
      ..name = name
      ..mimeType = 'application/vnd.google-apps.folder'
      ..parents = [parentId];

    return await _driveApi.files.create(folder);
  }
}
