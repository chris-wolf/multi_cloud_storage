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
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import 'cloud_storage_provider.dart';
import 'file_log_output.dart';

class DropboxProvider extends CloudStorageProvider {
  // --- Configuration Properties ---
  final String _appKey;
  final String _appSecret;
  final String _redirectUri;

  // --- Token storage ---
  final _secureStorage = const FlutterSecureStorage();
  static const _kDropboxTokenKey = 'dropbox_token';

  late Dio _dio;
  DropboxToken? _token;
  DropboxAccount? _account;
  String? _pkceCodeVerifier;

  bool _isAuthenticated = false;

  /// Private constructor used by the static `connect` method.
  DropboxProvider._create({
    required String appKey,
    required String appSecret,
    required String redirectUri,
  })  : _appKey = appKey,
        _appSecret = appSecret,
        _redirectUri = redirectUri {
    _initializeDio();
  }

  /// Creates and authenticates a [DropboxProvider] instance.
  /// Handles both silent sign-in and interactive user login.
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
      logger.e(
          'Dropbox connection failed: App Key, Secret, or Redirect URI is missing.');
      return null;
    }
    final provider = DropboxProvider._create(
        appKey: appKey, appSecret: appSecret, redirectUri: redirectUri);
    // If interactive login is forced, clear any existing credentials.
    if (forceInteractive) {
      logger.i('Forcing interactive login, clearing existing token.');
      await provider._clearToken();
    }
    try {
      // Attempt to sign in silently with a stored token.
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
        logger.i(
            'Dropbox silent sign-in successful for ${provider._account?.email}');
        return provider;
      }
      // If no token exists, start the interactive login flow.
      logger.i('No valid token found. Starting interactive Dropbox login.');
      final authCode = await provider._getAuthCodeViaInteractiveFlow();
      if (authCode == null) {
        logger.i('Interactive Dropbox login cancelled by user.');
        return null;
      }
      await provider._completeConnection(authCode);
      await provider._saveToken(provider._token);
      logger.i(
          'Interactive Dropbox login successful for ${provider._account?.email}');
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

  /// Lists all files and directories at the specified [path].
  @override
  Future<List<CloudFile>> listFiles(
      {String path = '', bool recursive = false}) {
    return _executeRequest(() async {
      final List<CloudFile> allFiles = [];
      String? cursor;
      bool hasMore = true;
      String initialPath = path == '/' ? '' : _normalizePath(path);
      logger.d(
          'Listing files in Dropbox path: "$initialPath", recursive: $recursive');
      // Paginate through results using the cursor until all files are fetched.
      while (hasMore) {
        Response response;
        if (cursor == null) {
          // First request.
          response = await _dio.post(
            'https://api.dropboxapi.com/2/files/list_folder',
            data: jsonEncode(
                {'path': initialPath, 'recursive': recursive, 'limit': 1000}),
            options: Options(contentType: 'application/json'),
          );
        } else {
          // Subsequent paged requests.
          logger.d('Fetching next page of files with cursor...');
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
      logger.i('Found ${allFiles.length} files/folders in "$initialPath".');
      return allFiles;
    });
  }

  /// Downloads a file from a [remotePath] to a [localPath] on the device.
  @override
  Future<String> downloadFile(
      {required String remotePath, required String localPath}) {
    return _executeRequest(() async {
      final normalizedPath = _normalizePath(remotePath);
      logger.d('Downloading from Dropbox path: $normalizedPath to $localPath');
      final response = await _dio.post(
        'https://content.dropboxapi.com/2/files/download',
        options: Options(
          headers: {
            'Dropbox-API-Arg': jsonEncode({'path': normalizedPath})
          },
          responseType: ResponseType.stream, // Download as a stream.
        ),
      );
      final file = File(localPath);
      final sink = file.openWrite();
      final Stream<Uint8List> stream = response.data.stream;
      await stream.cast<List<int>>().pipe(sink); // Pipe stream to file.
      logger.i('Successfully downloaded file to $localPath');
      return localPath;
    });
  }

  /// Uploads a file from a [localPath] to a [remotePath] in the dropbox.
  @override
  Future<String> uploadFile(
      {required String localPath,
      required String remotePath,
      Map<String, dynamic>? metadata}) {
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
            // Dropbox API arguments are passed in a JSON header.
            'Dropbox-API-Arg': jsonEncode({
              'path': normalizedPath,
              'mode': 'overwrite',
              'autorename': false,
            }),
            'Content-Type': 'application/octet-stream',
            'Content-Length': fileSize,
          },
        ),
      );
      logger.i(
          'Successfully uploaded file to Dropbox, ID: ${response.data['id']}');
      return response.data['id'];
    });
  }

  /// Deletes the file or directory at the specified [path].
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
        // If the file doesn't exist, treat it as a successful deletion.
        if (e.response?.data?['error_summary']
                ?.contains('path_lookup/not_found') ==
            true) {
          logger.w(
              'Path not found during deletion, considering it a success: $normalizedPath');
        } else {
          rethrow;
        }
      }
    });
  }

  /// Creates a new directory at the specified [path].
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
        // If the directory already exists, treat it as a success.
        if (e.response?.data?['error_summary']
                ?.contains('path/conflict/folder') ==
            true) {
          logger.w(
              'Directory already exists, ignoring creation: $normalizedPath');
        } else {
          rethrow;
        }
      }
    });
  }

  /// Retrieves metadata for the file or directory at the specified [path].
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

  /// Retrieves the display name of the currently logged-in user.
  @override
  Future<String?> loggedInUserDisplayName() async => _account?.displayName;

  /// Checks if the current user's authentication token is expired.
  @override
  Future<bool> tokenExpired() async => _token?.isExpired ?? true;

  /// Logs out the current user from dropbox.
  @override
  Future<bool> logout() async {
    logger.i('Logging out from Dropbox.');
    if (_isAuthenticated && _token != null) {
      try {
        // Attempt to revoke the token on Dropbox's servers.
        await _dio.post('https://api.dropboxapi.com/2/auth/token/revoke');
        logger.i('Successfully revoked Dropbox token via API.');
      } catch (e) {
        logger.w(
            'Failed to revoke Dropbox token via API, but logging out locally anyway.',
            error: e);
      }
    }
    // Clear local state regardless of API call success.
    await _clearToken();
    _token = null;
    _account = null;
    _isAuthenticated = false;
    return true;
  }

  /// Generates a shareable link for the file or directory at the [path].
  @override
  Future<Uri?> generateShareLink(String path) {
    return _executeRequest(() async {
      final normalizedPath = _normalizePath(path);
      logger.d('Generating sharable link for Dropbox path: $normalizedPath');
      try {
        // Attempt to create a new public, editable share link.
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
        // If a link already exists, fetch the existing one.
        if (e.response?.data?['error_summary']
                ?.contains('shared_link_already_exists') ==
            true) {
          logger.w(
              'Share link already exists for $normalizedPath, fetching existing one.');
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
  Future<String?> getShareTokenFromShareLink(Uri shareLink) async {
    throw UnsupportedError(
        'getShareTokenFromShareLink is not supported for dropbox');
  }

  @override
  Future<String> uploadFileByShareToken(
      {required String localPath,
      required String shareToken,
      Map<String, dynamic>? metadata}) async {
    throw UnsupportedError(
        'uploadFileByShareToken is not supported for dropbox');
  }

  @override
  Future<String> downloadFileByShareToken(
      {required String shareToken, required String localPath}) async {
    throw UnsupportedError(
        'downloadFileByShareToken is not supported for dropbox');
  }

  /// A centralized wrapper for executing API requests.
  /// It ensures authentication and handles common API errors.
  Future<T> _executeRequest<T>(Future<T> Function() request) async {
    _checkAuth();
    try {
      return await request();
    } on DioException catch (e, stackTrace) {
      logger.e('A DioException occurred in Dropbox request',
          error: e, stackTrace: stackTrace);
      if (e.response?.statusCode == 401) {
        logger
            .w('Dropbox request failed with 401. Possible token invalidation.');
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
      logger.e('An unexpected error occurred in Dropbox request',
          error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Initializes the Dio HTTP client with interceptors for auth and token refresh.
  void _initializeDio() {
    _dio = Dio(BaseOptions(
        sendTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 30)));
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        // Add the Authorization header to every request.
        if (_token != null) {
          options.headers['Authorization'] = 'Bearer ${_token!.accessToken}';
        }
        return handler.next(options);
      },
      onError: (e, handler) async {
        // If a 401 Unauthorized error occurs, attempt to refresh the token.
        if (e.response?.statusCode == 401 && _token?.refreshToken != null) {
          logger.w('Token expired (401). Attempting to refresh Dropbox token.');
          try {
            await _refreshToken();
            await _saveToken(_token);
            logger.i(
                'Dropbox token refreshed successfully. Retrying original request.');
            // Retry the original request with the new token.
            final response = await _dio.request(
              e.requestOptions.path,
              options: Options(
                  method: e.requestOptions.method,
                  headers: e.requestOptions.headers),
              data: e.requestOptions.data,
              queryParameters: e.requestOptions.queryParameters,
            );
            return handler.resolve(response);
          } catch (refreshError, stackTrace) {
            logger.e('Failed to refresh Dropbox token. Logging out.',
                error: refreshError, stackTrace: stackTrace);
            await logout(); // Logout on catastrophic refresh failure.
            return handler.reject(e);
          }
        }
        return handler.next(e);
      },
    ));
  }

  /// Throws an exception if the user is not authenticated.
  void _checkAuth() {
    if (!_isAuthenticated || _token == null) {
      throw Exception(
          'DropboxProvider: Not authenticated. Call connect() first.');
    }
  }

  /// Uses the refresh token to get a new access token.
  Future<void> _refreshToken() async {
    if (_token?.refreshToken == null) {
      throw Exception('No Dropbox refresh token available.');
    }
    logger.i('Executing Dropbox token refresh request.');
    final dioForToken = Dio(); // Use a clean Dio instance for auth.
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
    // Create a new token, preserving the original refresh token.
    _token = DropboxToken(
      accessToken: newPartialToken.accessToken,
      tokenType: newPartialToken.tokenType,
      expiresIn: newPartialToken.expiresIn,
      refreshToken: _token!.refreshToken,
    );
    logger.i('New Dropbox access token obtained.');
  }

  /// Fetches the current user's account info.
  Future<void> _fetchCurrentUserAccount() async {
    if (_token == null) {
      throw Exception('Cannot fetch user account without a token.');
    }
    logger.d('Fetching current Dropbox user account.');
    final response = await _dio
        .post('https://api.dropboxapi.com/2/users/get_current_account');
    _account = DropboxAccount.fromJson(response.data);
    logger.d('Successfully fetched user: ${_account?.email}');
  }

  /// Manages the interactive OAuth2 flow using a web view and app links.
  Future<String?> _getAuthCodeViaInteractiveFlow() async {
    final authUrl = _getAuthorizationUrl();
    final uri = Uri.parse(authUrl);
    final codeCompleter = Completer<String?>();
    final appLinks = AppLinks();
    StreamSubscription? linkSub;

    // Listen for the redirect URI from the OS.
    linkSub = appLinks.uriLinkStream.listen((Uri? link) {
      if (link != null && link.toString().startsWith(_redirectUri)) {
        linkSub?.cancel();
        final code = link.queryParameters['code'];
        if (code != null) {
          logger.i('Received authorization code from redirect.');
          if (!codeCompleter.isCompleted) codeCompleter.complete(code);
        } else {
          final error =
              link.queryParameters['error_description'] ?? 'Unknown error';
          logger.e('Dropbox auth failed from redirect: $error');
          if (!codeCompleter.isCompleted) codeCompleter.complete(null);
        }
      }
    });
    // Launch the auth URL in a web view.
    logger.i('Launching Dropbox authorization URL: $authUrl');
    if (!await launchUrl(uri,
        webViewConfiguration: const WebViewConfiguration())) {
      linkSub.cancel();
      const errorMsg = 'Could not launch Dropbox auth URL';
      logger.e(errorMsg);
      if (!codeCompleter.isCompleted) codeCompleter.completeError(errorMsg);
    }
    return codeCompleter.future;
  }

  /// Exchanges the authorization code for an access token.
  Future<void> _completeConnection(String code) async {
    if (_pkceCodeVerifier == null) {
      throw Exception('PKCE code verifier is missing.');
    }
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
    _pkceCodeVerifier = null; // Verifier is single-use.
    await _fetchCurrentUserAccount();
  }

  /// Saves the token securely to the device's storage.
  Future<void> _saveToken(DropboxToken? token) async {
    if (token == null) return _clearToken();
    final tokenJson = jsonEncode(token.toJson());
    await _secureStorage.write(key: _kDropboxTokenKey, value: tokenJson);
    logger.d('Dropbox token saved to secure storage.');
  }

  /// Retrieves the token from secure storage.
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

  /// Deletes the token from secure storage.
  Future<void> _clearToken() async {
    await _secureStorage.delete(key: _kDropboxTokenKey);
    logger.i('Cleared Dropbox token from secure storage.');
  }

  /// Normalizes a path for the Dropbox API (must start with '/').
  String _normalizePath(String path) {
    if (path.isEmpty || path == '/') {
      return ''; // Root is an empty string for Dropbox API.
    }
    return p.url.normalize(path.startsWith('/') ? path : '/$path');
  }

  /// Maps a Dropbox API file/folder entry to a generic [CloudFile].
  CloudFile _mapToCloudFile(Map<String, dynamic> data) {
    final isDir = data['.tag'] == 'folder';
    return CloudFile(
      path: data['path_display'],
      name: data['name'],
      size: isDir ? null : data['size'],
      modifiedTime:
          isDir ? null : DateTime.tryParse(data['server_modified'] ?? ''),
      isDirectory: isDir,
      metadata: {'id': data['id'], if (!isDir) 'rev': data['rev']},
    );
  }

  /// Constructs the full authorization URL for the OAuth2 PKCE flow.
  String _getAuthorizationUrl() {
    _pkceCodeVerifier = _generateCodeVerifier();
    final queryParams = {
      'client_id': _appKey,
      'response_type': 'code',
      'redirect_uri': _redirectUri,
      'token_access_type': 'offline', // To get a refresh token
      'code_challenge_method': 'S256',
      'code_challenge': _generateCodeChallengeS256(_pkceCodeVerifier!),
      'scope':
          'account_info.read files.content.read files.content.write sharing.write',
    };
    return Uri.https('www.dropbox.com', '/oauth2/authorize', queryParams)
        .toString();
  }

  /// Generates a cryptographically secure random string for PKCE.
  String _generateCodeVerifier() {
    const charset =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final random = Random.secure();
    return List.generate(128, (_) => charset[random.nextInt(charset.length)])
        .join();
  }

  /// Creates a SHA-256 code challenge from a verifier for PKCE.
  String _generateCodeChallengeS256(String verifier) {
    return base64Url
        .encode(sha256.convert(utf8.encode(verifier)).bytes)
        .replaceAll('=', ''); // base64url encoding must not have padding.
  }
}

/// Represents an OAuth2 token for the Dropbox API.
class DropboxToken {
  /// The access token for making API calls.
  final String accessToken;

  /// The type of token (e.g., 'bearer').
  final String tokenType;

  /// The token used to obtain a new access token.
  final String? refreshToken;

  /// The timestamp when the access token expires.
  final DateTime expiresIn;

  DropboxToken({
    required this.accessToken,
    this.refreshToken,
    required this.tokenType,
    required this.expiresIn,
  });

  /// Creates a [DropboxToken] from a JSON map.
  factory DropboxToken.fromJson(Map<String, dynamic> json) {
    final dynamic expiresInValue = json['expires_in'];
    DateTime expires;
    // Handles both integer (seconds) and ISO 8601 string formats for expiration.
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

  /// Converts the [DropboxToken] to a JSON map for storage.
  Map<String, dynamic> toJson() => {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'token_type': tokenType,
        'expires_in': expiresIn.toIso8601String(),
      };

  /// Checks if the token is expired or close to expiring.
  bool get isExpired =>
      DateTime.now().isAfter(expiresIn.subtract(const Duration(minutes: 5)));
}

/// Represents a Dropbox user's account information.
class DropboxAccount {
  /// The user's unique Dropbox account ID.
  final String accountId;

  /// The user's display name.
  final String displayName;

  /// The user's email address.
  final String email;

  DropboxAccount({
    required this.accountId,
    required this.displayName,
    required this.email,
  });

  /// Creates a [DropboxAccount] from a JSON map.
  factory DropboxAccount.fromJson(Map<String, dynamic> json) {
    return DropboxAccount(
      accountId: json['account_id'] as String,
      email: json['email'] as String,
      displayName:
          (json['name'] as Map<String, dynamic>)['display_name'] as String,
    );
  }
}
