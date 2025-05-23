import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:dropbox_client/dropbox_client.dart';
import 'cloud_storage_provider.dart';
import 'package:http/http.dart' as http;

class DropboxProvider extends CloudStorageProvider {
  bool _isAuthenticated = false;
  late String appKey;
  late String appSecret;
  late String redirectUri;

  DropboxProvider._instance({
    required this.appKey,
    required this.appSecret,
    required this.redirectUri,
  });

  static Future<DropboxProvider?> connect(
      {required String appKey,
      required String appSecret,
      required String redirectUri,
      String? accessToken}) async {
    if (appKey.trim().isEmpty &&
        redirectUri.trim().isEmpty &&
        (accessToken?.isEmpty ?? true)) {
      throw ArgumentError(
          'App registration required required https://www.dropbox.com/developers/apps');
    }

    await Dropbox.init(appKey, appKey, appSecret);
    if (accessToken == null) {
      await Dropbox.authorizePKCE();
    } else {
      await Dropbox.authorizeWithAccessToken(accessToken);
    }
    if ((await Dropbox.getAccessToken()) == null) {
      return null;
    }
    return DropboxProvider._instance(
        appKey: appKey, appSecret: appSecret, redirectUri: redirectUri)
      .._isAuthenticated = true;
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

    final fixedPath = (path == '/' ? '' : path);
    final result = await Dropbox.listFolder(fixedPath);
    final List<dynamic> entries = result ?? [];

    return entries.map((entry) {
      final isFolder = (entry['name'] ?? '').contains('.') == false;
      return CloudFile(
        path: entry['pathDisplay'] ?? '',
        name: entry['name'] ?? '',
        size: entry['size'],
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

    final accessToken = await Dropbox.getAccessToken();

    final response = await http.post(
      Uri.parse('https://api.dropboxapi.com/2/files/delete_v2'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'path': path.startsWith('/') ? path : '/$path',
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to delete file: ${response.body}');
    }
  }

  @override
  Future<void> createDirectory(String path) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    final response = await http.post(
      Uri.parse('https://api.dropboxapi.com/2/files/create_folder_v2'),
      headers: {
        'Authorization': 'Bearer ${(await Dropbox.getAccessToken()) ?? ''}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'path': path,
        'autorename': false,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to create directory: ${response.body}');
    }
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

  @override
  Future<bool> logout() async {
    if (_isAuthenticated) {
      await Dropbox.authorizeWithAccessToken('');
      _isAuthenticated = false;
      return true;
    }
    return false;
  }
}
