import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:dropbox_client/dropbox_client.dart';
import 'package:path/path.dart' as path;
import 'cloud_storage_provider.dart';

class DropboxProvider extends CloudStorageProvider {
  bool _isAuthenticated = false;
  late String _appKey;
  late String _appSecret;
  late String _redirectUri;

  DropboxProvider._instance({
    required String appKey,
    required String appSecret,
    required String redirectUri,
  })  : _appKey = appKey,
        _appSecret = appSecret,
        _redirectUri = redirectUri;

  static Future<DropboxProvider> connect(
      {required String appKey,
      required String appSecret,
      required String redirectUri}) async {
    await Dropbox.init(appKey, appKey, appSecret);
    await Dropbox.authorizePKCE();
    return DropboxProvider._instance(appKey: appKey, appSecret: appSecret, redirectUri: redirectUri);
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

    await Dropbox.upload(localPath, remotePath, (uploaded, total) {
      debugPrint('Upload progress: $uploaded / $total');
    });

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

    await Dropbox.download(remotePath, localPath, (downloaded, total) {
      debugPrint('Download progress: $downloaded / $total');
    });

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

    final result = await Dropbox.listFolder(path);
    final List<dynamic> entries = result['entries'] ?? [];

    return entries.map((entry) {
      final isFolder = entry['.tag'] == 'folder';
      return CloudFile(
        path: entry['path_display'] ?? '',
        name: entry['name'] ?? '',
        size: entry['size'] ?? 0,
        modifiedTime: DateTime.parse(
            entry['server_modified'] ?? DateTime.now().toIso8601String()),
        isDirectory: isFolder,
        metadata: {
          'id': entry['id'],
          'tag': entry['.tag'],
        },
      );
    }).toList();
  }

  @override
  Future<void> deleteFile(String path) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    // Note: The delete method is not directly exposed in the package
    // We'll need to implement this using the API directly
    throw UnimplementedError('Delete functionality not implemented');
  }

  @override
  Future<void> createDirectory(String path) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    // Note: The createFolder method is not directly exposed in the package
    // We'll need to implement this using the API directly
    throw UnimplementedError('Create directory functionality not implemented');
  }

  @override
  Future<CloudFile> getFileMetadata(String path) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    // Note: The getMetadata method is not directly exposed in the package
    // We'll need to implement this using the API directly
    throw UnimplementedError('Get metadata functionality not implemented');
  }
}
