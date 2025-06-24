import 'dart:io';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:path/path.dart';
import 'cloud_storage_provider.dart';
import 'package:http/http.dart' as http;

import 'multi_cloud_storage.dart';

class GoogleDriveProvider extends CloudStorageProvider {
  late drive.DriveApi driveApi;
  bool _isAuthenticated = false;

  // Static instance for GoogleSignIn to manage it globally for this provider
  static GoogleSignIn? _googleSignIn;

  // Static instance of the provider to make it a singleton
  static GoogleDriveProvider? _instance;

  GoogleDriveProvider._create(); // Private constructor

  // Public accessor for the singleton instance
  static GoogleDriveProvider? get instance => _instance;

  @override
  Future<String?> loggedInUserDisplayName() async {
    return _googleSignIn?.currentUser?.displayName;
  }

  // Get an authenticated instance of GoogleDriveProvider
  // Tries silent sign-in first, then interactive if needed.
  static Future<GoogleDriveProvider?> connect(
      {bool forceInteractive = false}) async {
    // If already connected and not forcing interactive, return existing instance
    if (_instance != null && _instance!._isAuthenticated && !forceInteractive) {
      debugPrint("GoogleDriveProvider: Already connected.");
      return _instance;
    }

    _googleSignIn ??= GoogleSignIn(
      scopes: [
        MultiCloudStorage.cloudAccess == CloudAccessType.appStorage
            ? drive.DriveApi
            .driveAppdataScope // Use driveAppdataScope for appDataFolder
            : drive.DriveApi.driveScope, // Full drive access
        // You might need PeopleServiceApi.contactsReadonlyScope or other scopes
        // if GSI complains about missing them, but for Drive, these should be enough.
      ],
      // If you use serverClientId for offline access (refresh tokens which are longer-lived)
      // This is highly recommended for "don't re-auth as long as possible"
      // You need to create this OAuth 2.0 Client ID of type "Web application" in Google Cloud Console
      // serverClientId: 'YOUR_SERVER_CLIENT_ID_FROM_GOOGLE_CLOUD_CONSOLE',
    );

    GoogleSignInAccount? account;
    // The `authenticatedClient` extension method from `extension_google_sign_in_as_googleapis_auth`
    // returns a `http.Client`.
    http.Client? client;

    try {
      if (!forceInteractive) {
        debugPrint("GoogleDriveProvider: Attempting silent sign-in...");
        account = await _googleSignIn!.signInSilently();
      }

      if (account == null) {
        debugPrint(
            "GoogleDriveProvider: Silent sign-in failed or interactive forced. Attempting interactive sign-in...");
        account = await _googleSignIn!.signIn();
        if (account == null) {
          debugPrint("GoogleDriveProvider: Interactive sign-in cancelled by user.");
          _instance?._isAuthenticated =
          false; // Ensure state is false if it was previously true
          return null; // User cancelled
        }
      }
      debugPrint("GoogleDriveProvider: Sign-in successful for ${account.email}.");

      // Get the authenticated client from the extension.
      // This client will handle refreshing the access token automatically.
      client = await _googleSignIn!.authenticatedClient();

      if (client == null) {
        debugPrint(
            "GoogleDriveProvider: Failed to get authenticated client. User might not be signed in or credentials issue.");
        await signOut(); // Sign out to clear any problematic state
        _instance?._isAuthenticated = false;
        return null;
      }

      debugPrint("GoogleDriveProvider: Authenticated client obtained.");
      final provider = _instance ?? GoogleDriveProvider._create();
      // The drive.DriveApi constructor accepts the http.Client provided by the extension.
      provider.driveApi = drive.DriveApi(client);
      provider._isAuthenticated = true;
      _instance = provider;
      return _instance;
    } catch (error, stackTrace) {
      debugPrint(
          'GoogleDriveProvider: Error during sign-in or client retrieval: $error');
      debugPrint(stackTrace.toString());
      _instance?._isAuthenticated = false;
      // Optionally sign out if a severe error occurs
      // await signOut();
      return null;
    }
  }

  // Method to sign out
  static Future<void> signOut() async {
    try {
      await _googleSignIn?.disconnect(); // Revoke token
      await _googleSignIn?.signOut();    // Sign out locally
    } catch (e) {
      debugPrint("GoogleDriveProvider: Sign out error - $e");
    }

    _googleSignIn = null;  // Clear scopes & cached state
    _instance?._isAuthenticated = false;
    _instance = null;      // Reset the singleton
    debugPrint("GoogleDriveProvider: User signed out and GoogleSignIn reset.");
  }

  void _checkAuth() {
    if (!_isAuthenticated || _instance == null) {
      throw Exception(
          'GoogleDriveProvider: Not authenticated or not properly initialized. Call connect() first.');
    }
  }

  // Helper to get the root folder ID based on access type
  Future<String> _getRootFolderId() async {
    if (MultiCloudStorage.cloudAccess == CloudAccessType.appStorage) {
      return 'appDataFolder';
    }
    return 'root';
  }

  @override
  Future<String> uploadFile({
    required String localPath,
    required String remotePath,
    Map<String, dynamic>? metadata,
  }) async {
    _checkAuth();

    final file = File(localPath);
    final fileName = basename(remotePath);
    // Ensure the remote path is relative to the root (or appDataFolder)
    final remoteDir = dirname(remotePath) == '.' ? '' : dirname(remotePath);
    final folder = await _getOrCreateFolder(remoteDir);

    final driveFile = drive.File()
      ..name = fileName
      ..parents = [folder.id!];

    final media = drive.Media(file.openRead(), await file.length());
    drive.File uploadedFile;
    try {
      uploadedFile = await driveApi.files
          .create(driveFile, uploadMedia: media, $fields: 'id');
    } catch (e) {
      debugPrint("Error uploading file: $e");
      // The authenticated client should handle token refreshes.
      // If an error still occurs, it might be a permissions issue.
      if (e is drive.DetailedApiRequestError &&
          (e.status == 401 || e.status == 403)) {
        debugPrint("Authentication error during upload. The user may not have permission, or the token is invalid.");
        _isAuthenticated = false; // Mark as unauthenticated
      }
      rethrow;
    }

    return uploadedFile.id!;
  }

  @override
  Future<String> uploadFileById({
    required String localPath,
    required String fileId,
    Map<String, dynamic>? metadata,
  }) async {
    _checkAuth();

    final file = File(localPath);

    final driveFile = drive.File(); // Metadata changes can be added here if needed

    final media = drive.Media(file.openRead(), await file.length());
    drive.File updatedFile;
    try {
      updatedFile = await driveApi.files.update(
        driveFile,
        fileId,
        uploadMedia: media,
        $fields: 'id',
      );
    } catch (e) {
      debugPrint("Error uploading file by ID: $e");
      if (e is drive.DetailedApiRequestError &&
          (e.status == 401 || e.status == 403)) {
        debugPrint("Authentication error during upload. The user may not have permission, or the token is invalid.");
        _isAuthenticated = false;
      }
      rethrow;
    }

    return updatedFile.id!;
  }

  @override
  Future<String> downloadFile({
    required String remotePath,
    required String localPath,
  }) async {
    _checkAuth();

    final file = await _getFileByPath(remotePath);
    if (file == null || file.id == null) {
      throw Exception('GoogleDriveProvider: File not found at $remotePath');
    }

    final output = File(localPath);
    final sink = output.openWrite();

    try {
      final media = await driveApi.files.get(
        file.id!,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media; // Cast is important here

      await media.stream.pipe(sink);
      await sink.close();
    } catch (e) {
      await sink.close(); // Ensure sink is closed on error
      // Delete partially downloaded file if an error occurs
      if (await output.exists()) {
        await output.delete();
      }
      debugPrint("Error downloading file: $e");
      if (e is drive.DetailedApiRequestError &&
          (e.status == 401 || e.status == 403)) {
        debugPrint("Authentication error during download. The user may not have permission, or the token is invalid.");
        _isAuthenticated = false;
      }
      rethrow;
    }

    return localPath;
  }

  @override
  Future<List<CloudFile>> listFiles({
    required String path,
    bool recursive =
    false, // Recursive listing can be complex and quota-intensive
  }) async {
    _checkAuth();

    final folder = await _getFolderByPath(path);
    if (folder == null || folder.id == null) {
      debugPrint("GoogleDriveProvider: Folder not found at $path");
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
          if (path == '/' || path.isEmpty) {
            currentItemPath = file.name ?? '';
          }

          cloudFiles.add(CloudFile(
            path: currentItemPath,
            name: file.name ?? 'Unnamed',
            size: file.size == null
                ? null
                : int.tryParse(file.size!), // Size is string
            modifiedTime: file.modifiedTime ?? DateTime.now(),
            isDirectory: file.mimeType == 'application/vnd.google-apps.folder',
            metadata: {
              'id': file.id,
              'mimeType': file.mimeType,
              'parents': file.parents,
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
          subFolderFiles
              .addAll(await listFiles(path: cf.path, recursive: true));
        }
      }
      cloudFiles.addAll(subFolderFiles);
    }

    return cloudFiles;
  }

  Future<drive.File?> _getFolderByPath(String folderPath) async {
    _checkAuth();
    if (folderPath.isEmpty || folderPath == '.' || folderPath == '/') {
      return _getRootFolder();
    }

    final parts = split(folderPath
        .replaceAll(RegExp(r'^/+'), '')
        .replaceAll(RegExp(r'/+$'), ''));
    if (parts.isEmpty || (parts.length == 1 && parts[0].isEmpty)) {
      return _getRootFolder();
    }

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
    if (file != null && file.id != null) {
      try {
        await driveApi.files.delete(file.id!);
      } catch (e) {
        debugPrint("Error deleting file: $e");
        rethrow;
      }
    } else {
      debugPrint("GoogleDriveProvider: File/Folder to delete not found at $path");
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
        'parents': file.parents,
      },
    );
  }

  Future<drive.File?> _getFileByPath(String filePath) async {
    _checkAuth();
    if (filePath.isEmpty || filePath == '.' || filePath == '/') {
      if (filePath == '/' || filePath == '.') {
        return _getRootFolder();
      }
      return null;
    }

    final normalizedPath =
    filePath.replaceAll(RegExp(r'^/+'), '').replaceAll(RegExp(r'/+$'), '');
    if (normalizedPath.isEmpty) {
      return _getRootFolder();
    }

    final parts = split(normalizedPath);
    drive.File currentFolder = await _getRootFolder();

    for (var i = 0; i < parts.length - 1; i++) {
      final folderName = parts[i];
      if (folderName.isEmpty) continue;
      final folder = await _getFolderByName(currentFolder.id!, folderName);
      if (folder == null) {
        debugPrint(
            "GoogleDriveProvider: Intermediate folder '$folderName' not found in path '$filePath'");
        return null;
      }
      currentFolder = folder;
    }

    final fileName = parts.last;
    if (fileName.isEmpty) {
      return currentFolder;
    }

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
    _checkAuth();
    if (folderPath.isEmpty || folderPath == '.' || folderPath == '/') {
      return _getRootFolder();
    }

    final normalizedPath = folderPath
        .replaceAll(RegExp(r'^/+'), '')
        .replaceAll(RegExp(r'/+$'), '');
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
    _checkAuth();
    String rootFolderId = await _getRootFolderId();
    return drive.File()..id = rootFolderId;
  }

  Future<drive.File?> _getFolderByName(String parentId, String name) async {
    _checkAuth();
    final query =
        "'$parentId' in parents and name = '${_sanitizeQueryString(name)}' and mimeType = 'application/vnd.google-apps.folder' and trashed = false";
    final fileList = await driveApi.files.list(
      spaces: MultiCloudStorage.cloudAccess == CloudAccessType.appStorage
          ? 'appDataFolder'
          : 'drive',
      q: query,
      $fields:
      'files(id, name, mimeType, parents)',
    );
    return fileList.files?.isNotEmpty == true ? fileList.files!.first : null;
  }

  Future<drive.File> _createFolder(String parentId, String name) async {
    _checkAuth();
    final folder = drive.File()
      ..name = name
      ..mimeType = 'application/vnd.google-apps.folder'
      ..parents = [parentId];

    return await driveApi.files
        .create(folder, $fields: 'id, name, mimeType, parents');
  }

  String _sanitizeQueryString(String value) {
    return value.replaceAll("'", "\\'");
  }

  @override
  Future<Uri?> generateSharableLink(String path) async {
    _checkAuth();

    final drive.File? file = await _getFileByPath(path);
    if (file == null || file.id == null) {
      debugPrint("GoogleDriveProvider: File not found at $path");
      return null;
    }

    final permission = drive.Permission()
      ..type = 'anyone'
      ..role = 'writer';

    try {
      await driveApi.permissions.create(
        permission,
        file.id!,
        $fields: 'id',
      );
    } catch (e) {
      debugPrint("Error setting permission for sharing: $e");
      return null;
    }

    try {
      final fileMetadata = await driveApi.files.get(
        file.id!,
        $fields: 'id, name, webViewLink',
      ) as drive.File;

      if (fileMetadata.webViewLink == null) {
        debugPrint("No webViewLink returned by API.");
        return null;
      }

      final shareableUri = Uri.parse(fileMetadata.webViewLink!).replace(
        queryParameters: {
          ...Uri.parse(fileMetadata.webViewLink!).queryParameters,
          'originalPath': path,
        },
      );

      return shareableUri;
    } catch (e) {
      debugPrint("Error getting shareable link: $e");
      return null;
    }
  }

  @override
  Future<bool> logout() async {
    if (_isAuthenticated) {
      try {
        await signOut();
        _isAuthenticated = false;
        return true;
      } catch (e) {
        debugPrint("Logout failed: $e");
        return false;
      }
    }
    return false;
  }

  @override
  Future<bool> tokenExpired() async {
    if (!_isAuthenticated || _instance == null) return true;

    try {
      // The authenticated client handles token refreshes automatically, but we can make a
      // lightweight call to check for connectivity and fundamental auth issues.
      await driveApi.about.get($fields: 'user');
      return false; // If the call succeeds, the token is considered valid.
    } on drive.DetailedApiRequestError catch (e) {
      if (e.status == 401 || e.status == 403) {
        _isAuthenticated = false; // Token is invalid or expired
        return true;
      }
      return false; // Some other API error
    } on http.ClientException catch (_) {
      // Likely a network issue, not an auth issue.
      return false;
    } catch (_) {
      // Unknown error, could be anything.
      return false;
    }
  }

  @override
  Future<String> getSharedFileById({
    required String fileId,
    required String localPath,
  }) async {
    _checkAuth();

    final output = File(localPath);
    final sink = output.openWrite();

    try {
      final media = await driveApi.files.get(
        fileId,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media;

      await media.stream.pipe(sink);
      await sink.close();
    } catch (e) {
      await sink.close();
      if (await output.exists()) {
        await output.delete();
      }
      debugPrint("Error downloading shared file by ID: $e");
      if (e is drive.DetailedApiRequestError &&
          (e.status == 401 || e.status == 403)) {
        debugPrint("Authentication error during download.");
        _isAuthenticated = false;
      }
      rethrow;
    }

    return localPath;
  }


  @override
  Future<String?> extractFileIdFromSharableLink(Uri shareLink) async {
    final regex = RegExp(r'd/([a-zA-Z0-9_-]+)');
    final match = regex.firstMatch(shareLink.toString());
    return match?.group(1);
  }
}
