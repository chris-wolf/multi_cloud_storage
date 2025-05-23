import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_onedrive/flutter_onedrive.dart';
import 'package:flutter_onedrive/token.dart';
import 'cloud_storage_provider.dart';
import 'multi_cloud_storage.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

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
    if (clientId.trim().isEmpty && redirectUri.trim().isEmpty) {
      throw ArgumentError(
          'App registration required: https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade');
    }
    final provider = OneDriveProvider._create(
        clientId: clientId, redirectUri: redirectUri, context: context);
    provider.client = OneDrive(
      clientID: clientId,
      redirectURL: redirectUri,
    );
    final success = await provider.client.connect(context);
    if (success == false) {
      return null;
    }
    provider._isAuthenticated = true;
    return provider;
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
    final bytes = await file.readAsBytes();
    await client.push(bytes, remotePath,
        isAppFolder:
            MultiCloudStorage.cloudAccess == CloudAccessType.appStorage);
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

    final response = await client.pull(remotePath,
        isAppFolder:
            MultiCloudStorage.cloudAccess == CloudAccessType.appStorage);
    final file = File(localPath);
    await file.writeAsBytes(response.bodyBytes!);

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
    return (await client.listFiles(path,
            recursive: recursive,
            isAppFolder:
                MultiCloudStorage.cloudAccess == CloudAccessType.appStorage))
        .map((dropboxFile) => CloudFile(
            path: dropboxFile.path,
            name: dropboxFile.name,
            size: dropboxFile.size,
            modifiedTime: DateTime.fromMillisecondsSinceEpoch(0),
            isDirectory: dropboxFile.isFolder))
        .toList();
  }

  @override
  Future<void> deleteFile(String path) async {
    await client.deleteFile(path,
        isAppFolder:
            MultiCloudStorage.cloudAccess == CloudAccessType.appStorage);
  }

  @override
  Future<void> createDirectory(String path) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    await client.createDirectory(path,
        isAppFolder:
            MultiCloudStorage.cloudAccess == CloudAccessType.appStorage);
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

  @override
  Future<Uri?> generateSharableLinkWithMetadata(String path) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    final accessToken = await DefaultTokenManager(
      tokenEndpoint: OneDrive.tokenEndpoint,
      clientID: client.clientID,
      redirectURL: client.redirectURL,
      scope: client.scopes,
    ).getAccessToken(); //accesToken is private so need to access it like this
    if (accessToken == null || accessToken.isEmpty) {
      print("OneDriveProvider: No access token available.");
      return null;
    }

    final encodedPath = Uri.encodeComponent(path.startsWith('/') ? path.substring(1) : path);
    final driveItemPath = "/me/drive/root:/$encodedPath:/createLink";

    try {
      final response = await http.post(
        Uri.parse("https://graph.microsoft.com/v1.0$driveItemPath"),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          "type": "view", // or "edit" if you want an editable link
          "scope": "anonymous"
        }),
      );

      if (response.statusCode != 200) {
        print("OneDriveProvider: Failed to create shareable link: ${response.body}");
        return null;
      }

      final json = jsonDecode(response.body);
      final link = json['link']?['webUrl'];
      if (link == null) {
        print("OneDriveProvider: No shareable link returned.");
        return null;
      }

      // Append original path metadata as a query parameter
      final shareableUri = Uri.parse(link).replace(
        queryParameters: {
          ...Uri.parse(link).queryParameters,
          'originalPath': path,
        },
      );

      return shareableUri;
    } catch (e) {
      print("OneDriveProvider: Error creating shareable link: $e");
      return null;
    }
  }

  @override
  Future<bool> logout() async {
    if (_isAuthenticated) {
      await client.disconnect();
      _isAuthenticated = false;
      return true;
    }
    return false;
  }

  @override
  Future<bool> tokenExpired() async {
    if (!_isAuthenticated) return true;
    try {
      // Try a simple API call to check if token is valid
      await client.listFiles('/');
      return false;
    } catch (e) {
      return e.toString().contains('401') ||  e.toString().contains('403');
    }
  }
}
