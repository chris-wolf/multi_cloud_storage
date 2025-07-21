import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:icloud_storage_sync/icloud_storage_sync.dart';
import 'package:icloud_storage_sync/models/icloud_file.dart';
import 'package:path/path.dart' as p;

import 'cloud_storage_provider.dart';
import 'exceptions/no_connection_exception.dart';
import 'exceptions/not_found_exception.dart';

class ICloudProvider extends CloudStorageProvider {
  late final IcloudStorageSync _icloudSync;
  late final String _containerId;
  static ICloudProvider? _instance;

  ICloudProvider._create(this._containerId) {
    _icloudSync = IcloudStorageSync();
  }

  /// Establishes a connection to iCloud storage.
  ///
  /// On success, returns a singleton instance of [ICloudProvider].
  ///
  /// This method requires the iCloud [containerId] specific to your app.
  /// It will throw an [UnsupportedError] if called on a non-iOS platform.
  static Future<ICloudProvider?> connect(
      {required String containerId}) async {
    // iCloud is only available on iOS.
    if (Platform.isIOS == false && Platform.isMacOS == false) {
      debugPrint('iCloud Storage is only available on iOS and.');
      throw UnsupportedError(
          'iCloud Storage is only available on iOS and MacOs.');
    }
    _instance ??= ICloudProvider._create(containerId);
    return _instance;
  }

  /// Lists all files and directories at the specified [path].
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

  /// Downloads a file from a [remotePath] to a [localPath] on the device.
  @override
  Future<String> downloadFile({
    required String remotePath,
    required String localPath,
  }) async {
    final completer = Completer<String>();
    StreamSubscription? progressSubscription;
    try {
      await _icloudSync.download(
        containerId: _containerId,
        relativePath: _sanitizePath(remotePath),
        destinationFilePath: localPath,
        onProgress: (stream) {
          // This listener is now for in-progress updates and potential mid-stream errors.
          progressSubscription = stream.listen(
                (progress) {
              // You can handle progress updates here if needed.
              debugPrint('Download progress: $progress');
            },
            onError: (error) {
              // This handles errors that might occur *during* the download stream.
              if (!completer.isCompleted) {
                // You can still keep your original checks here as a fallback.
                if (error is PlatformException && error.toString().contains('NSURLErrorDomain Code=-1009')) {
                  completer.completeError(NoConnectionException(error.toString()));
                } else if (error.toString().contains('NSCocoaErrorDomain Code=4')) {
                  completer.completeError(NotFoundException(error.toString()));
                } else {
                  completer.completeError(Exception('iCloud download failed during stream: $error'));
                }
              }
            },
            onDone: () {
              if (!completer.isCompleted) {
                completer.complete(localPath);
              }
            },
            cancelOnError: true,
          );
        },
      );
      // If the download call completes without an error but the completer is still not done,
      // it means we are waiting for the onDone callback from the stream.
    } on PlatformException catch (e) {
      // **FIX:** Handle initial errors, like "file not found", here.
      if (!completer.isCompleted) {
        if (e.toString().contains('NSCocoaErrorDomain Code=4')) {
          completer.completeError(NotFoundException('File not found at path: $remotePath'));
        } else if (e.toString().contains('NSURLErrorDomain Code=-1009')) {
          completer.completeError(NoConnectionException('Failed to download from iCloud. Check your internet connection.'));
        } else {
          completer.completeError(e); // Rethrow other platform exceptions.
        }
      }
    } catch (e) {
      // Catch any other general exceptions.
      if (!completer.isCompleted) {
        completer.completeError(e);
      }
    }

    try {
      return await completer.future;
    } finally {
      // Ensure the subscription is cancelled to prevent memory leaks.
      await progressSubscription?.cancel();
    }
  }

  /// Uploads a file from a [localPath] to a [remotePath] in the cloud.
  @override
  Future<String> uploadFile({
    required String localPath,
    required String remotePath,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      await _icloudSync.upload(
        containerId: _containerId,
        filePath: localPath,
        destinationRelativePath: _sanitizePath(remotePath),
      );
      return remotePath;
    } on PlatformException catch (e) {
      // ADD THIS CHECK: for "No Connection" (NSURLErrorDomain Code -1009)
      if (e.code == '-1009' || e.toString().contains('NSURLErrorDomain Code=-1009')) {
        throw NoConnectionException('Failed to upload to iCloud. Please check your internet connection.');
      }
      rethrow;
    }
  }

  /// Deletes the file or directory at the specified [path].
  @override
  Future<void> deleteFile(String path) async {
    await _icloudSync.delete(
      containerId: _containerId,
      relativePath: path,
    );
  }

  @override
  Future<void> createDirectory(String path) {
    // The `iCloud_Storage_Sync` package does not provide a method to explicitly
    // create an empty directory. Directories are created implicitly when a file
    // is uploaded into a non-existent path.
    throw UnimplementedError(
        'iCloudProvider: createDirectory is not supported. Directories are created automatically upon file upload.');
  }

  /// Retrieves metadata for the file or directory at the specified [path].
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

  @override
  Future<String?> loggedInUserDisplayName() {
    // The package does not provide access to user information like display name.
    throw UnimplementedError(
        'iCloudProvider: Cannot retrieve user display name.');
  }

  @override
  Future<bool> tokenExpired() async {
    // The app does not manage iCloud authentication tokens; the OS does.
    // We can assume the token is always valid if the user is logged into iCloud.
    return false;
  }

  /// logout not necessary since only current appleId user can login, so just clear isntance
  @override
  Future<bool> logout() async {
    _instance = null;
    return true;
  }

  /// iCloud access is limited to the container and can't share files directly.
  @override
  Future<Uri?> generateShareLink(String path) {
    throw UnsupportedError(
        'iCloudProvider: Generating sharable links is not supported.');
  }

  /// iCloud access is limited to the container and can't share files directly.
  @override
  Future<String?> getShareTokenFromShareLink(Uri shareLink) async {
    return null; // The package does not support sharing.
  }

  /// iCloud access is limited to the container and can't share files directly.
  @override
  Future<String> downloadFileByShareToken(
      {required String shareToken, required String localPath}) {
    // The package does not support sharing.
    throw UnsupportedError(
        'iCloudProvider: Sharing functionality is not supported.');
  }

  /// iCloud access is limited to the container and can't share files directly.
  @override
  Future<String> uploadFileByShareToken({
    required String localPath,
    required String shareToken,
    Map<String, dynamic>? metadata,
  }) async {
    throw UnsupportedError(
        'iCloud doesn\'t allow sharing of files since each app has its own container');
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

  /// Removes a leading slash from a path, as the iCloud package requires it.
  String _sanitizePath(String path) {
    if (path.startsWith('/')) {
      return path.substring(1);
    }
    return path;
  }
}
