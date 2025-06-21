import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:dropbox_client/dropbox_client.dart';
import 'package:flutter/material.dart';
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
    final lifecycleWaiter = _AppLifecycleWaiter();
    await lifecycleWaiter.waitForResumed();
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
      debugdebugPrint('Upload progress: $uploaded / $total');
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
        debugdebugPrint('Download progress: $downloaded / $total');
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
  @override
  Future<CloudFile> getFileMetadata(String path) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    final accessToken = await Dropbox.getAccessToken();
    final fixedPath = path.startsWith('/') ? path : '/$path';

    final response = await http.post(
      Uri.parse('https://api.dropboxapi.com/2/files/get_metadata'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'path': fixedPath,
        'include_media_info': false,
        'include_deleted': false,
        'include_has_explicit_shared_members': false,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to get file metadata: ${response.body}');
    }

    final metadata = jsonDecode(response.body);
    final isFolder = metadata['.tag'] == 'folder';

    return CloudFile(
      path: metadata['path_display'] ?? '',
      name: metadata['name'] ?? '',
      size: metadata['size'] ?? 0,
      modifiedTime: DateTime.tryParse(metadata['server_modified'] ?? '') ??
          DateTime.now(),
      isDirectory: isFolder,
      metadata: {
        'id': metadata['id'],
        'tag': metadata['.tag'],
      },
    );
  }


  @override
  Future<Uri?> generateSharableLink(String path) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    final accessToken = await Dropbox.getAccessToken();
    final fixedPath = path.startsWith('/') ? path : '/$path';

    try {
      // Create a shared link with default visibility
      final response = await http.post(
        Uri.parse('https://api.dropboxapi.com/2/sharing/create_shared_link_with_settings'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'path': fixedPath,
          'settings': {
            'requested_visibility': 'public',
          },
        }),
      );

      if (response.statusCode != 200) {
        debugPrint("DropboxProvider: Failed to create shared link: ${response.body}");
        return null;
      }

      final json = jsonDecode(response.body);
      final url = json['url'];
      if (url == null) {
        debugPrint("DropboxProvider: No URL returned.");
        return null;
      }

      // Optionally encode original path info as query parameters
      final shareableUri = Uri.parse(url).replace(
        queryParameters: {
          ...Uri.parse(url).queryParameters,
          'originalPath': path,
        },
      );

      return shareableUri;
    } catch (e) {
      debugPrint("DropboxProvider: Error generating shareable link: $e");
      return null;
    }
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

  @override
  Future<bool> tokenExpired() async {
    if (!_isAuthenticated) return true;
    final token = await Dropbox.getAccessToken();
    return token == null || token.isEmpty;
  }

  @override
  Future<String> getSharedFileById({
    required String fileId,
    required String localPath,
  }) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    final accessToken = await Dropbox.getAccessToken();

    final response = await http.post(
      Uri.parse('https://content.dropboxapi.com/2/sharing/get_shared_link_file'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Dropbox-API-Arg': jsonEncode({
          'url': fileId, // Dropbox shared links act as file IDs
        }),
      },
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to download shared file: ${response.body}');
    }

    final file = await _writeToFile(response.bodyBytes, localPath);
    return file.path;
  }

  Future<File> _writeToFile(Uint8List data, String path) async {
    final file = File(path);
    await file.create(recursive: true);
    await file.writeAsBytes(data);
    return file;
  }

  @override
  Future<String> uploadFileById({required String localPath, required String fileId, Map<String, dynamic>? metadata}) {
    // TODO: implement uploadFileById
    throw UnimplementedError();
  }

  @override
  Future<String?> loggedInUserDisplayName() async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    final accessToken = await Dropbox.getAccessToken();

    final response = await http.post(
      Uri.parse('https://api.dropboxapi.com/2/users/get_current_account'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
    );

    if (response.statusCode != 200) {
      debugdebugPrint('Failed to fetch user info: ${response.body}');
      return null;
    }

    final json = jsonDecode(response.body);
    return json['name']?['display_name'];
  }

  @override
  Future<String?> extractFileIdFromSharableLink(Uri shareLink) {
    // TODO: implement extractFileIdFromSharableLink
    throw UnimplementedError();
  }

}


class _AppLifecycleWaiter with WidgetsBindingObserver {
  final Completer<void> _resumedCompleter = Completer<void>();

  _AppLifecycleWaiter() {
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> waitForResumed() async {
    return _resumedCompleter.future;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_resumedCompleter.isCompleted) {
      _resumedCompleter.complete();
      WidgetsBinding.instance.removeObserver(this);
    }
  }
}