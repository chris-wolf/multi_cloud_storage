import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:googleapis_auth/auth_io.dart' as authIo;
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

  Map<String, dynamic> toJson() =>
      {
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
  })
      : _appKey = appKey,
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
      bool forceInteractive = false
  }) async {

    // 1. Check for internet connection first.
    final connectivityResult = await (Connectivity().checkConnectivity());
    if (connectivityResult.contains(ConnectivityResult.none)) {
      debugPrint("No internet connection. Skipping auth flow.");
      // 2. Return null immediately if offline.
      return null;
    }

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

    if (forceInteractive) {
      await provider._clearToken();
    }

    // Attempt to load token from secure storage
    DropboxToken? storedToken = await provider._getToken();
    if (storedToken != null) {
      provider._token = storedToken;
      try {
        if (provider._token!.isExpired) {
          debugPrint(
              "DropboxProvider: Stored token is expired, attempting refresh...");
          await provider._refreshToken();
          await provider
              ._saveToken(provider._token); // Save the refreshed token
        }
        await provider._fetchCurrentUserAccount();
        provider._isAuthenticated = true;
        debugPrint(
            "DropboxProvider: Silent sign-in successful for ${provider._account
                ?.email}");
        return provider;
      } on DioException catch (e) {
        if (e.response?.statusCode == 401) {
          debugPrint("DropboxProvider: Silent sign-in failed - Access denied (401).");
          provider._isAuthenticated = false;
          throw authIo.AccessDeniedException("Dropbox access revoked or token invalid.");
        }

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
    if (storedToken != null  && forceInteractive == false) {
      throw authIo.AccessDeniedException("DropboxProvider: No valid token found.");
    }
    try {
      final authCode = await provider._getAuthCodeViaInteractiveFlow();

      if (authCode == null) {
        debugPrint("DropboxProvider: Interactive login cancelled by user.");
        return null; // User cancelled the flow
      }

      await provider._completeConnection(authCode);
      await provider._saveToken(provider._token); // Save the new token

      debugPrint(
          "DropboxProvider: Interactive login successful for ${provider._account
              ?.email}");
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
    _dio = Dio(BaseOptions(
        sendTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 30)));
    _dio.interceptors.add(LogInterceptor(requestBody: true, responseBody: true, requestHeader: true));

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
          } on DioException catch (refreshError) {
            if ((refreshError.response?.data as Map<String, dynamic>).values.any((value) => value == 'invalid_grant')) {
              debugPrint("DropboxProvider: Silent sign-in failed - Access denied (${(refreshError.response?.data as Map<String, dynamic>)?.toString()}).");
              return handler.reject(e); // Propagate the original error
              return;
            }

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
              "Dropbox auth error from redirect: ${link
                  .queryParameters['error']}");
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
      // V-- ADD THIS LINE --V
      'scope': 'account_info.read files.content.read files.content.write',
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
  Future<String> uploadFile({required String localPath,
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
            'mode': 'overwrite',
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
    final headers = {
      'Authorization': 'Bearer ${_token!.accessToken}',
      'Dropbox-API-Arg': jsonEncode({'path': _normalizePath(remotePath)}),
    };

    try {
      final response = await _dio.post(
        'https://content.dropboxapi.com/2/files/download',
        options: Options(
          headers: headers,
          responseType: ResponseType.stream,
        ),
      );

      final file = File(localPath);
      final sink = file.openWrite();
      await sink.addStream(response.data.stream);
      await sink.close();
      return localPath;

    } on DioException catch (e) {
      // If the error response has a body, read and print it.
      if (e.response?.data is ResponseBody) {
        final errorBody = await _readErrorBody(e.response!.data);
        debugPrint("--- DROPBOX API ERROR ---");
        debugPrint(errorBody);
        debugPrint("-------------------------");
      }
      // Rethrow the original exception so the app still knows an error occurred.
      rethrow;
    }
  }

  /// Helper to read the body of a Dio error response when it's a stream.
  Future<String> _readErrorBody(ResponseBody responseBody) async {
    final completer = Completer<String>();
    final contents = StringBuffer();
    responseBody.stream.listen(
          (data) {
        contents.write(utf8.decode(data));
      },
      onDone: () => completer.complete(contents.toString()),
      onError: (error, stackTrace) => completer.completeError(error, stackTrace),
    );
    return completer.future;
  }


  @override
  Future<void> deleteFile(String path) async {
    _checkAuth();
    try {
      await _dio.post(
        'https://api.dropboxapi.com/2/files/delete_v2',
        data: jsonEncode({'path': _normalizePath(path)}),
        options: Options(contentType: 'application/json'),
      );
      debugPrint("DropboxProvider: Successfully deleted '$path'.");
    } on DioException catch (e) {
      // Check if the error is because the file or folder was not found.
      // The Dropbox API returns an error summary containing 'path_lookup/not_found'.
      if (e.response?.data?['error_summary']?.contains(
          'path_lookup/not_found') == true) {
        // If it doesn't exist, we can consider the "deletion" successful for our purpose.
        debugPrint(
            "DropboxProvider: Path '$path' not found, but treating as a success as it does not need deletion.");
      } else {
        // For any other type of error (e.g., authentication, network), we should rethrow it.
        debugPrint(
            "DropboxProvider: An unexpected error occurred while deleting '$path': ${e
                .response?.data ?? e.message}");
        rethrow;
      }
    }
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
      if (e.response?.data?['error_summary']
          ?.contains('path/conflict/folder') ==
          false) {
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
          ? DateTime
          .now() // Folders don't have a specific modified time in list_folder
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

  // Make sure Dio is initialized with the LogInterceptor in your class constructor
// _dio.interceptors.add(LogInterceptor(requestBody: true, responseBody: true));

  /// Generates a sharable link that allows other Dropbox users to edit contents.
  @override
  Future<Uri?> generateSharableLink(String path) async {
    _checkAuth();

    final normalizedPath = _normalizePath(path);
    const hardTimeout = Duration(seconds: 30);
    final cancelToken = CancelToken();

    try {
      // 1. First, attempt to create a new shared link as before.
      final createResponse = await _dio.post(
        'https://api.dropboxapi.com/2/sharing/create_shared_link_with_settings',
        data: jsonEncode({
          'path': normalizedPath,
          'settings': {
            'requested_visibility': 'public', // Or 'team_only', etc.
            'access': 'editor',
          }
        }),
        options: Options(contentType: 'application/json'),
        cancelToken: cancelToken,
      ).timeout(
        hardTimeout,
        onTimeout: () {
          cancelToken.cancel(
              'API call timed out after ${hardTimeout.inSeconds} seconds.');
          throw TimeoutException(
              'The request to create a link took too long and was cancelled.');
        },
      );

      final url = createResponse.data['url'];
      return url == null ? null : Uri.parse(url);
    } on DioException catch (e) {
      // 2. If the first attempt fails, inspect the error.
      if (e.response?.statusCode == 409 &&
          e.response?.data?['error_summary']?.contains(
              'shared_link_already_exists') == true) {
        // 3. This is the specific error we want to handle. The link already exists.
        // Now, we call a different endpoint to get the existing link's URL.
        debugPrint(
            "Link already exists for path: $normalizedPath. Fetching existing link.");

        try {
          final listResponse = await _dio.post(
            'https://api.dropboxapi.com/2/sharing/list_shared_links',
            data: jsonEncode({
              'path': normalizedPath,
              'direct_only': true, // We only want links for this specific path
            }),
            options: Options(contentType: 'application/json'),
          );

          // The response contains a list of links. We'll take the first one.
          final links = listResponse.data['links'] as List?;
          if (links != null && links.isNotEmpty) {
            final url = links.first['url'];
            return url == null ? null : Uri.parse(url);
          } else {
            // This is an unlikely edge case, but good to handle.
            // The API said a link exists, but we couldn't find it.
            throw Exception(
                'Dropbox reported an existing link, but it could not be retrieved.');
          }
        } catch (listError) {
          debugPrint("Failed to retrieve existing shared link: $listError");
          rethrow; // Rethrow the error from the second API call.
        }
      }

      // 4. Handle other errors (cancellation, timeout, other server errors)
      if (e.type == DioExceptionType.cancel) {
        debugPrint('Request was cancelled: ${e.message}');
      } else {
        debugPrint('A DioException occurred while creating a share link: ${e
            .message}');
      }
      // For any other error, rethrow it so the calling code can handle it.
      rethrow;
    } on TimeoutException catch (e) {
      // Catch the TimeoutException thrown from the onTimeout callback.
      debugPrint(e.message);
      rethrow;
    }
  }


  @override
  Future<String?> extractFileIdFromSharableLink(Uri shareLink) async {
    if (shareLink.host.contains('dropbox.com') &&
        shareLink.path.contains('/scl/fo/')) {
      return shareLink.toString();
    }
    debugPrint("Link is not a valid Dropbox shared folder link: $shareLink");
    return null;
  }

  @override
  Future<String> uploadFileById({required String localPath,
    required String fileId,
    Map<String, dynamic>? metadata, String? subPath}) async {
   // todo
    return '';
  }

  @override
  Future<String> getSharedFileById(
      {required String fileId, // This is the shared URL
        required String localPath,
        String? subPath}) async {
    throw UnimplementedError();
  }

}
