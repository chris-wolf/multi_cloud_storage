import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_onedrive/flutter_onedrive.dart';
import 'package:flutter_onedrive/token.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';

import '../main.dart'; // Assuming your global logger is accessible via main.dart
import 'cloud_storage_provider.dart';
import 'file_log_output.dart'; // Assuming you have these custom classes
import 'multi_cloud_storage.dart';

class OneDriveProvider extends CloudStorageProvider {
  late OneDrive client;
  bool _isAuthenticated = false;
  final String clientId;
  final String redirectUri;
  final BuildContext context;

  OneDriveProvider._create({
    required this.clientId,
    required this.redirectUri,
    required this.context,
  });

  static Future<OneDriveProvider?> connect({
    required String clientId,
    required String redirectUri,
    required BuildContext context,
  }) async {
    if (clientId.trim().isEmpty) {
      throw ArgumentError(
          'App registration required: https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade');
    }
    if (redirectUri.isEmpty) {
      redirectUri =
      'https://login.microsoftonline.com/common/oauth2/nativeclient'; //fallback: use native redirect
    }

    final provider = OneDriveProvider._create(
        clientId: clientId, redirectUri: redirectUri, context: context);

    provider.client = OneDrive(
      clientID: clientId,
      redirectURL: redirectUri,
    );

    // 1. First, try to connect silently by checking for an existing token
    final bool alreadyConnected = await provider.client.isConnected();

    if (alreadyConnected) {
      provider._isAuthenticated = true;
      logger.i("OneDriveProvider: Silently connected successfully.");
      return provider;
    }

    // 2. If not connected, proceed with the interactive login
    logger.i("OneDriveProvider: Not connected, attempting interactive login...");
    final success = await provider.client.connect(context);

    if (success == false) {
      logger.i("OneDriveProvider: Interactive login failed or was cancelled.");
      return null; // User cancelled or login failed
    }

    provider._isAuthenticated = true;
    logger.i("OneDriveProvider: Interactive login successful.");
    return provider;
  }





  void _checkAuth() {
    if (!_isAuthenticated) {
      throw Exception(
          'OneDriveProvider: Not authenticated. Call connect() first.');
    }
  }

  Future<T> _executeRequest<T>(
      Future<T> Function() request, {
        required String operation,
      }) async {
    _checkAuth();
    try {
      logger.d('Executing OneDrive operation: $operation');
      return await request();
    } catch (e, stackTrace) {
      logger.e(
        'Error during OneDrive operation: $operation',
        error: e,
        stackTrace: stackTrace,
      );
      // Check for authentication-related errors
      if (e.toString().contains('401') || e.toString().contains('invalid_grant')) {
        _isAuthenticated = false;
        logger.w('OneDrive token appears to be expired. User re-authentication is required.');
      }
      rethrow;
    }
  }

  @override
  Future<String> uploadFile({
    required String localPath,
    required String remotePath,
    Map<String, dynamic>? metadata,
  }) {
    return _executeRequest(
          () async {
        final file = File(localPath);
        final bytes = await file.readAsBytes();
        await client.push(bytes, remotePath,
            isAppFolder:
            MultiCloudStorage.cloudAccess == CloudAccessType.appStorage);
        return remotePath;
      },
      operation: 'uploadFile to $remotePath',
    );
  }

  @override
  Future<String> downloadFile({
    required String remotePath,
    required String localPath,
  }) {
    return _executeRequest(
          () async {
        final response = await client.pull(remotePath,
            isAppFolder:
            MultiCloudStorage.cloudAccess == CloudAccessType.appStorage);
        final file = File(localPath);
        await file.writeAsBytes(response.bodyBytes!);
        return localPath;
      },
      operation: 'downloadFile from $remotePath',
    );
  }

  @override
  Future<List<CloudFile>> listFiles({
    String path = '',
    bool recursive = false,
  }) {
    return _executeRequest(
          () async {
        final files = await client.listFiles(path,
            recursive: recursive,
            isAppFolder:
            MultiCloudStorage.cloudAccess == CloudAccessType.appStorage);
        return files
            .map((oneDriveFile) => CloudFile(
            path: oneDriveFile.path,
            name: oneDriveFile.name,
            size: oneDriveFile.size,
            modifiedTime: DateTime.now(), // OneDrive SDK doesn't provide this
            isDirectory: oneDriveFile.isFolder))
            .toList();
      },
      operation: 'listFiles at $path',
    );
  }

  @override
  Future<void> deleteFile(String path) {
    return _executeRequest(
          () => client.deleteFile(path,
          isAppFolder:
          MultiCloudStorage.cloudAccess == CloudAccessType.appStorage),
      operation: 'deleteFile at $path',
    );
  }

  @override
  Future<void> createDirectory(String path) {
    return _executeRequest(
          () => client.createDirectory(path,
          isAppFolder:
          MultiCloudStorage.cloudAccess == CloudAccessType.appStorage),
      operation: 'createDirectory at $path',
    );
  }

  @override
  Future<CloudFile> getFileMetadata(String path) {
    return _executeRequest(
          () async {
        // The package doesn't provide a direct get metadata method.
        // This is a placeholder for a potential future implementation.
        throw UnimplementedError('Get metadata functionality not implemented');
      },
      operation: 'getFileMetadata for $path',
    );
  }

  @override
  Future<Uri?> generateSharableLink(String path) {
    return _executeRequest(
          () async {
        final accessToken = await DefaultTokenManager(
          tokenEndpoint: OneDrive.tokenEndpoint,
          clientID: client.clientID,
          redirectURL: client.redirectURL,
          scope: client.scopes,
        ).getAccessToken();
        if (accessToken == null || accessToken.isEmpty) {
          logger.w("OneDriveProvider: No access token available for generating share link.");
          return null;
        }

        final encodedPath = Uri.encodeComponent(path.startsWith('/') ? path.substring(1) : path);
        final driveItemPath = "/me/drive/root:/$encodedPath:/createLink";

        final response = await http.post(
          Uri.parse("https://graph.microsoft.com/v1.0$driveItemPath"),
          headers: {
            'Authorization': 'Bearer $accessToken',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            "type": "view", // or "edit"
            "scope": "anonymous"
          }),
        );

        if (response.statusCode != 200 && response.statusCode != 201) {
          logger.e("Failed to create shareable link. Status: ${response.statusCode}, Body: ${response.body}");
          return null;
        }

        final json = jsonDecode(response.body);
        final link = json['link']?['webUrl'];
        if (link == null) {
          logger.w("No shareable link was returned in the API response.");
          return null;
        }
        return Uri.parse(link);
      },
      operation: 'generateSharableLink for $path',
    );
  }

  @override
  Future<bool> logout() async {
    logger.i("Logging out from OneDrive...");
    if (_isAuthenticated) {
      try {
        await client.disconnect();
        _isAuthenticated = false;
        logger.i("OneDrive logout successful.");
        return true;
      } catch (error, stackTrace) {
        logger.e("Error during OneDrive logout.", error: error, stackTrace: stackTrace);
        return false;
      }
    }
    logger.d("Already logged out from OneDrive.");
    return false;
  }

  @override
  Future<bool> tokenExpired() async {
    if (!_isAuthenticated) return true;
    try {
      // Perform a lightweight, authenticated call to check token validity
      await _executeRequest(
            () => client.listFiles('/',
          isAppFolder: MultiCloudStorage.cloudAccess == CloudAccessType.appStorage,
        ),
        operation: 'tokenExpiredCheck',
      );
      return false; // Success means token is not expired
    } catch (e) {
      // _executeRequest already logged the error.
      // If it was a 401 error, _isAuthenticated is now false.
      // Any exception here implies the token is not valid.
      return true;
    }
  }

  @override
  Future<String> getSharedFileById({
    required String fileId,
    required String localPath,
    String? subPath,
  }) {
    return _executeRequest(
          () async {
        final accessToken = await DefaultTokenManager(
          tokenEndpoint: OneDrive.tokenEndpoint,
          clientID: client.clientID,
          redirectURL: client.redirectURL,
          scope: client.scopes,
        ).getAccessToken();

        if (accessToken == null || accessToken.isEmpty) {
          throw Exception('Access token is null or empty');
        }

        final response = await http.get(
          Uri.parse('https://graph.microsoft.com/v1.0/me/drive/items/$fileId/content'),
          headers: {'Authorization': 'Bearer $accessToken'},
        );

        if (response.statusCode != 200) {
          throw Exception('Failed to download file by item ID: ${response.statusCode}, ${response.body}');
        }

        final file = File(localPath);
        await file.writeAsBytes(response.bodyBytes);
        return localPath;
      },
      operation: 'getSharedFileById: $fileId',
    );
  }

  @override
  Future<String> uploadFileById({
    required String localPath,
    required String fileId,
    String? subPath,
    Map<String, dynamic>? metadata,
  }) {
    return _executeRequest(
          () async {
        final accessToken = await DefaultTokenManager(
          tokenEndpoint: OneDrive.tokenEndpoint,
          clientID: client.clientID,
          redirectURL: client.redirectURL,
          scope: client.scopes,
        ).getAccessToken();

        if (accessToken == null || accessToken.isEmpty) {
          throw Exception('Access token is null or empty');
        }

        final fileBytes = await File(localPath).readAsBytes();

        final response = await http.put(
          Uri.parse('https://graph.microsoft.com/v1.0/me/drive/items/$fileId/content'),
          headers: {
            'Authorization': 'Bearer $accessToken',
            'Content-Type': 'application/octet-stream',
          },
          body: fileBytes,
        );

        if (response.statusCode >= 200 && response.statusCode < 300) {
          return fileId;
        } else {
          throw Exception('Failed to upload file by ID: ${response.statusCode}, ${response.body}');
        }
      },
      operation: 'uploadFileById: $fileId',
    );
  }

  @override
  Future<String?> extractFileIdFromSharableLink(Uri shareLink) {
    return _executeRequest(
          () async {
        final accessToken = await DefaultTokenManager(
          tokenEndpoint: OneDrive.tokenEndpoint,
          clientID: client.clientID,
          redirectURL: client.redirectURL,
          scope: client.scopes,
        ).getAccessToken();
        final encoded = encodeShareUrl(shareLink);

        final response = await http.get(
          Uri.parse('https://graph.microsoft.com/v1.0/shares/u!$encoded/driveItem'),
          headers: {'Authorization': 'Bearer $accessToken'},
        );

        if (response.statusCode == 200) {
          final json = jsonDecode(response.body);
          return json['id']; // actual OneDrive item ID
        } else {
          throw Exception('Failed to resolve item ID from link: ${response.statusCode}, ${response.body}');
        }
      },
      operation: 'extractFileIdFromSharableLink',
    );
  }

  String encodeShareUrl(Uri url) {
    final bytes = utf8.encode(url.toString());
    final base64Str = base64UrlEncode(bytes);
    return base64Str.replaceAll('=', '');
  }

  @override
  Future<String?> loggedInUserDisplayName() {
    return _executeRequest(
          () async {
        final accessToken = await DefaultTokenManager(
          tokenEndpoint: OneDrive.tokenEndpoint,
          clientID: client.clientID,
          redirectURL: client.redirectURL,
          scope: client.scopes,
        ).getAccessToken();

        if (accessToken == null || accessToken.isEmpty) return null;

        final response = await http.get(
          Uri.parse('https://graph.microsoft.com/v1.0/me'),
          headers: {'Authorization': 'Bearer $accessToken'},
        );

        if (response.statusCode != 200) return null;

        final json = jsonDecode(response.body);
        return json['displayName'] as String?;
      },
      operation: 'loggedInUserDisplayName',
    );
  }
}