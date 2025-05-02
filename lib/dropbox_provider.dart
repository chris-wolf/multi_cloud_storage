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
      required String redirectUri, String? accessToken}) async {

    await Dropbox.init(appKey, appKey, appSecret);
    if (accessToken == null) {
      await Dropbox.authorizePKCE();
    } else {
      await Dropbox.authorizeWithAccessToken('sl.u.AFuyaXaxQST3P78Oau0M31t-7e3gPDjt3RNTybzxg_lwMaprZt9adta8-EQjb8XHtwSyhoCp1mDWoju87oxxuBPjyvJvoQM9z7La6MoYt_rSHbPlJQ6wYydm2pQo_SmWDmD_cNrlSKE1Kuabs51hOLbBQJu5Ed8nPXwrtjFMAHb1ApGwK1iJcSOyTISrWbH0dLdzL7uuVjG87iHUMMCNjbEbTiI0aGpFMzK5b8Nfn71W3A0nrRQ1zVxTeTQ4c9SvYYQBt6utixdUZ4BA1IPfsruBnWa_xZZmf0p6P9TgIPRm6Fshl-MztMwaE49OBcpZY7I1HfWSoUuaFdIz-CphDdidYWQEZiuYpcPF1zNozf2HYfNtxgvHgVOAGJJ5jCR55O4wXXl3Zmk1hGEXWruV99fZmIRSZzRXgEhjxiPV3NqaU4UrDkddtQRb0ZfNrEtgJ41zjAgZue9P_HJ6zVb8G4GK7c3Lo4d1QA6Ayr9qZEv3Q-CmytEQPJq7P0XeXBKkGQRhO8WKz8I6oY2g0T15zQvKeVOgnMc7PMneIhMQFuirQXFYxqyxmZDj8WXUh6ceOabSV6LKC9ZwrPhViq1vEg9FwsJU3QH9TlG6sBfFLtGJl5Psuq4QRUHVyyidspJ-dmO5PmxucYXSdBc2cVLOobnNMFFAGCGZYW-CsRdqXjvCOsfDuSGv6ZaeeJ2Vzed8VIrPv7mJ5tR3z11-BBfjZVlAsXd4fWlK0Q7BPZDIvP1fpd4OSZqkfNjw88n4QqsYZiqzLE0KO1yaXg2kI-U2AlUaVM2PnNno9CmILslfLJ93Nb7F87HHNbSlLTIPDmsL8l9uhm63mrCDdAIAqfOjxPmP4SB1Hbg3Ic2NgKvXglt51LhDWhruvAe69Ynd4QW_IxTRrpY93yRQ40CCCzfAAwUALLCKhu7xtRpTxAmf1cX0yn9UHYRA2mJJWwzvpE2rrTtwve-2vVlswVnTniU0P7RoNnKKLsJCVYjSXjsqi2JfkoYAoQ-JOTQd-ewzuR4qhE-HiwOhG8rnXKH4_kTPy7Nptj86ovSb0ssKrTDfzfclf81z149pSE05mvd0OT3rVfuLoQa9RwHwGCzxQyiPYoxUr41-sYlzDftm-douEXYUCjEoBFseCgHd1-Lvk9UIDPWoEL4icLc0M67r-M_cD8vUc6AlDkGeABcGRV93ihMQJMAz8UiKtwFQpiPoTHc3Uw1SCW6duN1BSTjSDohDS28zXNmvtyaCrf99nbapBG-08MJS6hwyRGXECrmsFsgGsAhvM46vLq2ErzMJHjkFMUhR7d7DXjvoiaV9TEprnvkjDQ');
    }
   // await Dropbox.authorizePKCE();
    return DropboxProvider._instance(appKey: appKey, appSecret: appSecret, redirectUri: redirectUri).._isAuthenticated = true;
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
