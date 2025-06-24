import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';

import 'cloud_storage_provider.dart';

// =========================================================================
// 1. DATA MODELS (DropboxToken, DropboxAccount, etc.)
// =========================================================================

/// Represents the OAuth2 token returned by Dropbox.
class DropboxToken {
  final String accessToken;
  final String tokenType;
  final String? refreshToken;
  final DateTime expiresIn;

  DropboxToken({
    required this.accessToken,
    this.refreshToken,
    required this.tokenType,
    required this.expiresIn,
  });

  factory DropboxToken.fromJson(Map<String, dynamic> json) {
    final dynamic expiresInValue = json['expires_in'];
    DateTime expires;
    if (expiresInValue is int) {
      expires = DateTime.now().add(Duration(seconds: expiresInValue));
    } else if (expiresInValue is String) {
      // Handles the case where the expiration is already an ISO 8601 string from storage
      expires = DateTime.parse(expiresInValue);
    } else {
      throw Exception("Invalid 'expires_in' format");
    }

    return DropboxToken(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String?,
      tokenType: json['token_type'] as String,
      expiresIn: expires,
    );
  }

  Map<String, dynamic> toJson() => {
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'token_type': tokenType,
    'expires_in': expiresIn.toIso8601String(),
  };

  bool get isExpired =>
      DateTime.now().isAfter(expiresIn.subtract(const Duration(minutes: 5)));
}

/// Represents a Dropbox user account.
class DropboxAccount {
  final String accountId;
  final String displayName;
  final String email;

  DropboxAccount({
    required this.accountId,
    required this.displayName,
    required this.email,
  });

  factory DropboxAccount.fromJson(Map<String, dynamic> json) {
    return DropboxAccount(
      accountId: json['account_id'] as String,
      email: json['email'] as String,
      displayName:
      (json['name'] as Map<String, dynamic>)['display_name'] as String,
    );
  }
}

// =========================================================================
// 2. SELF-CONTAINED DROPBOX PROVIDER
// =========================================================================

class DropboxProvider extends CloudStorageProvider {
  final String _appKey;
  final String _appSecret;
  final String _redirectUri;

  // Secure storage is now integrated directly into the class.
  final _secureStorage = const FlutterSecureStorage();
  static const _kDropboxTokenKey = 'dropbox_token';

  late Dio _dio;
  DropboxToken? _token;
  DropboxAccount? _account;
  String? _pkceCodeVerifier;

  bool _isAuthenticated = false;

  /// Private constructor. Use `DropboxProvider.connect()` to instantiate.
  DropboxProvider._create({
    required String appKey,
    required String appSecret,
    required String redirectUri,
  })  : _appKey = appKey,
        _appSecret = appSecret,
        _redirectUri = redirectUri {
    _initializeDio();
  }

  /// The primary method to get a connected DropboxProvider instance.
  /// It now handles token storage internally.
  static Future<DropboxProvider?> connect({
    required String appKey,
    required String appSecret,
    required String redirectUri,
  }) async {
    if (appKey.isEmpty || appSecret.isEmpty) {
      throw ArgumentError(
          'App registration required: https://www.dropbox.com/developers/apps');
    }
    if (redirectUri.isEmpty) {
      throw ArgumentError(
          "redirectUri is empty. Please ensure your redirect URI is correctly configured as per the package documentation.");
    }
    final provider = DropboxProvider._create(
      appKey: appKey,
      appSecret: appSecret,
      redirectUri: redirectUri,
    );

    // Attempt to load token from secure storage
    DropboxToken? storedToken = await provider._getToken();
    if (storedToken != null) {
      provider._token = storedToken;
      try {
        if (provider._token!.isExpired) {
          debugPrint(
              "DropboxProvider: Stored token is expired, attempting refresh...");
          await provider._refreshToken();
          await provider._saveToken(provider._token); // Save the refreshed token
        }
        await provider._fetchCurrentUserAccount();
        provider._isAuthenticated = true;
        debugPrint(
            "DropboxProvider: Silent sign-in successful for ${provider._account?.email}");
        return provider;
      } catch (e) {
        debugPrint(
            "DropboxProvider: Silent sign-in failed ($e). Clearing token and proceeding to interactive login.");
        await provider._clearToken();
        provider._token = null;
        // CHANGE 2: Explicitly reset auth flag on failure to ensure clean state.
        provider._isAuthenticated = false;
      }
    }

    debugPrint(
        "DropboxProvider: No valid token found. Starting interactive login.");
    try {
      final authCode = await provider._getAuthCodeViaInteractiveFlow();

      if (authCode == null) {
        debugPrint("DropboxProvider: Interactive login cancelled by user.");
        return null; // User cancelled the flow
      }

      await provider._completeConnection(authCode);
      await provider._saveToken(provider._token); // Save the new token

      debugPrint(
          "DropboxProvider: Interactive login successful for ${provider._account?.email}");
      return provider;
    } catch (e) {
      debugPrint("DropboxProvider: Interactive login failed. Error: $e");
      await provider._clearToken();
      return null;
    }
  }

  //<editor-fold desc="Internal Token Management">

  /// Saves the Dropbox token securely.
  Future<void> _saveToken(DropboxToken? token) async {
    if (token == null) {
      await _clearToken();
      return;
    }
    final tokenJson = jsonEncode(token.toJson());
    await _secureStorage.write(key: _kDropboxTokenKey, value: tokenJson);
  }

  /// Retrieves the Dropbox token from secure storage.
  Future<DropboxToken?> _getToken() async {
    final tokenJson = await _secureStorage.read(key: _kDropboxTokenKey);
    if (tokenJson == null || tokenJson.isEmpty) {
      return null;
    }
    try {
      return DropboxToken.fromJson(jsonDecode(tokenJson));
    } catch (e) {
      debugPrint("Error decoding stored token, clearing it: $e");
      await _clearToken();
      return null;
    }
  }

  /// Deletes the Dropbox token from secure storage.
  Future<void> _clearToken() async {
    await _secureStorage.delete(key: _kDropboxTokenKey);
  }

  //</editor-fold>

  //<editor-fold desc="Authentication Internals">

  void _initializeDio() {
    _dio = Dio();
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (_token != null) {
          options.headers['Authorization'] = 'Bearer ${_token!.accessToken}';
        }
        return handler.next(options);
      },
      onError: (e, handler) async {
        if (e.response?.statusCode == 401 && _token?.refreshToken != null) {
          try {
            await _refreshToken();
            await _saveToken(_token); // Persist the new token after refresh
            // Retry the original request with the new token
            final response = await _dio.request(
              e.requestOptions.path,
              options: Options(
                  method: e.requestOptions.method,
                  headers: e.requestOptions.headers),
              data: e.requestOptions.data,
              queryParameters: e.requestOptions.queryParameters,
            );
            return handler.resolve(response);
          } catch (refreshError) {
            debugPrint(
                "Dropbox token refresh failed, logging out: $refreshError");
            await logout(); // Logout will clear tokens and state
            return handler.reject(e); // Propagate the original error
          }
        }
        return handler.next(e);
      },
    ));
  }

  Future<String?> _getAuthCodeViaInteractiveFlow() async {
    final authUrl = _getAuthorizationUrl();
    final uri = Uri.parse(authUrl);
    StreamSubscription? linkSub;
    final codeCompleter = Completer<String?>();
    final appLinks = AppLinks();

    // Listen for the redirect
    linkSub = appLinks.uriLinkStream.listen((Uri? link) {
      if (link != null && link.toString().startsWith(_redirectUri)) {
        // Stop listening to prevent multiple triggers
        linkSub?.cancel();
        final code = link.queryParameters['code'];
        if (code != null) {
          if (!codeCompleter.isCompleted) codeCompleter.complete(code);
        } else {
          debugPrint(
              "Dropbox auth error from redirect: ${link.queryParameters['error']}");
          if (!codeCompleter.isCompleted) codeCompleter.complete(null);
        }
      }
    }, onError: (err) {
      debugPrint("Error listening to deep links: $err");
      if (!codeCompleter.isCompleted) {
        codeCompleter.complete(null);
      }
    });

    // Launch the URL for user authorization
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, webViewConfiguration: const WebViewConfiguration());
    } else {
      linkSub.cancel();
      codeCompleter.completeError('Could not launch $authUrl');
    }
    return codeCompleter.future;
  }

  String _getAuthorizationUrl() {
    _pkceCodeVerifier = _generateCodeVerifier();
    final queryParams = {
      'client_id': _appKey,
      'response_type': 'code',
      'redirect_uri': _redirectUri,
      'token_access_type': 'offline',
      'code_challenge_method': 'S256',
      'code_challenge': _generateCodeChallengeS256(_pkceCodeVerifier!),
    };
    final uri = Uri.https('www.dropbox.com', '/oauth2/authorize', queryParams);
    return uri.toString();
  }

  Future<void> _completeConnection(String code) async {
    if (_pkceCodeVerifier == null) throw Exception("Auth flow not initiated.");

    final dioForToken = Dio(); // Use a separate Dio instance for token exchange
    final response = await dioForToken.post(
      'https://api.dropboxapi.com/oauth2/token',
      data: {
        'grant_type': 'authorization_code',
        'code': code,
        'client_id': _appKey,
        'client_secret': _appSecret,
        'redirect_uri': _redirectUri,
        'code_verifier': _pkceCodeVerifier,
      },
      options: Options(contentType: 'application/x-www-form-urlencoded'),
    );

    _token = DropboxToken.fromJson(response.data);
    _isAuthenticated = true;
    _pkceCodeVerifier = null; // Clear verifier after use
    await _fetchCurrentUserAccount();
  }

  Future<void> _refreshToken() async {
    if (_token?.refreshToken == null) {
      throw Exception("No refresh token available.");
    }

    final dioForToken = Dio();
    final response = await dioForToken.post(
      'https://api.dropboxapi.com/oauth2/token',
      data: {
        'grant_type': 'refresh_token',
        'refresh_token': _token!.refreshToken,
        'client_id': _appKey,
        'client_secret': _appSecret,
      },
      options: Options(contentType: 'application/x-www-form-urlencoded'),
    );
    final newPartialToken = DropboxToken.fromJson(response.data);
    // Important: Preserve the original refresh token as Dropbox might not send a new one
    _token = DropboxToken(
      accessToken: newPartialToken.accessToken,
      tokenType: newPartialToken.tokenType,
      expiresIn: newPartialToken.expiresIn,
      refreshToken: _token!.refreshToken,
    );
  }

  Future<void> _fetchCurrentUserAccount() async {
    // CHANGE 1: The _checkAuth() call is removed from here.
    // It was causing the silent sign-in to fail because _isAuthenticated
    // isn't true until *after* this method and the refresh logic succeed.
    // The Dio interceptor already ensures the request is authorized if a token exists.
    if (_token == null) {
      throw Exception(
          'DropboxProvider: Not authenticated. Cannot fetch user account.');
    }
    final response = await _dio
        .post('https://api.dropboxapi.com/2/users/get_current_account');
    _account = DropboxAccount.fromJson(response.data);
  }

  void _checkAuth() {
    if (!_isAuthenticated || _token == null) {
      throw Exception('DropboxProvider: Not authenticated.');
    }
  }
  //</editor-fold>

  //<editor-fold desc="Public API Methods">
  @override
  Future<String?> loggedInUserDisplayName() async => _account?.displayName;

  @override
  Future<bool> logout() async {
    if (_isAuthenticated && _token != null) {
      try {
        await _dio.post('https://api.dropboxapi.com/2/auth/token/revoke');
      } catch (e) {
        // Log the error but proceed with local logout regardless
        debugPrint(
            "Dropbox token revoke failed, but logging out locally anyway: $e");
      }
    }
    await _clearToken(); // Clear token from secure storage
    _token = null;
    _account = null;
    _isAuthenticated = false;
    return true;
  }

  @override
  Future<bool> tokenExpired() async => _token?.isExpired ?? true;

  @override
  Future<String> uploadFile(
      {required String localPath,
        required String remotePath,
        Map<String, dynamic>? metadata}) async {
    _checkAuth();
    final file = File(localPath);
    final fileStream = file.openRead();
    final fileSize = await file.length();

    final response = await _dio.post(
      'https://content.dropboxapi.com/2/files/upload',
      data: fileStream,
      options: Options(
        headers: {
          'Dropbox-API-Arg': jsonEncode({
            'path': _normalizePath(remotePath),
            'mode': 'add', // or 'overwrite'
            'autorename': true,
          }),
          'Content-Type': 'application/octet-stream',
          'Content-Length': fileSize,
        },
      ),
    );
    return response.data['id'];
  }

  @override
  Future<String> downloadFile(
      {required String remotePath, required String localPath}) async {
    _checkAuth();
    final response = await _dio.post(
      'https://content.dropboxapi.com/2/files/download',
      options: Options(
        headers: {
          'Dropbox-API-Arg': jsonEncode({'path': _normalizePath(remotePath)})
        },
        responseType: ResponseType.stream,
      ),
    );

    final file = File(localPath);
    final sink = file.openWrite();

    // Efficiently write the stream to the file
    await sink.addStream(response.data.stream);
    await sink.close();

    return localPath;
  }

  @override
  Future<void> deleteFile(String path) async {
    _checkAuth();
    await _dio.post(
      'https://api.dropboxapi.com/2/files/delete_v2',
      data: jsonEncode({'path': _normalizePath(path)}),
      options: Options(contentType: 'application/json'),
    );
  }

  @override
  Future<void> createDirectory(String path) async {
    _checkAuth();
    try {
      await _dio.post(
        'https://api.dropboxapi.com/2/files/create_folder_v2',
        data: jsonEncode({'path': _normalizePath(path), 'autorename': false}),
        options: Options(contentType: 'application/json'),
      );
    } on DioException catch (e) {
      // Ignore error if the folder already exists.
      if (e.response?.data?['error_summary']?.contains('path/conflict/folder') == false) {
        rethrow;
      }
      debugPrint("Directory already exists, ignoring error.");
    }
  }

  @override
  Future<List<CloudFile>> listFiles(
      {required String path, bool recursive = false}) async {
    _checkAuth();
    final List<CloudFile> allFiles = [];
    String? cursor;
    bool hasMore = true;

    String initialPath = path == '/' ? '' : _normalizePath(path);

    while (hasMore) {
      Response response;
      if (cursor == null) {
        response = await _dio.post(
          'https://api.dropboxapi.com/2/files/list_folder',
          data: jsonEncode(
              {'path': initialPath, 'recursive': recursive, 'limit': 1000}),
          options: Options(contentType: 'application/json'),
        );
      } else {
        response = await _dio.post(
          'https://api.dropboxapi.com/2/files/list_folder/continue',
          data: jsonEncode({'cursor': cursor}),
          options: Options(contentType: 'application/json'),
        );
      }

      final entries = response.data['entries'] as List;
      allFiles.addAll(
          entries.map((e) => _mapToCloudFile(e as Map<String, dynamic>)));

      hasMore = response.data['has_more'] as bool;
      cursor = response.data['cursor'] as String?;
    }

    return allFiles;
  }

  @override
  Future<CloudFile> getFileMetadata(String path) async {
    _checkAuth();
    final response = await _dio.post(
      'https://api.dropboxapi.com/2/files/get_metadata',
      data: jsonEncode({'path': _normalizePath(path)}),
      options: Options(contentType: 'application/json'),
    );
    return _mapToCloudFile(response.data);
  }
  //</editor-fold>

  //<editor-fold desc="Helper Methods">
  CloudFile _mapToCloudFile(Map<String, dynamic> data) {
    final isDir = data['.tag'] == 'folder';
    return CloudFile(
      path: data['path_display'],
      name: data['name'],
      size: isDir ? null : data['size'],
      modifiedTime: isDir
          ? DateTime.now() // Folders don't have a specific modified time in list_folder
          : DateTime.parse(data['server_modified']),
      isDirectory: isDir,
      metadata: {'id': data['id'], if (!isDir) 'rev': data['rev']},
    );
  }

  String _normalizePath(String path) {
    if (path.isEmpty || path == '/') return '';
    return path.startsWith('/') ? path : '/$path';
  }

  String _generateCodeVerifier() {
    const charset =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final random = Random.secure();
    return List.generate(128, (_) => charset[random.nextInt(charset.length)])
        .join();
  }

  String _generateCodeChallengeS256(String verifier) {
    final bytes = utf8.encode(verifier);
    final digest = sha256.convert(bytes);
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }
  //</editor-fold>

  //<editor-fold desc="Collaboration & Sharing Implementation">

  // NOTE: This implementation assumes a collaborative sync file will always
  // be named 'sync_file.json' inside the shared folder.

  /// Generates a sharable link for a FOLDER that allows other users to edit its contents.
  @override
  Future<Uri?> generateSharableLink(String path) async {
    _checkAuth();
    final normalizedPath = _normalizePath(path);

    try {
      await _dio.post(
        'https://api.dropboxapi.com/2/sharing/share_folder',
        data: jsonEncode({
          'path': normalizedPath,
          'acl_update_policy': 'owner',
          'shared_link_policy': 'anyone'
        }),
        options: Options(contentType: 'application/json'),
      );
    } on DioException catch (e) {
      if (e.response?.data?['error_summary']?.contains('bad_path/already_shared') == false) {
        rethrow;
      }
      debugPrint("Folder is already shared, proceeding...");
    }

    try {
      final response = await _dio.post(
        'https://api.dropboxapi.com/2/sharing/create_shared_link_with_settings',
        data: jsonEncode({
          'path': normalizedPath,
          'settings': {
            'requested_visibility': 'public',
            'access': 'editor',
          }
        }),
        options: Options(contentType: 'application/json'),
      );
      return Uri.parse(response.data['url']);
    } on DioException catch (e) {
      final errorData = e.response?.data;
      if (errorData is Map && errorData['error_summary'].toString().contains('shared_link_already_exists')) {
        final listResponse = await _dio.post(
          'https://api.dropboxapi.com/2/sharing/list_shared_links',
          data: jsonEncode({'path': normalizedPath, 'direct_only': true}),
          options: Options(contentType: 'application/json'),
        );
        if ((listResponse.data['links'] as List).isNotEmpty) {
          return Uri.parse(listResponse.data['links'][0]['url']);
        }
      }
      debugPrint("Failed to create or retrieve shared link: $e");
      rethrow;
    }
  }

  @override
  Future<String?> extractFileIdFromSharableLink(Uri shareLink) async {
    if (shareLink.host.contains('dropbox.com') && shareLink.path.contains('/scl/fo/')) {
      return shareLink.toString();
    }
    debugPrint("Link is not a valid Dropbox shared folder link: $shareLink");
    return null;
  }

  @override
  Future<String> uploadFileById({required String localPath, required String fileId, Map<String, dynamic>? metadata}) async {
    _checkAuth();

    var folderInfo = await _findOrJoinSharedFolder(fileId);
    final remoteFilePath = "${folderInfo['path_lower']}/sync_file.json";

    debugPrint("Uploading to resolved remote path: $remoteFilePath");
    return uploadFile(localPath: localPath, remotePath: remoteFilePath, metadata: metadata);
  }

  @override
  Future<String> getSharedFileById({required String fileId, required String localPath}) async {
    _checkAuth();

    var folderInfo = await _findOrJoinSharedFolder(fileId);
    final remoteFilePath = "${folderInfo['path_lower']}/sync_file.json";

    debugPrint("Downloading from resolved remote path: $remoteFilePath");
    return downloadFile(remotePath: remoteFilePath, localPath: localPath);
  }

  /// Centralized helper to find a mounted folder or join it if not found.
  Future<Map<String, String>> _findOrJoinSharedFolder(String sharedLinkUrl) async {
    var folderInfo = await _findMountedFolderInfo(sharedLinkUrl);

    if (folderInfo == null) {
      debugPrint("Shared folder not found in user's Dropbox. Attempting to join...");
      try {
        folderInfo = await joinSharedFolder(sharedLinkUrl: sharedLinkUrl);
      } catch (e) {
        debugPrint("Failed to automatically join shared folder: $e");
        throw Exception("Shared folder could not be found or joined. Please ensure the link is valid and you have permission.");
      }
    }
    return folderInfo;
  }

  Future<Map<String, String>?> _findMountedFolderInfo(String sharedLinkUrl) async {
    _checkAuth();

    String targetSharedFolderId;
    try {
      final metaResponse = await _dio.post(
        'https://api.dropboxapi.com/2/sharing/get_shared_link_metadata',
        data: jsonEncode({'url': sharedLinkUrl}),
        options: Options(contentType: 'application/json'),
      );
      targetSharedFolderId = metaResponse.data['id'].toString().replaceFirst('id:', '');
    } catch (e) {
      debugPrint("Could not get metadata from shared link: $e");
      return null;
    }

    String? cursor;
    bool hasMore = true;
    while (hasMore) {
      Response response = cursor == null
          ? await _dio.post(
        'https://api.dropboxapi.com/2/files/list_folder',
        data: jsonEncode({'path': '', 'recursive': true, 'include_shared_folders': true}),
        options: Options(contentType: 'application/json'),
      )
          : await _dio.post(
        'https://api.dropboxapi.com/2/files/list_folder/continue',
        data: jsonEncode({'cursor': cursor}),
        options: Options(contentType: 'application/json'),
      );

      for (final entry in (response.data['entries'] as List)) {
        if (entry['.tag'] == 'folder' && entry['sharing_info']?['shared_folder_id'] == targetSharedFolderId) {
          return {'path_lower': entry['path_lower'], 'name': entry['name']};
        }
      }
      hasMore = response.data['has_more'] as bool;
      cursor = response.data['cursor'] as String?;
    }
    return null;
  }

  Future<Map<String, String>> joinSharedFolder({required String sharedLinkUrl}) async {
    _checkAuth();

    String targetSharedFolderId;
    try {
      final metaResponse = await _dio.post(
        'https://api.dropboxapi.com/2/sharing/get_shared_link_metadata',
        data: jsonEncode({'url': sharedLinkUrl}),
        options: Options(contentType: 'application/json'),
      );
      targetSharedFolderId = metaResponse.data['id'].toString().replaceFirst('id:', '');
    } catch (e) {
      debugPrint("Could not get metadata from shared link: $e");
      throw Exception("Invalid shared link or insufficient permissions to view it.");
    }

    try {
      debugPrint("Attempting to mount folder with ID: $targetSharedFolderId");
      final mountResponse = await _dio.post(
        'https://api.dropboxapi.com/2/sharing/mount_folder',
        data: jsonEncode({'shared_folder_id': targetSharedFolderId}),
        options: Options(contentType: 'application/json'),
      );

      debugPrint("Successfully mounted folder: ${mountResponse.data['name']}");
      return {'path_lower': mountResponse.data['path_lower'], 'name': mountResponse.data['name']};
    } on DioException catch (e) {
      final error = e.response?.data?['error'];
      if (error != null && error['.tag'] == 'already_mounted') {
        debugPrint("Folder is already mounted. Locating it...");
        final folderInfo = await _findMountedFolderInfo(sharedLinkUrl);
        if (folderInfo == null) {
          throw Exception("Could not locate the folder in Dropbox, even though it is reportedly mounted.");
        }
        return folderInfo;
      }
      debugPrint("Error mounting folder: $e");
      throw Exception("Could not mount the shared folder. The user may not have permission or another API error occurred.");
    }
  }
}
