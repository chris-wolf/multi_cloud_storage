import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:icloud_storage_sync/icloud_storage_sync.dart';
import 'package:icloud_storage_sync/models/exceptions.dart';
import 'package:icloud_storage_sync/models/icloud_file.dart';
import 'package:path/path.dart' as p;

import 'cloud_storage_provider.dart';
import 'not_found_exception.dart';

/// An implementation of [CloudStorageProvider] for Apple's iCloud Drive.
///
/// This provider uses the `iCloud_Storage_Sync` package to interact with iCloud.
/// Note that iCloud functionality is only available on iOS devices.
class ICloudStorageProvider extends CloudStorageProvider {
  late final IcloudStorageSync _icloudSync;
  late final String _containerId;
  static ICloudStorageProvider? _instance;

  /// Private constructor for the singleton pattern.
  ICloudStorageProvider._create(this._containerId) {
    _icloudSync = IcloudStorageSync();
  }

  /// Establishes a connection to iCloud storage.
  ///
  /// On success, returns a singleton instance of [ICloudStorageProvider].
  ///
  /// This method requires the iCloud [containerId] specific to your app.
  /// It will throw an [UnsupportedError] if called on a non-iOS platform.
  static Future<ICloudStorageProvider?> connect(
      {required String containerId}) async {
    // iCloud is only available on iOS.
    if (Platform.isIOS == false && Platform.isMacOS == false) {
      debugPrint('iCloud Storage is only available on iOS and.');
      throw UnsupportedError(
          'iCloud Storage is only available on iOS and MacOs.');
    }
    _instance ??= ICloudStorageProvider._create(containerId);
    return _instance;
  }

  //----------------------------------------------------------------------------
  // ## Implemented Methods
  //----------------------------------------------------------------------------

  @override
  Future<String> uploadFile({
    required String localPath,
    required String remotePath,
    Map<String, dynamic>? metadata, // Note: iCloud metadata is not supported.
  }) async {
    await _icloudSync.upload(
      containerId: _containerId,
      filePath: localPath,
      destinationRelativePath: _sanitizePath(remotePath),
    );
    // For iCloud, the path acts as the identifier.
    return remotePath;
  }

  @override
  Future<String> downloadFile({
    required String remotePath,
    required String localPath,
  }) async {
    try {
      await _icloudSync.download(
        containerId: _containerId,
        relativePath: _sanitizePath(remotePath),
        destinationFilePath: localPath,
      );
      return localPath;
    } on PlatformException catch (e) {
      // Check for the specific "File Not Found" error from the native iOS/macOS side.
      // NSCocoaErrorDomain code 4 is the standard file-not-found error.
      if (e.toString().contains('NSCocoaErrorDomain Code=4')) {
        // Convert the platform-specific error into our abstract NotFoundException
        throw NotFoundException(
          'File not found in iCloud at path: $remotePath. Original error: ${e.toString()}',
        );
      }
      // For any other platform exceptions, rethrow them as they are unexpected.
      rethrow;
    }
  }

  @override
  Future<List<CloudFile>> listFiles({
    required String path,
    bool recursive = false,
  }) async {
    // The package fetches all file metadata at once.
    final allFiles = await _icloudSync.gather(containerId: _containerId);
    final List<CloudFile> results = [];

    // Normalize the directory path for consistent comparison.
    final normalizedPath =
        path == '/' ? '' : path.replaceAll(RegExp(r'/$'), '');

    for (final icloudFile in allFiles) {
      final itemPath = icloudFile.relativePath;

      if (recursive) {
        // For recursive, check if the item path starts with the directory path.
        if (itemPath.startsWith(normalizedPath)) {
          results.add(_mapToCloudFile(icloudFile));
        }
      } else {
        // For non-recursive, check if the item is a direct child.
        // The parent directory of the item should be the same as the target path.
        final parentDir = p.dirname(itemPath);
        final rootEquivalent = parentDir == '.' &&
            (normalizedPath.isEmpty || normalizedPath == '/');

        if (parentDir == normalizedPath || rootEquivalent) {
          results.add(_mapToCloudFile(icloudFile));
        }
      }
    }
    return results;
  }

  @override
  Future<void> deleteFile(String path) async {
    await _icloudSync.delete(
      containerId: _containerId,
      relativePath: path,
    );
  }

  @override
  Future<CloudFile> getFileMetadata(String path) async {
    final allFiles = await _icloudSync.gather(containerId: _containerId);
    final foundFile = allFiles.firstWhere(
      (f) => f.relativePath == path,
      orElse: () =>
          throw Exception('iCloudProvider: File not found at path: $path'),
    );
    return _mapToCloudFile(foundFile);
  }

  /// Helper to convert from the package's model to the abstract model.
  CloudFile _mapToCloudFile(ICloudFile icloudFile) {
    return CloudFile(
      path: icloudFile.relativePath,
      name: p.basename(icloudFile.relativePath),
      size: icloudFile.sizeInBytes,
      modifiedTime: icloudFile.contentChangeDate,
      isDirectory: icloudFile.relativePath.endsWith('/'),
      // Metadata is not natively supported by the iCloud package in the same way.
      metadata: {'relativePath': icloudFile.relativePath},
    );
  }

  //----------------------------------------------------------------------------
  // ## Partially or Not Implemented Methods
  //----------------------------------------------------------------------------

  @override
  Future<String> uploadFileByShareToken({
    required String localPath,
    required String shareToken,
    Map<String, dynamic>? metadata,
  }) async {
    throw UnsupportedError(
        'iCloud doesn\'t allow sharing of files since each app has its own container');
  }

  @override
  Future<void> createDirectory(String path) {
    // The `iCloud_Storage_Sync` package does not provide a method to explicitly
    // create an empty directory. Directories are created implicitly when a file
    // is uploaded into a non-existent path.
    throw UnimplementedError(
        'iCloudProvider: createDirectory is not supported. Directories are created automatically upon file upload.');
  }

  @override
  Future<bool> logout() async {
    _instance = null;
    return true;
  }

  @override
  Future<bool> tokenExpired() async {
    // The app does not manage iCloud authentication tokens; the OS does.
    // We can assume the token is always valid if the user is logged into iCloud.
    return false;
  }

  @override
  Future<String?> loggedInUserDisplayName() {
    // The package does not provide access to user information like display name.
    throw UnimplementedError(
        'iCloudProvider: Cannot retrieve user display name.');
  }

  @override
  Future<Uri?> generateShareLink(String path) {
    // The package does not support creating sharable links.
    throw UnimplementedError(
        'iCloudProvider: Generating sharable links is not supported.');
  }

  @override
  Future<String?> getShareTokenFromShareLink(Uri shareLink) async {
    return null;  // The package does not support sharing.
  }

  /// Removes a leading slash from a path, as the iCloud package requires it.
  String _sanitizePath(String path) {
    if (path.startsWith('/')) {
      return path.substring(1);
    }
    return path;
  }

  @override
  Future<String> downloadFileByShareToken(
      {required String shareToken, required String localPath}) {
    // The package does not support sharing.
    throw UnimplementedError(
        'iCloudProvider: Sharing functionality is not supported.');
  }
}
