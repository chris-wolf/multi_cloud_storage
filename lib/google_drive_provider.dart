import 'dart:io';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:http/retry.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart';

import '../main.dart'; // Assuming your global logger is accessible via main.dart
import 'cloud_storage_provider.dart';
import 'file_log_output.dart';
import 'multi_cloud_storage.dart';

// 3. The Logger Instance: Your global logger object
final logger = Logger(
  filter: MyFilter(),      // Use your custom filter
  output: FileLogOutput(),   // Use your custom file output
  printer: PrettyPrinter(
    methodCount: 0,
    colors: false, // Set to false for file output
    printTime: true,
  ),
);

class GoogleDriveProvider extends CloudStorageProvider {
  late drive.DriveApi driveApi;
  bool _isAuthenticated = false;

  static GoogleSignIn? _googleSignIn;
  static GoogleDriveProvider? _instance;

  GoogleDriveProvider._create();

  static GoogleDriveProvider? get instance => _instance;

  @override
  Future<String?> loggedInUserDisplayName() async {
    return _googleSignIn?.currentUser?.displayName;
  }

  static Future<GoogleDriveProvider?> connect(
      {bool forceInteractive = false}) async {
    logger.i("connect Google Drive,  forceInteractive: $forceInteractive");
    if (_instance != null && _instance!._isAuthenticated && !forceInteractive) {
      return _instance;
    }

    _googleSignIn ??= GoogleSignIn(
      scopes: [
        MultiCloudStorage.cloudAccess == CloudAccessType.appStorage
            ? drive.DriveApi.driveAppdataScope
            : drive.DriveApi.driveScope,
      ],
    );

    GoogleSignInAccount? account;

    try {
      if (!forceInteractive) {
        account = await _googleSignIn!.signInSilently();
      }
      account ??= await _googleSignIn!.signIn();

      if (account == null) {
        logger.i('User cancelled Google Sign-In process.');
        return null;
      }

      final bool hasPermissions =
      await _googleSignIn!.requestScopes(_googleSignIn!.scopes);
      if (!hasPermissions) {
        logger.w('User did not grant necessary Google Drive permissions.');
        await signOut();
        return null;
      }

      final client = await _googleSignIn!.authenticatedClient();

      if (client == null) {
        logger.e(
            'Failed to get authenticated Google client after permissions were granted. Can happen if auth flow is interrupted.');
        await signOut();
        return null;
      }

      final retryClient = RetryClient(
        client,
        retries: 3,
        when: (response) =>
            {500, 502, 503, 504}.contains(response.statusCode), // Removed 401/403
        onRetry: (request, response, retryCount) =>
            logger.d('Retrying request to ${request.url} (Retry #$retryCount)'),
      );

      final provider = _instance ?? GoogleDriveProvider._create();
      provider.driveApi = drive.DriveApi(retryClient);
      provider._isAuthenticated = true;
      _instance = provider;

      logger.i('Google Drive user signed in: ID=${account.id}, Email=${account.email}');

      return _instance;
    } catch (error, stackTrace) {
      logger.e(
        'Error occurred during the Google Drive connect process.',
        error: error,
        stackTrace: stackTrace,
      );
      await signOut();
      return null;
    }
  }

  static Future<void> signOut() async {
    try {
      await _googleSignIn?.disconnect();
      await _googleSignIn?.signOut();
    } catch (error, stackTrace) {
      logger.e(
        'Failed to sign out or disconnect from Google.',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _googleSignIn = null;
      if (_instance != null) {
        _instance!._isAuthenticated = false;
        _instance = null;
      }
      logger.i('User signed out from Google Drive.');
    }
  }

  void _checkAuth() {
    if (!_isAuthenticated || _instance == null) {
      throw Exception(
          'GoogleDriveProvider: Not authenticated. Call connect() first.');
    }
  }

  // --- 🚀 NEW: Centralized Request Execution with Retry Logic 🚀 ---
  Future<T> _executeRequest<T>(Future<T> Function() request) async {
    _checkAuth();
    try {
      // First attempt
      return await request();
    } on drive.DetailedApiRequestError catch (e, stackTrace) {
      // Handle expired token or permission errors
      if (e.status == 401 || e.status == 403) {
        logger.w('Authentication token expired or invalid. Attempting to reconnect...',
            error: e,
            stackTrace: stackTrace);
        _isAuthenticated = false;

        // Silently try to reconnect to refresh the token
        final reconnectedProvider = await GoogleDriveProvider.connect();

        if (reconnectedProvider != null && reconnectedProvider._isAuthenticated) {
          logger.i('Successfully reconnected. Retrying the original request.');
          // Retry the request once more
          return await request();
        } else {
          logger.e('Failed to reconnect after token expiration. Throwing original error.');
          rethrow;
        }
      }
      // For any other API error, rethrow
      rethrow;
    }
  }

  Future<String> _getRootFolderId() async {
    return MultiCloudStorage.cloudAccess == CloudAccessType.appStorage
        ? 'appDataFolder'
        : 'root';
  }

  @override
  Future<String> uploadFile({
    required String localPath,
    required String remotePath,
    Map<String, dynamic>? metadata,
  }) {
    return _executeRequest(() async {
      final existingFile = await _getFileByPath(remotePath);

      if (existingFile != null && existingFile.id != null) {
        return uploadFileById(
          localPath: localPath,
          fileId: existingFile.id!,
          metadata: metadata,
        );
      } else {
        final file = File(localPath);
        final fileName = basename(remotePath);
        final remoteDir = dirname(remotePath) == '.' ? '' : dirname(remotePath);
        final folder = await _getOrCreateFolder(remoteDir);

        final driveFile = drive.File()
          ..name = fileName
          ..parents = [folder.id!];

        final media = drive.Media(file.openRead(), await file.length());

        final uploadedFile = await driveApi.files
            .create(driveFile, uploadMedia: media, $fields: 'id, name');
        return uploadedFile.id!;
      }
    });
  }

  @override
  Future<String> uploadFileById({
    required String localPath,
    required String fileId,
    String? subPath,
    Map<String, dynamic>? metadata,
  }) {
    return _executeRequest(() async {
      final file = File(localPath);
      final driveFile = drive.File();
      final media = drive.Media(file.openRead(), await file.length());

      final updatedFile = await driveApi.files
          .update(driveFile, fileId, uploadMedia: media, $fields: 'id');
      return updatedFile.id!;
    });
  }

  @override
  Future<String> downloadFile({
    required String remotePath,
    required String localPath,
  }) {
    return _executeRequest(() async {
      final file = await _getFileByPath(remotePath);
      if (file == null || file.id == null) {
        throw Exception('GoogleDriveProvider: File not found at $remotePath');
      }

      final output = File(localPath);
      final sink = output.openWrite();

      try {
        final media = await driveApi.files
            .get(file.id!, downloadOptions: drive.DownloadOptions.fullMedia)
        as drive.Media;
        await media.stream.pipe(sink);
      } catch (e) {
        await sink.close(); // Ensure sink is closed on error
        if (await output.exists()) await output.delete(); // Clean up partial file
        rethrow;
      }
      await sink.close();
      return localPath;
    });
  }

  @override
  Future<List<CloudFile>> listFiles(
      {String path = '', bool recursive = false}) {
    return _executeRequest(() async {
      final folder = await _getFolderByPath(path);
      if (folder == null || folder.id == null) {
        return [];
      }

      final List<CloudFile> cloudFiles = [];
      String? pageToken;
      do {
        final fileList = await driveApi.files.list(
          spaces: MultiCloudStorage.cloudAccess == CloudAccessType.appStorage
              ? 'appDataFolder'
              : 'drive',
          q: "'${folder.id}' in parents and trashed = false",
          $fields:
          'nextPageToken, files(id, name, size, modifiedTime, mimeType, parents)',
          pageToken: pageToken,
        );
        if (fileList.files != null) {
          for (final file in fileList.files!) {
            String currentItemPath = join(path, file.name ?? '');
            if (path == '/' || path.isEmpty) currentItemPath = file.name ?? '';

            cloudFiles.add(CloudFile(
              path: currentItemPath,
              name: file.name ?? 'Unnamed',
              size: file.size == null ? null : int.tryParse(file.size!),
              modifiedTime: file.modifiedTime ?? DateTime.now(),
              isDirectory: file.mimeType == 'application/vnd.google-apps.folder',
              metadata: {
                'id': file.id,
                'mimeType': file.mimeType,
                'parents': file.parents
              },
            ));
          }
        }
        pageToken = fileList.nextPageToken;
      } while (pageToken != null);

      if (recursive) {
        final List<CloudFile> subFolderFiles = [];
        for (final cf in cloudFiles) {
          if (cf.isDirectory) {
            subFolderFiles.addAll(await listFiles(path: cf.path, recursive: true));
          }
        }
        cloudFiles.addAll(subFolderFiles);
      }
      return cloudFiles;
    });
  }

  @override
  Future<void> deleteFile(String path) {
    return _executeRequest(() async {
      final file = await _getFileByPath(path);
      if (file != null && file.id != null) {
        await driveApi.files.delete(file.id!);
      }
    });
  }

  @override
  Future<void> createDirectory(String path) {
    return _executeRequest(() async {
      await _getOrCreateFolder(path);
    });
  }

  @override
  Future<CloudFile> getFileMetadata(String path) {
    return _executeRequest(() async {
      final file = await _getFileByPath(path);
      if (file == null) {
        throw Exception('GoogleDriveProvider: File not found at $path');
      }
      return CloudFile(
        path: path,
        name: file.name ?? 'Unnamed',
        size: file.size == null ? null : int.tryParse(file.size!),
        modifiedTime: file.modifiedTime ?? DateTime.now(),
        isDirectory: file.mimeType == 'application/vnd.google-apps.folder',
        metadata: {
          'id': file.id,
          'mimeType': file.mimeType,
          'parents': file.parents
        },
      );
    });
  }

  // --- Helper Methods (No changes needed below, but shown for completeness) ---

  Future<drive.File?> _getFolderByPath(String folderPath) async {
    if (folderPath.isEmpty || folderPath == '.' || folderPath == '/') {
      return _getRootFolder();
    }
    final parts = split(
        folderPath.replaceAll(RegExp(r'^/+'), '').replaceAll(RegExp(r'/+$'), ''));
    if (parts.isEmpty || (parts.length == 1 && parts[0].isEmpty)) {
      return _getRootFolder();
    }
    drive.File currentFolder = await _getRootFolder();
    for (final part in parts) {
      if (part.isEmpty) continue;
      final folder = await _getFolderByName(currentFolder.id!, part);
      if (folder == null) return null;
      currentFolder = folder;
    }
    return currentFolder;
  }

  Future<drive.File?> _getFileByPath(String filePath) async {
    if (filePath.isEmpty || filePath == '.' || filePath == '/') {
      return (filePath == '/' || filePath == '.') ? _getRootFolder() : null;
    }

    final normalizedPath =
    filePath.replaceAll(RegExp(r'^/+'), '').replaceAll(RegExp(r'/+$'), '');
    if (normalizedPath.isEmpty) return _getRootFolder();

    final parts = split(normalizedPath);
    drive.File currentFolder = await _getRootFolder();

    for (var i = 0; i < parts.length - 1; i++) {
      final folderName = parts[i];
      if (folderName.isEmpty) continue;
      final folder = await _getFolderByName(currentFolder.id!, folderName);
      if (folder == null) {
        return null;
      }
      currentFolder = folder;
    }

    final fileName = parts.last;
    if (fileName.isEmpty) return currentFolder;

    final query =
        "'${currentFolder.id}' in parents and name = '${_sanitizeQueryString(fileName)}' and trashed = false";
    final fileList = await driveApi.files.list(
      spaces: MultiCloudStorage.cloudAccess == CloudAccessType.appStorage
          ? 'appDataFolder'
          : 'drive',
      q: query,
      $fields: 'files(id, name, size, modifiedTime, mimeType, parents)',
    );
    return fileList.files?.isNotEmpty == true ? fileList.files!.first : null;
  }

  Future<drive.File> _getOrCreateFolder(String folderPath) async {
    if (folderPath.isEmpty || folderPath == '.' || folderPath == '/') {
      return _getRootFolder();
    }
    final normalizedPath =
    folderPath.replaceAll(RegExp(r'^/+'), '').replaceAll(RegExp(r'/+$'), '');
    if (normalizedPath.isEmpty) return _getRootFolder();

    final parts = split(normalizedPath);
    drive.File currentFolder = await _getRootFolder();
    for (final part in parts) {
      if (part.isEmpty) continue;
      var folder = await _getFolderByName(currentFolder.id!, part);
      folder ??= await _createFolder(currentFolder.id!, part);
      currentFolder = folder;
    }
    return currentFolder;
  }

  Future<drive.File> _getRootFolder() async {
    return drive.File()..id = await _getRootFolderId();
  }

  Future<drive.File?> _getFolderByName(String parentId, String name) async {
    final query =
        "'$parentId' in parents and name = '${_sanitizeQueryString(name)}' and mimeType = 'application/vnd.google-apps.folder' and trashed = false";
    final fileList = await driveApi.files.list(
      spaces: MultiCloudStorage.cloudAccess == CloudAccessType.appStorage
          ? 'appDataFolder'
          : 'drive',
      q: query,
      $fields: 'files(id, name, mimeType, parents)',
    );
    return fileList.files?.isNotEmpty == true ? fileList.files!.first : null;
  }

  Future<drive.File> _createFolder(String parentId, String name) async {
    final folder = drive.File()
      ..name = name
      ..mimeType = 'application/vnd.google-apps.folder'
      ..parents = [parentId];
    return await driveApi.files
        .create(folder, $fields: 'id, name, mimeType, parents');
  }

  String _sanitizeQueryString(String value) => value.replaceAll("'", "\\'");

  @override
  Future<bool> logout() async {
    if (_isAuthenticated) {
      try {
        await signOut();
        _isAuthenticated = false;
        return true;
      } catch (e) {
        return false;
      }
    }
    return false;
  }

  @override
  Future<bool> tokenExpired() {
    return _executeRequest(() async {
      // If this request succeeds, the token is valid.
      // If it fails with 401/403, _executeRequest will handle it.
      // A successful check means the token is not expired.
      await driveApi.about.get($fields: 'user');
      return false;
    }).then((_) => false).catchError((_) => true);
  }

  @override
  Future<String> getSharedFileById({
    required String fileId,
    required String localPath,
    String? subPath,
  }) {
    return _executeRequest(() async {
      final output = File(localPath);
      final sink = output.openWrite();
      try {
        final media = await driveApi.files
            .get(fileId, downloadOptions: drive.DownloadOptions.fullMedia)
        as drive.Media;
        await media.stream.pipe(sink);
      } finally {
        await sink.close();
      }
      return localPath;
    });
  }

  @override
  Future<String?> extractFileIdFromSharableLink(Uri shareLink) async {
    final regex = RegExp(r'd/([a-zA-Z0-9_-]+)');
    final match = regex.firstMatch(shareLink.toString());
    return match?.group(1);
  }

  @override
  Future<Uri?> generateSharableLink(String path) {
    return _executeRequest(() async {
      final drive.File? file = await _getFileByPath(path);
      if (file == null || file.id == null) {
        return null;
      }

      final permission = drive.Permission()
        ..type = 'anyone'
        ..role = 'writer';

      await driveApi.permissions.create(permission, file.id!, $fields: 'id');

      final fileMetadata = await driveApi.files
          .get(file.id!, $fields: 'id, name, webViewLink') as drive.File;
      if (fileMetadata.webViewLink == null) {
        return null;
      }
      return Uri.parse(fileMetadata.webViewLink!);
    });
  }
}