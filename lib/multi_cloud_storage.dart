import 'package:flutter/foundation.dart';
import 'package:multi_cloud_storage/src/providers/cloud_storage_provider.dart';
import 'package:multi_cloud_storage/src/providers/google_drive_provider.dart';
import 'package:multi_cloud_storage/src/providers/dropbox_provider.dart';
import 'package:multi_cloud_storage/src/providers/onedrive_provider.dart';
import 'package:multi_cloud_storage/src/providers/icloud_provider.dart';

/// A class that provides a unified interface for multiple cloud storage providers.
class MultiCloudStorage {
  /// Creates a new instance of [MultiCloudStorage].
  MultiCloudStorage();

  /// The currently selected cloud storage provider.
  CloudStorageProvider? _currentProvider;

  /// Sets the current cloud storage provider.
  void setProvider(CloudProviderType type) {
    switch (type) {
      case CloudProviderType.googleDrive:
        _currentProvider = GoogleDriveProvider();
        break;
      case CloudProviderType.dropbox:
        _currentProvider = DropboxProvider();
        break;
      case CloudProviderType.oneDrive:
        _currentProvider = OneDriveProvider();
        break;
      case CloudProviderType.iCloud:
        _currentProvider = ICloudProvider();
        break;
    }
  }

  /// Authenticates with the current cloud storage provider.
  Future<void> authenticate() async {
    if (_currentProvider == null) {
      throw Exception('No cloud provider selected');
    }
    await _currentProvider!.authenticate();
  }

  /// Uploads a file to the cloud storage.
  Future<String> uploadFile({
    required String localPath,
    required String remotePath,
    Map<String, dynamic>? metadata,
  }) async {
    if (_currentProvider == null) {
      throw Exception('No cloud provider selected');
    }
    return _currentProvider!.uploadFile(
      localPath: localPath,
      remotePath: remotePath,
      metadata: metadata,
    );
  }

  /// Downloads a file from the cloud storage.
  Future<String> downloadFile({
    required String remotePath,
    required String localPath,
  }) async {
    if (_currentProvider == null) {
      throw Exception('No cloud provider selected');
    }
    return _currentProvider!.downloadFile(
      remotePath: remotePath,
      localPath: localPath,
    );
  }

  /// Lists files in a directory.
  Future<List<CloudFile>> listFiles({
    required String path,
    bool recursive = false,
  }) async {
    if (_currentProvider == null) {
      throw Exception('No cloud provider selected');
    }
    return _currentProvider!.listFiles(
      path: path,
      recursive: recursive,
    );
  }

  /// Deletes a file from the cloud storage.
  Future<void> deleteFile(String path) async {
    if (_currentProvider == null) {
      throw Exception('No cloud provider selected');
    }
    await _currentProvider!.deleteFile(path);
  }

  /// Creates a new directory in the cloud storage.
  Future<void> createDirectory(String path) async {
    if (_currentProvider == null) {
      throw Exception('No cloud provider selected');
    }
    await _currentProvider!.createDirectory(path);
  }

  /// Gets the metadata of a file.
  Future<CloudFile> getFileMetadata(String path) async {
    if (_currentProvider == null) {
      throw Exception('No cloud provider selected');
    }
    return _currentProvider!.getFileMetadata(path);
  }
}

/// Represents a file in cloud storage.
class CloudFile {
  final String path;
  final String name;
  final int size;
  final DateTime modifiedTime;
  final bool isDirectory;
  final Map<String, dynamic>? metadata;

  CloudFile({
    required this.path,
    required this.name,
    required this.size,
    required this.modifiedTime,
    required this.isDirectory,
    this.metadata,
  });
}

/// Enum representing different cloud storage providers.
enum CloudProviderType {
  googleDrive,
  dropbox,
  oneDrive,
  iCloud,
}
