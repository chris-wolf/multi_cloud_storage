import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:icloud_storage_sync/icloud_storage_sync.dart';
import 'package:path/path.dart' as path;
import 'cloud_storage_provider.dart';

class ICloudProvider implements CloudStorageProvider {
  late ICloudStorageSync _client;
  bool _isAuthenticated = false;
  final String _containerId;
  final String _teamId;

  ICloudProvider({
    required String containerId,
    required String teamId,
  })  : _containerId = containerId,
        _teamId = teamId;

  @override
  Future<void> authenticate() async {
    _client = ICloudStorageSync(
      containerId: _containerId,
      teamId: _teamId,
    );

    await _client.authenticate();
    _isAuthenticated = true;
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

    final file = File(localPath);
    final fileName = path.basename(localPath);
    final remoteFilePath = path.join(remotePath, fileName);

    await _client.uploadFile(
      localPath: localPath,
      remotePath: remoteFilePath,
    );

    return remoteFilePath;
  }

  @override
  Future<String> downloadFile({
    required String remotePath,
    required String localPath,
  }) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    await _client.downloadFile(
      remotePath: remotePath,
      localPath: localPath,
    );

    return localPath;
  }

  @override
  Future<List<CloudFile>> listFiles({
    required String path,
    bool recursive = false,
  }) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    final items = await _client.listItems(path);

    return items
        .map((item) => CloudFile(
              path: item.path,
              name: item.name,
              size: item.size,
              modifiedTime: item.modifiedTime,
              isDirectory: item.isDirectory,
              metadata: {
                'id': item.id,
                'type': item.type,
              },
            ))
        .toList();
  }

  @override
  Future<void> deleteFile(String path) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    await _client.deleteItem(path);
  }

  @override
  Future<void> createDirectory(String path) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    await _client.createDirectory(path);
  }

  @override
  Future<CloudFile> getFileMetadata(String path) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    final item = await _client.getItem(path);

    return CloudFile(
      path: item.path,
      name: item.name,
      size: item.size,
      modifiedTime: item.modifiedTime,
      isDirectory: item.isDirectory,
      metadata: {
        'id': item.id,
        'type': item.type,
      },
    );
  }
}
