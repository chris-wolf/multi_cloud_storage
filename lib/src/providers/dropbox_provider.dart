import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:dropbox_client/dropbox_client.dart';
import 'package:path/path.dart' as path;
import 'cloud_storage_provider.dart';

class DropboxProvider implements CloudStorageProvider {
  late DropboxClient _client;
  bool _isAuthenticated = false;
  final String _appKey;
  final String _appSecret;
  final String _redirectUri;

  DropboxProvider({
    required String appKey,
    required String appSecret,
    required String redirectUri,
  })  : _appKey = appKey,
        _appSecret = appSecret,
        _redirectUri = redirectUri;

  @override
  Future<void> authenticate() async {
    _client = DropboxClient(
      appKey: _appKey,
      appSecret: _appSecret,
      redirectUri: _redirectUri,
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

    await _client.files.upload(
      remoteFilePath,
      file.readAsBytesSync(),
      mode: WriteMode.overwrite,
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

    final file = File(localPath);
    final response = await _client.files.download(remotePath);
    await file.writeAsBytes(response);

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

    final result = await _client.files.listFolder(
      path,
      recursive: recursive,
    );

    return result.entries
        .map((entry) => CloudFile(
              path: entry.pathDisplay!,
              name: entry.name!,
              size: entry.size ?? 0,
              modifiedTime: DateTime.parse(entry.serverModified!),
              isDirectory: entry is FolderMetadata,
              metadata: {
                'id': entry.id,
                'tag': entry.tag,
              },
            ))
        .toList();
  }

  @override
  Future<void> deleteFile(String path) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    await _client.files.delete(path);
  }

  @override
  Future<void> createDirectory(String path) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    await _client.files.createFolder(path);
  }

  @override
  Future<CloudFile> getFileMetadata(String path) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    final metadata = await _client.files.getMetadata(path);

    return CloudFile(
      path: metadata.pathDisplay!,
      name: metadata.name!,
      size: metadata.size ?? 0,
      modifiedTime: DateTime.parse(metadata.serverModified!),
      isDirectory: metadata is FolderMetadata,
      metadata: {
        'id': metadata.id,
        'tag': metadata.tag,
      },
    );
  }
}
