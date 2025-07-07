import 'dart:io';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:http/retry.dart';
import 'package:path/path.dart';

import 'cloud_storage_provider.dart';
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

  /// Establishes a connection to Google Drive.
  ///
  /// This method handles the entire authentication flow. It first attempts a silent
  /// sign-in. If that fails or if `forceInteractive` is true, it prompts the user
  /// with the interactive sign-in screen.
  ///
  /// The key fix to prevent the "deadlock" `PlatformException` is to call
  /// `requestScopes` immediately after a successful sign-in, which ensures that
  /// permissions are correctly registered before fetching the authenticated client.
  static Future<GoogleDriveProvider?> connect(
      {bool forceInteractive = false}) async {
    // If already connected and not forcing a new interactive session, return the existing instance.
    if (_instance != null && _instance!._isAuthenticated && !forceInteractive) {
      print("GoogleDriveProvider: Already connected.");
      return _instance;
    }

    // Initialize GoogleSignIn if it hasn't been already.
    _googleSignIn ??= GoogleSignIn(
      scopes: [
        MultiCloudStorage.cloudAccess == CloudAccessType.appStorage
            ? drive.DriveApi.driveAppdataScope
            : drive.DriveApi.driveScope,
      ],
      // For persistent offline access, uncomment and provide your web client ID.
      // serverClientId: 'YOUR_SERVER_CLIENT_ID_FROM_GOOGLE_CLOUD_CONSOLE',
    );

    GoogleSignInAccount? account;

    try {
      // Attempt to sign in. First silently, then interactively if needed.
      if (!forceInteractive) {
        account = await _googleSignIn!.signInSilently();
      }
      account ??= await _googleSignIn!.signIn();

      // If account is null, the user cancelled the sign-in process.
      if (account == null) {
        print("GoogleDriveProvider: Sign-in process cancelled by user.");
        return null;
      }

      print(
          "GoogleDriveProvider: Sign-in successful for ${account.email}.");

      // *** KEY FIX ***
      // Explicitly request scopes after sign-in. This is crucial for preventing the
      // 'deadlock' PlatformException on Android by ensuring the auth state is
      // fully synchronized before proceeding.
      final bool hasPermissions =
      await _googleSignIn!.requestScopes(_googleSignIn!.scopes);
      if (!hasPermissions) {
        print(
            "GoogleDriveProvider: User did not grant necessary permissions.");
        await signOut(); // Sign out to ensure a clean state.
        return null;
      }

      // Now it's safe to get the authenticated client.
      final client = await _googleSignIn!.authenticatedClient();

      if (client == null) {
        print(
            "GoogleDriveProvider: Failed to get authenticated client after granting permissions.");
        await signOut(); // Clean up on failure.
        return null;
      }

      final retryClient = RetryClient(
        client,
        retries: 3,
        when: (response) {
          const retryableStatuses = {
            401, // Unauthorized (token expired)
            403, // Forbidden (token expired)
            500, // Internal Server Error
            502, // Bad Gateway
            503, // Service Unavailable
            504, // Gateway Timeout
          };
          return retryableStatuses.contains(response.statusCode);
        },
        onRetry: (request, response, retryCount) {
          debugPrint('Retrying request to ${request.url} (Retry #$retryCount)');
        },
      );

      print("GoogleDriveProvider: Authenticated client obtained successfully.");

      // Create or update the singleton instance with the authenticated client.
      final provider = _instance ?? GoogleDriveProvider._create();
      provider.driveApi = drive.DriveApi(retryClient);
      provider._isAuthenticated = true;
      _instance = provider;

      return _instance;
    } catch (error, stackTrace) {
      print('GoogleDriveProvider: Error during sign-in or client retrieval: $error');
      print(stackTrace.toString());
      // On any error, sign out completely to avoid corrupt state.
      await signOut();
      return null;
    }
  }

  // Method to sign out
  static Future<void> signOut() async {
    try {
      // Disconnect revokes the token, signOut clears local auth cache.
      await _googleSignIn?.disconnect();
      await _googleSignIn?.signOut();
    } catch (e) {
      print("GoogleDriveProvider: Sign out error - $e");
    } finally {
      // Reset all static instances to ensure a fresh start next time.
      _googleSignIn = null;
      if (_instance != null) {
        _instance!._isAuthenticated = false;
        _instance = null;
      }
      print("GoogleDriveProvider: User signed out and state has been reset.");
    }
  }

  void _checkAuth() {
    if (!_isAuthenticated || _instance == null) {
      throw Exception(
          'GoogleDriveProvider: Not authenticated. Call connect() first.');
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

    // First, check if a file already exists at the given path.
    final existingFile = await _getFileByPath(remotePath);

    if (existingFile != null && existingFile.id != null) {
      // If the file exists, update it using its ID.
      print(
          "GoogleDriveProvider: Found existing file at '$remotePath'. Updating it.");
      return uploadFileById(
        localPath: localPath,
        fileId: existingFile.id!,
        metadata: metadata,
      );
    } else {
      // If the file does not exist, create it.
      print(
          "GoogleDriveProvider: No file at '$remotePath'. Creating a new one.");
      final file = File(localPath);
      final fileName = basename(remotePath);
      final remoteDir = dirname(remotePath) == '.' ? '' : dirname(remotePath);
      final folder = await _getOrCreateFolder(remoteDir);

      final driveFile = drive.File()
        ..name = fileName
        ..parents = [folder.id!];

      final media = drive.Media(file.openRead(), await file.length());
      drive.File uploadedFile;
      try {
        uploadedFile = await driveApi.files
            .create(driveFile, uploadMedia: media, $fields: 'id, name');
        print(
            "GoogleDriveProvider: Created new file '${uploadedFile.name}' with ID '${uploadedFile.id}'.");
      } catch (e) {
        print("Error creating file during upload: $e");
        if (e is drive.DetailedApiRequestError &&
            (e.status == 401 || e.status == 403)) {
          print(
              "Authentication error during create. The user may not have permission, or the token is invalid.");
          _isAuthenticated = false;
        }
        rethrow;
      }

      return uploadedFile.id!;
    }
  }

  @override
  Future<String> uploadFileById({
    required String localPath,
    required String fileId,
    String? subPath,
    Map<String, dynamic>? metadata,
  }) async {
    _checkAuth();

    final file = File(localPath);

    final driveFile =
        drive.File(); // Metadata changes can be added here if needed

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
      print("Error uploading file by ID: $e");
      if (e is drive.DetailedApiRequestError &&
          (e.status == 401 || e.status == 403)) {
        print(
            "Authentication error during upload. The user may not have permission, or the token is invalid.");
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
      print("Error downloading file: $e");
      if (e is drive.DetailedApiRequestError &&
          (e.status == 401 || e.status == 403)) {
        print(
            "Authentication error during download. The user may not have permission, or the token is invalid.");
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
      print("GoogleDriveProvider: Folder not found at $path");
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
        print("Error deleting file: $e");
        rethrow;
      }
    } else {
      print(
          "GoogleDriveProvider: File/Folder to delete not found at $path");
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
        print(
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
      $fields: 'files(id, name, mimeType, parents)',
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
      print("GoogleDriveProvider: File not found at $path");
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
      print("Error setting permission for sharing: $e");
      return null;
    }

    try {
      final fileMetadata = await driveApi.files.get(
        file.id!,
        $fields: 'id, name, webViewLink',
      ) as drive.File;

      if (fileMetadata.webViewLink == null) {
        print("No webViewLink returned by API.");
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
      print("Error getting shareable link: $e");
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
        print("Logout failed: $e");
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
    String? subPath,
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
      print("Error downloading shared file by ID: $e");
      if (e is drive.DetailedApiRequestError &&
          (e.status == 401 || e.status == 403)) {
        print("Authentication error during download.");
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
