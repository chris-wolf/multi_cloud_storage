import 'dart:io';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:path/path.dart';
import 'cloud_storage_provider.dart';
import 'package:http/http.dart' as http;
import 'package:googleapis_auth/googleapis_auth.dart';

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

  // Get an authenticated instance of GoogleDriveProvider
  // Tries silent sign-in first, then interactive if needed.
  static Future<GoogleDriveProvider?> connect(
      {bool forceInteractive = false}) async {
    // If already connected and not forcing interactive, return existing instance
    if (_instance != null && _instance!._isAuthenticated && !forceInteractive) {
      print("GoogleDriveProvider: Already connected.");
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
    AuthClient? client;

    try {
      if (!forceInteractive) {
        print("GoogleDriveProvider: Attempting silent sign-in...");
        account = await _googleSignIn!.signInSilently();
      }

      if (account == null) {
        print(
            "GoogleDriveProvider: Silent sign-in failed or interactive forced. Attempting interactive sign-in...");
        account = await _googleSignIn!.signIn();
        if (account == null) {
          print("GoogleDriveProvider: Interactive sign-in cancelled by user.");
          _instance?._isAuthenticated =
              false; // Ensure state is false if it was previously true
          return null; // User cancelled
        }
      }
      print("GoogleDriveProvider: Sign-in successful for ${account.email}.");

      // Get the AuthClient from the extension
      client = await _googleSignIn!.authenticatedClient();

      if (client == null) {
        print(
            "GoogleDriveProvider: Failed to get authenticated client. User might not be signed in or credentials issue.");
        await signOut(); // Sign out to clear any problematic state
        _instance?._isAuthenticated = false;
        return null;
      }

      print("GoogleDriveProvider: Authenticated client obtained.");
      final provider = _instance ?? GoogleDriveProvider._create();
      provider.driveApi = drive.DriveApi(client);
      provider._isAuthenticated = true;
      _instance = provider;
      return _instance;
    } catch (error, stackTrace) {
      print(
          'GoogleDriveProvider: Error during sign-in or client retrieval: $error');
      print(stackTrace);
      _instance?._isAuthenticated = false;
      // Optionally sign out if a severe error occurs
      // await signOut();
      return null;
    }
  }

  // Method to sign out
  static Future<void> signOut() async {
    await _googleSignIn?.signOut(); // Sign out from GSI
    await _googleSignIn
        ?.disconnect(); // Disconnect to revoke tokens (optional, more thorough)
    _instance?._isAuthenticated = false;
    _instance = null; // Clear the instance
    print("GoogleDriveProvider: User signed out.");
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
      print("Error uploading file: $e");
      // Check for auth-related errors here if needed, though the client should refresh
      if (e is drive.DetailedApiRequestError &&
          (e.status == 401 || e.status == 403)) {
        print("Authentication error during upload. Attempting to reconnect...");
        _isAuthenticated = false; // Mark as unauthenticated
        // Optionally try to reconnect or notify user
        // await connect(forceInteractive: true);
        // _checkAuth(); // Re-check auth
        // Retry logic could be added here
      }
      rethrow;
    }

    return uploadedFile.id!;
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
            "Authentication error during download. Attempting to reconnect...");
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
        // Consider spaces: 'appDataFolder' for app-specific data, 'drive' for full access
        // spaces: MultiCloudStorage.cloudAccess == CloudAccessType.appStorage ? 'appDataFolder' : 'drive',
      );

      if (fileList.files != null) {
        for (final file in fileList.files!) {
          // Construct full path. For items directly in the listed 'path', it's join(path, file.name).
          // If the item is in a subfolder of listed 'path' (due to recursive or complex query),
          // its path needs to be correctly determined.
          // For non-recursive, it's simpler:
          String currentItemPath = join(path, file.name ?? '');
          if (path == '/' || path.isEmpty) {
            // Handling root path
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

    // Basic recursive implementation (can be very slow and hit API limits for large drives)
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
      print("GoogleDriveProvider: File/Folder to delete not found at $path");
      // Optionally throw an exception if not found behavior is critical
      // throw Exception('File not found for deletion: $path');
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

    // Path for CloudFile should be the original input path.
    // If path normalization occurs (e.g. resolving to root), ensure original path is used.
    return CloudFile(
      path: path, // Use the input path for consistency
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
      // Cannot get a "file" that is the root itself this way,
      // root has special handling or use _getFolderByPath for root folder metadata.
      // This method expects a file or folder *within* another folder.
      if (filePath == '/' || filePath == '.') {
        // Requesting root metadata
        return _getRootFolder();
      }
      return null;
    }

    // Normalize path: remove leading/trailing slashes for consistent splitting
    final normalizedPath =
        filePath.replaceAll(RegExp(r'^/+'), '').replaceAll(RegExp(r'/+$'), '');
    if (normalizedPath.isEmpty)
      return _getRootFolder(); // If path was only slashes

    final parts = split(normalizedPath);
    drive.File currentFolder = await _getRootFolder();

    for (var i = 0; i < parts.length - 1; i++) {
      final folderName = parts[i];
      if (folderName.isEmpty) continue; // Should not happen with normalizedPath
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
      // Path ended with a slash, meaning it's a directory request
      return currentFolder; // This is the directory itself
    }

    final query =
        "'${currentFolder.id}' in parents and name = '${_sanitizeQueryString(fileName)}' and trashed = false";
    final fileList = await driveApi.files.list(
      spaces: MultiCloudStorage.cloudAccess == CloudAccessType.appStorage
          ? 'appDataFolder'
          : 'drive',
      q: query,
      $fields: 'files(id, name, size, modifiedTime, mimeType, parents)',
      // spaces: MultiCloudStorage.cloudAccess == CloudAccessType.appStorage ? 'appDataFolder' : 'drive',
    );

    return fileList.files?.isNotEmpty == true ? fileList.files!.first : null;
  }

  Future<drive.File> _getOrCreateFolder(String folderPath) async {
    _checkAuth();
    if (folderPath.isEmpty || folderPath == '.' || folderPath == '/') {
      return _getRootFolder();
    }

    // Remove leading/trailing slashes for consistent splitting
    final normalizedPath = folderPath
        .replaceAll(RegExp(r'^/+'), '')
        .replaceAll(RegExp(r'/+$'), '');
    if (normalizedPath.isEmpty) return _getRootFolder();

    final parts = split(normalizedPath);
    drive.File currentFolder = await _getRootFolder();

    for (final part in parts) {
      if (part.isEmpty) continue; // Should not happen with normalizedPath

      var folder = await _getFolderByName(currentFolder.id!, part);
      if (folder == null) {
        folder = await _createFolder(currentFolder.id!, part);
      }
      currentFolder = folder;
    }
    return currentFolder;
  }

  Future<drive.File> _getRootFolder() async {
    // In Drive API, the root folder ID is 'root' or 'appDataFolder'
    String rootFolderId = await _getRootFolderId();
    // We generally don't fetch 'root' or 'appDataFolder' details, just use its ID.
    // If you need its metadata, you'd call files.get(rootFolderId).

    if (_instance == null || !_instance!._isAuthenticated) _checkAuth();

    // To get metadata of the root folder if actually needed:
    // return await driveApi.files.get(rootFolderId, $fields: 'id, name, mimeType, parents');

    // For path traversal, just its ID is sufficient:
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
          'files(id, name, mimeType, parents)', // Add mimeType and parents for consistency
      // spaces: MultiCloudStorage.cloudAccess == CloudAccessType.appStorage ? 'appDataFolder' : 'drive',
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

  // Helper to sanitize strings for Drive API queries (names with single quotes)
  String _sanitizeQueryString(String value) {
    return value.replaceAll("'", "\\'");
  }

  @override
  Future<bool> logout() async {
    if (_isAuthenticated) {
      await signOut();
      return true;
    }
    return false;
  }

  @override
  Future<bool> tokenExpired() async {
    if (!_isAuthenticated || _instance == null) return true;

    try {
      // Try a simple API call to check if token is valid
      await driveApi.files.list(
        spaces: MultiCloudStorage.cloudAccess == CloudAccessType.appStorage
            ? 'appDataFolder'
            : 'drive',
        pageSize: 1,
      );
      return false;
    } on drive.DetailedApiRequestError catch (e) {
      if (e.status == 401 || e.status == 403) {
        // Token is invalid or expired
        return true;
      }
      return false; // Some other API error
    } on http.ClientException catch (_) {
      // Likely a network issue, not an auth issue
      return false;
    } catch (_) {
      // Unknown error, assume token is still valid to be safe
      return false;
    }
  }

}
