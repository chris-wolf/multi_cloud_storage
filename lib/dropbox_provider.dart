import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../main.dart'; // Assuming your global logger is accessible via main.dart
import 'cloud_storage_provider.dart';
import 'file_log_output.dart';

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
// 3. SELF-CONTAINED DROPBOX PROVIDER
// =========================================================================

class DropboxProvider extends CloudStorageProvider {
  final String _appKey;
  final String _appSecret;
  final String _redirectUri;

  final _secureStorage = const FlutterSecureStorage();
  static const _kDropboxTokenKey = 'dropbox_token';

  late Dio _dio;
  DropboxToken? _token;
  DropboxAccount? _account;
  String? _pkceCodeVerifier;

  bool _isAuthenticated = false;

  DropboxProvider._create({
    required String appKey,
    required String appSecret,
    required String redirectUri,
  })
      : _appKey = appKey,
        _appSecret = appSecret,
        _redirectUri = redirectUri {
    _initializeDio();
  }

  static Future<DropboxProvider?> connect({
    required String appKey,
    required String appSecret,
    required String redirectUri,
    bool forceInteractive = false,
  }) async {
    logger.i('connect Dropbox, forceInteractive: $forceInteractive');
    final connectivityResult = await (Connectivity().checkConnectivity());
    if (connectivityResult.contains(ConnectivityResult.none)) {
      logger.w('No internet connection. Cannot connect to Dropbox.');
      return null;
    }

    if (appKey.isEmpty || appSecret.isEmpty || redirectUri.isEmpty) {
      logger.e('Dropbox connection failed: App Key, Secret, or Redirect URI is missing.');
      return null;
    }

    final provider = DropboxProvider._create(
        appKey: appKey, appSecret: appSecret, redirectUri: redirectUri);

    if (forceInteractive) {
      logger.i('Forcing interactive login, clearing existing token.');
      await provider._clearToken();
    }

    try {
      DropboxToken? storedToken = await provider._getToken();
      if (storedToken != null) {
        provider._token = storedToken;
        if (provider._token!.isExpired) {
          logger.i('Stored Dropbox token is expired, attempting refresh.');
          await provider._refreshToken();
          await provider._saveToken(provider._token);
        }
        await provider._fetchCurrentUserAccount();
        provider._isAuthenticated = true;
        logger.i('Dropbox silent sign-in successful for ${provider._account?.email}');
        return provider;
      }

      logger.i('No valid token found. Starting interactive Dropbox login.');
      final authCode = await provider._getAuthCodeViaInteractiveFlow();
      if (authCode == null) {
        logger.i('Interactive Dropbox login cancelled by user.');
        return null;
      }

      await provider._completeConnection(authCode);
      await provider._saveToken(provider._token);
      logger.i('Interactive Dropbox login successful for ${provider._account?.email}');
      return provider;

    } catch (error, stackTrace) {
      logger.e(
        'Error occurred during the Dropbox connect process. Clearing credentials.',
        error: error,
        stackTrace: stackTrace,
      );
      await provider.logout();
      return null;
    }
  }

  // --- 🚀 NEW: Centralized Request Execution 🚀 ---
  Future<T> _executeRequest<T>(Future<T> Function() request) async {
    _checkAuth();
    try {
      return await request();
    } on DioException catch (e, stackTrace) {
      logger.e('A DioException occurred in Dropbox request', error: e, stackTrace: stackTrace);
      if (e.response?.statusCode == 401) {
        logger.w('Dropbox request failed with 401. Possible token invalidation.');
        // The interceptor handles automatic refresh. If it still fails,
        // it indicates a more serious issue (e.g., revoked access).
        await logout(); // Force logout to clear bad state
      }
      // Re-read and expose the API error message if available
      if (e.response?.data is Map) {
        final errorSummary = e.response?.data?['error_summary'];
        if (errorSummary != null) {
          throw Exception('Dropbox API Error: $errorSummary');
        }
      }
      rethrow;
    } catch (e, stackTrace) {
      logger.e('An unexpected error occurred in Dropbox request', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }


  @override
  Future<String?> loggedInUserDisplayName() async => _account?.displayName;

  @override
  Future<bool> logout() async {
    logger.i('Logging out from Dropbox.');
    if (_isAuthenticated && _token != null) {
      try {
        await _dio.post('https://api.dropboxapi.com/2/auth/token/revoke');
        logger.i('Successfully revoked Dropbox token via API.');
      } catch (e) {
        logger.w('Failed to revoke Dropbox token via API, but logging out locally anyway.', error: e);
      }
    }
    await _clearToken();
    _token = null;
    _account = null;
    _isAuthenticated = false;
    return true;
  }

  @override
  Future<String> uploadFile({required String localPath, required String remotePath, Map<String, dynamic>? metadata}) {
    return _executeRequest(() async {
      final file = File(localPath);
      final fileSize = await file.length();
      final normalizedPath = _normalizePath(remotePath);

      logger.d('Uploading $localPath to Dropbox at $normalizedPath');

      final response = await _dio.post(
        'https://content.dropboxapi.com/2/files/upload',
        data: file.openRead(),
        options: Options(
          headers: {
            'Dropbox-API-Arg': jsonEncode({
              'path': normalizedPath,
              'mode': 'overwrite',
              'autorename': false, // To behave like Google Drive overwrite
            }),
            'Content-Type': 'application/octet-stream',
            'Content-Length': fileSize,
          },
        ),
      );
      logger.i('Successfully uploaded file to Dropbox, ID: ${response.data['id']}');
      return response.data['id'];
    });
  }

  @override
  Future<String> downloadFile({required String remotePath, required String localPath}) {
    return _executeRequest(() async {
      final normalizedPath = _normalizePath(remotePath);
      logger.d('Downloading from Dropbox path: $normalizedPath to $localPath');

      final response = await _dio.post(
        'https://content.dropboxapi.com/2/files/download',
        options: Options(
          headers: {'Dropbox-API-Arg': jsonEncode({'path': normalizedPath})},
          responseType: ResponseType.stream,
        ),
      );

      final file = File(localPath);
      final sink = file.openWrite();

      // The stream from Dio's response body
      final Stream<Uint8List> stream = response.data.stream;

      // FIX: Cast the stream to the type required by the IOSink before piping.
      await stream.cast<List<int>>().pipe(sink);

      logger.i('Successfully downloaded file to $localPath');
      return localPath;
    });
  }

  @override
  Future<List<CloudFile>> listFiles({String path = '', bool recursive = false}) {
    return _executeRequest(() async {
      final List<CloudFile> allFiles = [];
      String? cursor;
      bool hasMore = true;
      String initialPath = path == '/' ? '' : _normalizePath(path);

      logger.d('Listing files in Dropbox path: "$initialPath", recursive: $recursive');

      while (hasMore) {
        Response response;
        if (cursor == null) {
          response = await _dio.post(
            'https://api.dropboxapi.com/2/files/list_folder',
            data: jsonEncode({'path': initialPath, 'recursive': recursive, 'limit': 1000}),
            options: Options(contentType: 'application/json'),
          );
        } else {
          logger.d('Fetching next page of files with cursor...');
          response = await _dio.post(
            'https://api.dropboxapi.com/2/files/list_folder/continue',
            data: jsonEncode({'cursor': cursor}),
            options: Options(contentType: 'application/json'),
          );
        }

        final entries = response.data['entries'] as List;
        allFiles.addAll(entries.map((e) => _mapToCloudFile(e as Map<String, dynamic>)));

        hasMore = response.data['has_more'] as bool;
        cursor = response.data['cursor'] as String?;
      }
      logger.i('Found ${allFiles.length} files/folders in "$initialPath".');
      return allFiles;
    });
  }

  @override
  Future<void> deleteFile(String path) {
    return _executeRequest(() async {
      final normalizedPath = _normalizePath(path);
      logger.d('Attempting to delete Dropbox path: $normalizedPath');
      try {
        await _dio.post(
          'https://api.dropboxapi.com/2/files/delete_v2',
          data: jsonEncode({'path': normalizedPath}),
          options: Options(contentType: 'application/json'),
        );
        logger.i('Successfully deleted path: $normalizedPath');
      } on DioException catch (e) {
        if (e.response?.data?['error_summary']?.contains('path_lookup/not_found') == true) {
          logger.w('Path not found during deletion, considering it a success: $normalizedPath');
        } else {
          rethrow;
        }
      }
    });
  }

  @override
  Future<void> createDirectory(String path) {
    return _executeRequest(() async {
      final normalizedPath = _normalizePath(path);
      logger.d('Creating Dropbox directory: $normalizedPath');
      try {
        await _dio.post(
          'https://api.dropboxapi.com/2/files/create_folder_v2',
          data: jsonEncode({'path': normalizedPath, 'autorename': false}),
          options: Options(contentType: 'application/json'),
        );
        logger.i('Successfully created directory: $normalizedPath');
      } on DioException catch (e) {
        if (e.response?.data?['error_summary']?.contains('path/conflict/folder') == true) {
          logger.w('Directory already exists, ignoring creation: $normalizedPath');
        } else {
          rethrow;
        }
      }
    });
  }

  @override
  Future<CloudFile> getFileMetadata(String path) {
    return _executeRequest(() async {
      final normalizedPath = _normalizePath(path);
      logger.d('Getting metadata for Dropbox path: $normalizedPath');
      final response = await _dio.post(
        'https://api.dropboxapi.com/2/files/get_metadata',
        data: jsonEncode({'path': normalizedPath}),
        options: Options(contentType: 'application/json'),
      );
      return _mapToCloudFile(response.data);
    });
  }

  //<editor-fold desc="Internal Methods">

  void _initializeDio() {
    _dio = Dio(BaseOptions(
        sendTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 30)));

    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (_token != null) {
          options.headers['Authorization'] = 'Bearer ${_token!.accessToken}';
        }
        return handler.next(options);
      },
      onError: (e, handler) async {
        if (e.response?.statusCode == 401 && _token?.refreshToken != null) {
          logger.w('Token expired (401). Attempting to refresh Dropbox token.');
          try {
            await _refreshToken();
            await _saveToken(_token);
            logger.i('Dropbox token refreshed successfully. Retrying original request.');

            final response = await _dio.request(
              e.requestOptions.path,
              options: Options(method: e.requestOptions.method, headers: e.requestOptions.headers),
              data: e.requestOptions.data,
              queryParameters: e.requestOptions.queryParameters,
            );
            return handler.resolve(response);
          } catch (refreshError, stackTrace) {
            logger.e('Failed to refresh Dropbox token. Logging out.', error: refreshError, stackTrace: stackTrace);
            await logout();
            return handler.reject(e);
          }
        }
        return handler.next(e);
      },
    ));
  }

  void _checkAuth() {
    if (!_isAuthenticated || _token == null) {
      throw Exception('DropboxProvider: Not authenticated. Call connect() first.');
    }
  }

  Future<void> _refreshToken() async {
    if (_token?.refreshToken == null) {
      throw Exception('No Dropbox refresh token available.');
    }
    logger.i('Executing Dropbox token refresh request.');
    final dioForToken = Dio(); // Use a separate Dio instance
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
    _token = DropboxToken(
      accessToken: newPartialToken.accessToken,
      tokenType: newPartialToken.tokenType,
      expiresIn: newPartialToken.expiresIn,
      refreshToken: _token!.refreshToken, // Preserve original refresh token
    );
    logger.i('New Dropbox access token obtained.');
  }

  Future<void> _fetchCurrentUserAccount() async {
    if (_token == null) throw Exception('Cannot fetch user account without a token.');
    logger.d('Fetching current Dropbox user account.');
    final response = await _dio.post('https://api.dropboxapi.com/2/users/get_current_account');
    _account = DropboxAccount.fromJson(response.data);
    logger.d('Successfully fetched user: ${_account?.email}');
  }

  Future<String?> _getAuthCodeViaInteractiveFlow() async {
    final authUrl = _getAuthorizationUrl();
    final uri = Uri.parse(authUrl);
    final codeCompleter = Completer<String?>();
    final appLinks = AppLinks();
    StreamSubscription? linkSub;

    linkSub = appLinks.uriLinkStream.listen((Uri? link) {
      if (link != null && link.toString().startsWith(_redirectUri)) {
        linkSub?.cancel();
        final code = link.queryParameters['code'];
        if (code != null) {
          logger.i('Received authorization code from redirect.');
          if (!codeCompleter.isCompleted) codeCompleter.complete(code);
        } else {
          final error = link.queryParameters['error_description'] ?? 'Unknown error';
          logger.e('Dropbox auth failed from redirect: $error');
          if (!codeCompleter.isCompleted) codeCompleter.complete(null);
        }
      }
    });

    logger.i('Launching Dropbox authorization URL: $authUrl');
    if (!await launchUrl(uri, webViewConfiguration: const WebViewConfiguration())) {
      linkSub.cancel();
      final errorMsg = 'Could not launch Dropbox auth URL';
      logger.e(errorMsg);
      if(!codeCompleter.isCompleted) codeCompleter.completeError(errorMsg);
    }

    return codeCompleter.future;
  }

  Future<void> _completeConnection(String code) async {
    if (_pkceCodeVerifier == null) throw Exception('PKCE code verifier is missing.');
    logger.d('Exchanging authorization code for a token.');
    final dioForToken = Dio();
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
    _pkceCodeVerifier = null;
    await _fetchCurrentUserAccount();
  }

  Future<void> _saveToken(DropboxToken? token) async {
    if (token == null) return _clearToken();
    final tokenJson = jsonEncode(token.toJson());
    await _secureStorage.write(key: _kDropboxTokenKey, value: tokenJson);
    logger.d('Dropbox token saved to secure storage.');
  }

  Future<DropboxToken?> _getToken() async {
    final tokenJson = await _secureStorage.read(key: _kDropboxTokenKey);
    if (tokenJson == null) {
      logger.i('No Dropbox token found in secure storage.');
      return null;
    }
    try {
      logger.d('Found and decoded Dropbox token from secure storage.');
      return DropboxToken.fromJson(jsonDecode(tokenJson));
    } catch (e) {
      logger.e('Error decoding stored Dropbox token, clearing it.', error: e);
      await _clearToken();
      return null;
    }
  }

  Future<void> _clearToken() async {
    await _secureStorage.delete(key: _kDropboxTokenKey);
    logger.i('Cleared Dropbox token from secure storage.');
  }

  String _normalizePath(String path) {
    if (path.isEmpty || path == '/') return '';
    return p.url.normalize(path.startsWith('/') ? path : '/$path');
  }

  CloudFile _mapToCloudFile(Map<String, dynamic> data) {
    final isDir = data['.tag'] == 'folder';
    return CloudFile(
      path: data['path_display'],
      name: data['name'],
      size: isDir ? null : data['size'],
      modifiedTime: isDir ? DateTime.now() : DateTime.parse(data['server_modified']),
      isDirectory: isDir,
      metadata: {'id': data['id'], if (!isDir) 'rev': data['rev']},
    );
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
      'scope': 'account_info.read files.content.read files.content.write sharing.write',
    };
    return Uri.https('www.dropbox.com', '/oauth2/authorize', queryParams).toString();
  }

  String _generateCodeVerifier() {
    const charset = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final random = Random.secure();
    return List.generate(128, (_) => charset[random.nextInt(charset.length)]).join();
  }

  String _generateCodeChallengeS256(String verifier) {
    return base64Url.encode(sha256.convert(utf8.encode(verifier)).bytes).replaceAll('=', '');
  }
  //</editor-fold>

  // --- Methods below are placeholders or require specific implementation details ---

  @override
  Future<bool> tokenExpired() async => _token?.isExpired ?? true;

  @override
  Future<Uri?> generateShareLink(String path) {
    return _executeRequest(() async {
      final normalizedPath = _normalizePath(path);
      logger.d('Generating sharable link for Dropbox path: $normalizedPath');
      try {
        final response = await _dio.post(
          'https://api.dropboxapi.com/2/sharing/create_shared_link_with_settings',
          data: jsonEncode({
            'path': normalizedPath,
            'settings': {'requested_visibility': 'public', 'access': 'editor'}
          }),
          options: Options(contentType: 'application/json'),
        );
        final url = response.data['url'];
        logger.i('Created sharable link: $url');
        return url == null ? null : Uri.parse(url);
      } on DioException catch (e) {
        if (e.response?.data?['error_summary']?.contains('shared_link_already_exists') == true) {
          logger.w('Share link already exists for $normalizedPath, fetching existing one.');
          final listResponse = await _dio.post(
            'https://api.dropboxapi.com/2/sharing/list_shared_links',
            data: jsonEncode({'path': normalizedPath, 'direct_only': true}),
            options: Options(contentType: 'application/json'),
          );
          final links = listResponse.data['links'] as List?;
          if (links != null && links.isNotEmpty) {
            final url = links.first['url'];
            logger.i('Fetched existing sharable link: $url');
            return url == null ? null : Uri.parse(url);
          }
        }
        rethrow;
      }
      return null;
    });
  }

  @override
  Future<String> uploadFileByShareToken({required String localPath, required String shareToken, Map<String, dynamic>? metadata}) async {
    logger.i("uploadFileById called, which for Dropbox is an alias for uploadFile with path: $shareToken");
    String remotePath = shareToken;
    return uploadFile(localPath: localPath, remotePath: remotePath, metadata: metadata);
  }

  @override
  Future<String> downloadFileByShareToken({required String shareToken, required String localPath}) async {
    // This method doesn't need _executeRequest as it downloads public links
    logger.d('Downloading shared Dropbox file: $shareToken to $localPath');
    final uri = Uri.parse(shareToken).replace(queryParameters: {'dl': '1'});

    // Use a separate Dio instance for downloading public links (no auth needed)
    final publicDio = Dio();
    final response = await publicDio.get(
      uri.toString(),
      options: Options(responseType: ResponseType.stream),
    );

    final file = File(localPath);
    final sink = file.openWrite();
    try {
      // Correctly use addStream and ensure the sink is closed
      await sink.addStream(response.data.stream);
    } finally {
      await sink.close();
    }

    logger.i('Successfully downloaded shared file to $localPath');
    return localPath;
  }

  @override
  Future<String?> getShareTokenFromShareLink(Uri shareLink) async {
    // For Dropbox, the "ID" is the URL itself. We just validate it.
    final url = shareLink.toString();
    if (url.contains('dropbox.com/scl/')) {
      logger.d("Extracted valid Dropbox share link: $url");
      return url;
    }
    logger.w("Link is not a valid Dropbox shared folder/file link: $shareLink");
    return null;
  }
}