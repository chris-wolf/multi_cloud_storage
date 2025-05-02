import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_onedrive/flutter_onedrive.dart';
import 'package:path/path.dart' as path;
import 'cloud_storage_provider.dart';

class OneDriveProvider implements CloudStorageProvider {
  late FlutterOneDrive _client;
  bool _isAuthenticated = false;
  final String _clientId;
  final String _clientSecret;
  final String _redirectUri;
  final List<String> _scopes = [
    'Files.ReadWrite',
    'Files.ReadWrite.All',
    'Sites.ReadWrite.All',
  ];

  OneDriveProvider({
    required String clientId,
    required String clientSecret,
    required String redirectUri,
  })  : _clientId = clientId,
        _clientSecret = clientSecret,
        _redirectUri = redirectUri;

  @override
  Future<void> authenticate() async {
    _client = FlutterOneDrive(
      clientId: _clientId,
      clientSecret: _clientSecret,
      redirectUri: _redirectUri,
      scopes: _scopes,
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
              isDirectory: item.isFolder,
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

    await _client.createFolder(path);
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
      isDirectory: item.isFolder,
      metadata: {
        'id': item.id,
        'type': item.type,
      },
    );
  }
}
