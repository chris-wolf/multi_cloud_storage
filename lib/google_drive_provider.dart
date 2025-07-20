import 'dart:io';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/retry.dart';
import 'package:logger/logger.dart';
import 'package:multi_cloud_storage/exceptions/no_connection_exception.dart';
import 'package:path/path.dart';

// Assuming your global logger is accessible via main.dart
import 'cloud_storage_provider.dart';
import 'exceptions/not_found_exception.dart';
import 'file_log_output.dart';
import 'multi_cloud_storage.dart';

// 3. The Logger Instance: Your global logger object
final logger = Logger(
  filter: MyFilter(), // Use your custom filter
  output: MultiOutput([
    ConsoleOutput(),
    FileLogOutput(),
  ]),
  printer: PrettyPrinter(
    methodCount: 0,
    colors: false, // Set to false for file output
    printTime: true,
  ),
);

class GoogleDriveProvider extends CloudStorageProvider {
  /// The authenticated Google Drive API client.
  late drive.DriveApi driveApi;
  bool _isAuthenticated = false;

  // Singleton instance backing fields.
  static GoogleSignIn? _googleSignIn;
  static GoogleDriveProvider? _instance;

  GoogleDriveProvider._create();

  static GoogleDriveProvider? get instance => _instance;

  /// Connects to Google Drive, authenticating the user.
  ///
  /// This method handles the Google Sign-In flow. It will attempt to sign in
  /// silently first, unless [forceInteractive] is true.
  /// Returns a connected [GoogleDriveProvider] instance on success, or null on failure/cancellation.
  static Future<GoogleDriveProvider?> connect(
      {bool forceInteractive = false}) async {
    logger.i("connect Google Drive,  forceInteractive: $forceInteractive");
    // Return existing instance if already connected and not forcing a new interactive session.
    if (_instance != null && _instance!._isAuthenticated && !forceInteractive) {
      return _instance;
    }
    try {
    // Initialize GoogleSignIn with the correct scope based on the desired cloud access level.
    _googleSignIn ??= GoogleSignIn(
      scopes: [
        MultiCloudStorage.cloudAccess == CloudAccessType.appStorage
            ? drive.DriveApi
                .driveAppdataScope // Access to the app-specific folder.
            : drive.DriveApi.driveScope, // Full access to user's Drive.
      ],
    );
    GoogleSignInAccount? account;
      // Attempt silent sign-in first to avoid unnecessary user interaction.
      if (!forceInteractive) {
        account = await _googleSignIn!.signInSilently();
      }
      // If silent sign-in fails or is skipped, start the interactive sign-in flow.
      account ??= await _googleSignIn!.signIn();
      if (account == null) {
        logger.i('User cancelled Google Sign-In process.');
        return null;
      }
      // Ensure the user has granted the required permissions.
      final bool hasPermissions =
          await _googleSignIn!.requestScopes(_googleSignIn!.scopes);
      if (!hasPermissions) {
        logger.w('User did not grant necessary Google Drive permissions.');
        await signOut();
        return null;
      }
      // Get the authenticated HTTP client.
      final client = await _googleSignIn!.authenticatedClient();
      if (client == null) {
        logger.e(
            'Failed to get authenticated Google client after permissions were granted.');
        await signOut();
        return null;
      }
      // Wrap the client in a RetryClient to handle transient network errors (5xx).
      final retryClient = RetryClient(
        client,
        retries: 3,
        when: (response) => {500, 502, 503, 504}.contains(response.statusCode),
        onRetry: (request, response, retryCount) =>
            logger.d('Retrying request to ${request.url} (Retry #$retryCount)'),
      );
      // Create or update the singleton instance with the authenticated client.
      final provider = _instance ?? GoogleDriveProvider._create();
      provider.driveApi = drive.DriveApi(retryClient);
      provider._isAuthenticated = true;
      _instance = provider;
      logger.i(
          'Google Drive user signed in: ID=${account.id}, Email=${account.email}');
      return _instance;
    }  on SocketException catch (e, stackTrace) {
      logger.w('No internet connection during Google Drive sign-in.',
          error: e, stackTrace: stackTrace);
      throw NoConnectionException(e.message);
    } catch (error, stackTrace) {
      logger.e(
        'Error occurred during the Google Drive connect process.',
        error: error,
        stackTrace: stackTrace,
      );
      if (error is PlatformException && error.code == 'network_error') {
        throw NoConnectionException(error.toString());
      }
      await signOut(); // Clean up on error.
      return null;
    }
  }

  /// Uploads a file from a [localPath] to a [remotePath] in the cloud.
  @override
  Future<List<CloudFile>> listFiles(
      {String path = '', bool recursive = false}) {
    return _executeRequest(() async {
      final folder = await _getFolderByPath(path);
      if (folder == null || folder.id == null) {
        return []; // Return empty list if path does not exist.
      }
      final List<CloudFile> cloudFiles = [];
      String? pageToken;
      // Loop to handle paginated results from the Drive API.
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
            // Convert Google Drive file object to a generic CloudFile.
            cloudFiles.add(CloudFile(
              path: currentItemPath,
              name: file.name ?? 'Unnamed',
              size: file.size == null ? null : int.tryParse(file.size!),
              modifiedTime: file.modifiedTime ?? DateTime.now(),
              isDirectory:
                  file.mimeType == 'application/vnd.google-apps.folder',
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
      // If recursive is true, fetch files from all subdirectories.
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
    });
  }

  /// Downloads a file from a [remotePath] to a [localPath] on the device.
  @override
  Future<String> downloadFile({
    required String remotePath,
    required String localPath,
  }) {
    return _executeRequest(() async {
      // Find the file by its path to get its ID.
      final file = await _getFileByPath(remotePath);
      if (file == null || file.id == null) {
        throw Exception('GoogleDriveProvider: File not found at $remotePath');
      }
      final output = File(localPath);
      final sink = output.openWrite();
      try {
        // Download the file content by its ID.
        final media = await driveApi.files.get(file.id!,
            downloadOptions: drive.DownloadOptions.fullMedia) as drive.Media;
        // Stream the content to the local file.
        await media.stream.pipe(sink);
      } catch (e) {
        await sink.close(); // Ensure sink is closed on error.
        if (await output.exists()) {
          await output.delete(); // Clean up partial file on failure.
        }
        rethrow;
      }
      await sink.close();
      return localPath;
    });
  }

  /// Uploads a file from a [localPath] to a [remotePath].
  @override
  Future<String> uploadFile({
    required String localPath,
    required String remotePath,
    Map<String, dynamic>? metadata,
  }) {
    return _executeRequest(() async {
      // Check if a file already exists at the remote path.
      final existingFile = await _getFileByPath(remotePath);
      if (existingFile != null && existingFile.id != null) {
        // If it exists, update it using its file ID.
        return uploadFileByShareToken(
          localPath: localPath,
          shareToken: existingFile.id!,
          metadata: metadata,
        );
      } else {
        // If it doesn't exist, create it.
        final file = File(localPath);
        final fileName = basename(remotePath);
        final remoteDir = dirname(remotePath) == '.' ? '' : dirname(remotePath);
        // Ensure the parent directory exists.
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

  /// Deletes the file or directory at the specified [path].
  @override
  Future<void> deleteFile(String path) {
    return _executeRequest(() async {
      final file = await _getFileByPath(path);
      if (file != null && file.id != null) {
        await driveApi.files.delete(file.id!);
      }
    });
  }

  /// Creates a new directory at the specified [path].
  @override
  Future<void> createDirectory(String path) {
    return _executeRequest(() async {
      // This helper finds the folder and creates it if it doesn't exist.
      await _getOrCreateFolder(path);
    });
  }

  /// Retrieves metadata for the file or directory at the specified [path].
  @override
  Future<CloudFile> getFileMetadata(String path) {
    return _executeRequest(() async {
      final file = await _getFileByPath(path);
      if (file == null) {
        throw Exception('GoogleDriveProvider: File not found at $path');
      }
      // Convert the Google Drive file object to a generic CloudFile.
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

  @override
  Future<String?> loggedInUserDisplayName() async {
    return _googleSignIn?.currentUser?.displayName;
  }

  /// Checks if the current user's authentication token is expired.
  @override
  Future<bool> tokenExpired() {
    return _executeRequest(() async {
      // Make a lightweight API call to check token validity.
      // If it succeeds, the token is valid. A 401/403 error is caught by
      // _executeRequest, which then tries to re-authenticate.
      await driveApi.about.get($fields: 'user');
      return false;
    })
        .then((_) =>
            false) // If the request (and potential retry) succeeds, token is not expired.
        .catchError((_) =>
            true); // If it ultimately fails, token is considered expired.
  }

  /// Logs out the current user from the cloud service.
  @override
  Future<bool> logout() async {
    if (_isAuthenticated) {
      try {
        await signOut();
        _isAuthenticated = false; // This is redundant due to signOut but safe.
        return true;
      } catch (e) {
        return false;
      }
    }
    return false; // Already logged out.
  }

  /// Generates a shareable link for the file or directory at the [path].
  @override
  Future<Uri?> generateShareLink(String path) {
    return _executeRequest(() async {
      final drive.File? file = await _getFileByPath(path);
      if (file == null || file.id == null) {
        return null;
      }
      // Create a permission to make the file accessible to anyone with the link.
      final permission = drive.Permission()
        ..type = 'anyone'
        ..role = 'writer'; // or 'reader'
      await driveApi.permissions.create(permission, file.id!, $fields: 'id');
      // Retrieve the file metadata again to get the shareable link.
      final fileMetadata = await driveApi.files
          .get(file.id!, $fields: 'id, name, webViewLink') as drive.File;
      if (fileMetadata.webViewLink == null) {
        return null;
      }
      return Uri.parse(fileMetadata.webViewLink!);
    });
  }

  /// Extracts a share token from a given [shareLink].
  @override
  Future<String?> getShareTokenFromShareLink(Uri shareLink) async {
    // Extracts the file ID from a standard Google Drive URL format.
    // e.g., .../d/FILE_ID/edit
    final regex = RegExp(r'd/([a-zA-Z0-9_-]+)');
    final match = regex.firstMatch(shareLink.toString());
    return match?.group(1);
  }

  /// Downloads a file to [localPath] using a [shareToken].
  @override
  Future<String> downloadFileByShareToken(
      {required String shareToken, required String localPath}) {
    return _executeRequest(() async {
      final output = File(localPath);
      final sink = output.openWrite();
      try {
        // Download the file directly using its ID (shareToken).
        final media = await driveApi.files.get(shareToken,
            downloadOptions: drive.DownloadOptions.fullMedia) as drive.Media;
        await media.stream.pipe(sink);
      } finally {
        await sink.close();
      }
      return localPath;
    });
  }

  /// Uploads a file from [localPath] using a [shareToken].
  @override
  Future<String> uploadFileByShareToken({
    required String localPath,
    required String shareToken,
    Map<String, dynamic>? metadata,
  }) {
    return _executeRequest(() async {
      final file = File(localPath);
      final driveFile = drive.File(); // Empty file metadata for update
      final media = drive.Media(file.openRead(), await file.length());
      // Use the 'update' method with the file ID (shareToken) to overwrite content.
      final updatedFile = await driveApi.files
          .update(driveFile, shareToken, uploadMedia: media, $fields: 'id');
      return updatedFile.id!;
    });
  }

  /// Signs the user out of Google and disconnects the app.
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
      // Clear all state regardless of success or failure.
      _googleSignIn = null;
      if (_instance != null) {
        _instance!._isAuthenticated = false;
        _instance = null;
      }
      logger.i('User signed out from Google Drive.');
    }
  }

  /// A wrapper for all API requests to centralize authentication checks and error handling.
  ///
  /// Executes the given `request` function. If an authentication error (401/403)
  /// occurs, it triggers the automatic reconnection and retry logic.
  Future<T> _executeRequest<T>(Future<T> Function() request) async {
    _checkAuth();
    try {
      return await request();
    } on drive.DetailedApiRequestError catch (e, stackTrace) {
      // If the error is an auth token issue, try to recover.
      if (e.status == 401 || e.status == 403) {
        return _handleAuthErrorAndRetry(request, e, stackTrace);
      } else if (e.status == 404) {
        throw NotFoundException(e.message ?? '');
      } else {
        // For other API errors, rethrow them.
        rethrow;
      }
    } on AccessDeniedException catch (e, stackTrace) {
      // Also handle auth errors from the underlying auth library.
      return _handleAuthErrorAndRetry(request, e, stackTrace);
    } on SocketException catch (e, stackTrace) {
  logger.w('No connection detected.', error: e, stackTrace: stackTrace);
  throw NoConnectionException(e.message);
}
  }

  /// Throws an exception if the provider is not authenticated.
  void _checkAuth() {
    if (!_isAuthenticated || _instance == null) {
      throw Exception(
          'GoogleDriveProvider: Not authenticated. Call connect() first.');
    }
  }

  /// A helper to handle auth errors by reconnecting and retrying the request.
  ///
  /// This is called when a 401/403 error occurs, indicating an expired token.
  /// It attempts a silent reconnect to refresh the token and then retries the
  /// original function `request`.
  Future<T> _handleAuthErrorAndRetry<T>(
      Future<T> Function() request, Object error, StackTrace stackTrace) async {
    logger.w('Authentication error occurred. Attempting to reconnect...',
        error: error, stackTrace: stackTrace);
    _isAuthenticated = false;
    // Silently try to reconnect to refresh the auth token.
    final reconnectedProvider = await GoogleDriveProvider.connect();
    if (reconnectedProvider != null && reconnectedProvider._isAuthenticated) {
      logger.i('Successfully reconnected. Retrying the original request.');
      // Retry the original request closure.
      return await request();
    } else {
      logger
          .e('Failed to reconnect after auth error. Throwing original error.');
      // If reconnection fails, rethrow the original error to the caller.
      throw error;
    }
  }

  /// Gets the root folder ID ('appDataFolder' or 'root') based on the access type.
  Future<String> _getRootFolderId() async {
    return MultiCloudStorage.cloudAccess == CloudAccessType.appStorage
        ? 'appDataFolder'
        : 'root';
  }

  /// Finds a folder by its full path, returning null if not found.
  Future<drive.File?> _getFolderByPath(String folderPath) async {
    if (folderPath.isEmpty || folderPath == '.' || folderPath == '/') {
      return _getRootFolder();
    }
    // Normalize path and split into components.
    final parts = split(folderPath
        .replaceAll(RegExp(r'^/+'), '')
        .replaceAll(RegExp(r'/+$'), ''));
    if (parts.isEmpty || (parts.length == 1 && parts[0].isEmpty)) {
      return _getRootFolder();
    }
    drive.File currentFolder = await _getRootFolder();
    // Traverse the path segment by segment.
    for (final part in parts) {
      if (part.isEmpty) continue;
      final folder = await _getFolderByName(currentFolder.id!, part);
      if (folder == null) return null; // Path does not exist.
      currentFolder = folder;
    }
    return currentFolder;
  }

  /// Finds a file or folder by its full path, returning null if not found.
  Future<drive.File?> _getFileByPath(String filePath) async {
    if (filePath.isEmpty || filePath == '.' || filePath == '/') {
      return (filePath == '/' || filePath == '.') ? _getRootFolder() : null;
    }

    final normalizedPath =
        filePath.replaceAll(RegExp(r'^/+'), '').replaceAll(RegExp(r'/+$'), '');
    if (normalizedPath.isEmpty) {
      return _getRootFolder();
    }
    final parts = split(normalizedPath);
    drive.File currentFolder = await _getRootFolder();
    // Traverse the directory parts of the path.
    for (var i = 0; i < parts.length - 1; i++) {
      final folderName = parts[i];
      if (folderName.isEmpty) continue;
      final folder = await _getFolderByName(currentFolder.id!, folderName);
      if (folder == null) {
        return null; // Parent path does not exist.
      }
      currentFolder = folder;
    }
    final fileName = parts.last;
    if (fileName.isEmpty) return currentFolder; // Path was a directory.
    // Search for the file in the final parent directory.
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

  /// Gets a folder by its path, creating it and any missing parent directories if necessary.
  Future<drive.File> _getOrCreateFolder(String folderPath) async {
    if (folderPath.isEmpty || folderPath == '.' || folderPath == '/') {
      return _getRootFolder();
    }
    final normalizedPath = folderPath
        .replaceAll(RegExp(r'^/+'), '')
        .replaceAll(RegExp(r'/+$'), '');
    if (normalizedPath.isEmpty) return _getRootFolder();
    final parts = split(normalizedPath);
    drive.File currentFolder = await _getRootFolder();
    // Traverse the path, creating folders as needed.
    for (final part in parts) {
      if (part.isEmpty) continue;
      var folder = await _getFolderByName(currentFolder.id!, part);
      folder ??= await _createFolder(currentFolder.id!, part);
      currentFolder = folder;
    }
    return currentFolder;
  }

  /// Returns a `drive.File` object representing the root folder.
  Future<drive.File> _getRootFolder() async {
    return drive.File()..id = await _getRootFolderId();
  }

  /// Finds a folder by name within a specific parent folder.
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

  /// Creates a new folder with the given name inside a parent folder.
  Future<drive.File> _createFolder(String parentId, String name) async {
    final folder = drive.File()
      ..name = name
      ..mimeType = 'application/vnd.google-apps.folder'
      ..parents = [parentId];
    return await driveApi.files
        .create(folder, $fields: 'id, name, mimeType, parents');
  }

  /// Escapes single quotes in a string for use in a Drive API query.
  String _sanitizeQueryString(String value) => value.replaceAll("'", "\\'");
}
