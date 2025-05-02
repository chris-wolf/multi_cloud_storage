import 'package:flutter/services.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'multi_cloud_storage.dart';

/// The interface that implementations of multi_cloud_storage must implement.
class MultiCloudStoragePlatform extends MultiCloudStorage {
  /// The default instance of [MultiCloudStoragePlatform] to use.
  static MultiCloudStoragePlatform _instance = MultiCloudStoragePlatform._();

  /// Default constructor for the platform interface.
  MultiCloudStoragePlatform._() : super();

  /// The default instance of [MultiCloudStoragePlatform] to use.
  static MultiCloudStoragePlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [MultiCloudStoragePlatform] when
  /// they register themselves.
  static set instance(MultiCloudStoragePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  @override
  Future<void> initialize() async {
    throw UnimplementedError('initialize() has not been implemented.');
  }

  @override
  Future<bool> authenticate() async {
    throw UnimplementedError('authenticate() has not been implemented.');
  }

  @override
  Future<String> uploadFile({
    required String localPath,
    required String remotePath,
    Map<String, String>? metadata,
  }) async {
    throw UnimplementedError('uploadFile() has not been implemented.');
  }

  @override
  Future<String> downloadFile({
    required String remotePath,
    required String localPath,
  }) async {
    throw UnimplementedError('downloadFile() has not been implemented.');
  }

  @override
  Future<List<CloudFile>> listFiles({
    required String path,
    bool recursive = false,
  }) async {
    throw UnimplementedError('listFiles() has not been implemented.');
  }

  @override
  Future<bool> deleteFile(String path) async {
    throw UnimplementedError('deleteFile() has not been implemented.');
  }

  @override
  Future<CloudFile> getFileMetadata(String path) async {
    throw UnimplementedError('getFileMetadata() has not been implemented.');
  }

  @override
  Future<bool> createDirectory(String path) async {
    throw UnimplementedError('createDirectory() has not been implemented.');
  }

  @override
  Future<bool> moveFile({
    required String sourcePath,
    required String destinationPath,
  }) async {
    throw UnimplementedError('moveFile() has not been implemented.');
  }

  @override
  Future<bool> copyFile({
    required String sourcePath,
    required String destinationPath,
  }) async {
    throw UnimplementedError('copyFile() has not been implemented.');
  }

  @override
  Future<bool> fileExists(String path) async {
    throw UnimplementedError('fileExists() has not been implemented.');
  }

  @override
  Future<StorageSpace> getStorageSpace() async {
    throw UnimplementedError('getStorageSpace() has not been implemented.');
  }
}
