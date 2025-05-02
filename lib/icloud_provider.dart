import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'cloud_storage_provider.dart';

import 'package:icloud_storage_sync/icloud_storage_sync.dart';

class ICloudProvider extends CloudStorageProvider {
  final icloudSyncPlugin = IcloudStorageSync();
  bool _isAuthenticated = false;
  final String _containerId;

  ICloudProvider.create({
    required String containerId,
  })  : _containerId = containerId;

static  Future<ICloudProvider> connect({
    required String containerId,
  }) async {
    // If this succeeds, we assume the user has access
    return ICloudProvider.create(containerId: containerId,);
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

    await icloudSyncPlugin.upload(
      containerId: _containerId,
      filePath: localPath,
      destinationRelativePath: remotePath,
    );

    return remotePath;
  }

  @override
  Future<String> downloadFile({
    required String remotePath,
    required String localPath,
  }) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    // Note: The package doesn't provide a direct download method
    // We'll need to implement this using the API directly
    throw UnimplementedError('Download functionality not implemented');
  }

  @override
  Future<List<CloudFile>> listFiles({
    required String path,
    bool recursive = false,
  }) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    final items = (await icloudSyncPlugin.getCloudFiles(
      containerId: _containerId,
    ))
        .where((file) => file.filePath == 'path');

    return items
        .map((item) => CloudFile(
              path: item.relativePath ?? '',
              name: item.relativePath?.split('/').last ?? '',
              size: 0, // The package doesn't provide size
              modifiedTime:
                  DateTime.now(), // The package doesn't provide modified time
              isDirectory: false, // The package doesn't provide directory info
              metadata: {
                'id': item.id ?? '',
                'type': 'file',
              },
            ))
        .toList();
  }

  @override
  Future<void> deleteFile(String path) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    await icloudSyncPlugin.delete(
      containerId: _containerId,
      relativePath: path,
    );
  }

  @override
  Future<void> createDirectory(String path) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    // Note: The package doesn't provide a direct create directory method
    // We'll need to implement this using the API directly
    throw UnimplementedError('Create directory functionality not implemented');
  }

  @override
  Future<CloudFile> getFileMetadata(String path) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    // Note: The package doesn't provide a direct get metadata method
    // We'll need to implement this using the API directly
    throw UnimplementedError('Get metadata functionality not implemented');
  }
}
