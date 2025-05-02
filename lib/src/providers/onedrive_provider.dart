import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_onedrive/flutter_onedrive.dart';
import 'package:path/path.dart' as path;
import 'cloud_storage_provider.dart';

class OneDriveProvider implements CloudStorageProvider {
  late OneDrive _client;
  bool _isAuthenticated = false;
  final String _clientId;
  final String _clientSecret;
  final String _redirectUri;
  final BuildContext _context;

  OneDriveProvider({
    required String clientId,
    required String clientSecret,
    required String redirectUri,
    required BuildContext context,
  })  : _clientId = clientId,
        _clientSecret = clientSecret,
        _redirectUri = redirectUri,
        _context = context;

  @override
  Future<void> authenticate() async {
    _client = OneDrive(
      clientID: _clientId,
      redirectURL: _redirectUri,
    );

    await _client.connect(_context);
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
    final bytes = await file.readAsBytes();
    await _client.push(bytes, remotePath);

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

    final response = await _client.pull(remotePath);
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

    // Note: The package doesn't provide a direct list files method
    // We'll need to implement this using the API directly
    throw UnimplementedError('List files functionality not implemented');
  }

  @override
  Future<void> deleteFile(String path) async {
    if (!_isAuthenticated) {
      throw Exception('Not authenticated');
    }

    // Note: The package doesn't provide a direct delete method
    // We'll need to implement this using the API directly
    throw UnimplementedError('Delete functionality not implemented');
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
