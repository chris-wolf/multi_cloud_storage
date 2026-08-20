import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:googleapis_auth/googleapis_auth.dart' show AccessDeniedException;
import 'package:http/http.dart' as http;

import 'multi_cloud_storage.dart';

/// Representation of an OAuth2 token response from Microsoft identity platform.
class OneDriveToken {
  final String accessToken;
  final String? refreshToken;
  final String tokenType;
  final DateTime expiresIn;

  OneDriveToken({
    required this.accessToken,
    this.refreshToken,
    required this.tokenType,
    required this.expiresIn,
  });

  factory OneDriveToken.fromJson(Map<String, dynamic> json) {
    final dynamic expiresInValue = json['expires_in'];
    DateTime expires;
    if (expiresInValue is int) {
      expires = DateTime.now().add(Duration(seconds: expiresInValue));
    } else if (expiresInValue is String) {
      expires = DateTime.tryParse(expiresInValue) ??
          DateTime.now().add(const Duration(hours: 1));
    } else {
      expires = DateTime.now().add(const Duration(hours: 1));
    }
    return OneDriveToken(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String?,
      tokenType: (json['token_type'] as String?) ?? 'Bearer',
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

/// Standalone, robust provider for Microsoft OneDrive via Microsoft Graph API.
class OneDriveProvider extends CloudStorageProvider {
  static const String authHost = 'login.microsoftonline.com';
  static const String authPath = '/common/oauth2/v2.0/authorize';
  static const String tokenEndpoint =
      'https://login.microsoftonline.com/common/oauth2/v2.0/token';
  static const String graphApiEndpoint = 'https://graph.microsoft.com/v1.0';

  static const String _kOneDriveTokenKey = 'onedrive_token';
  final _secureStorage = const FlutterSecureStorage();

  final String clientId;
  final String redirectUri;
  final BuildContext context;
  final String scopes;

  OneDriveToken? _token;
  bool _isAuthenticated = false;

  /// Private constructor. Use [connect] to instantiate.
  OneDriveProvider._create({
    required this.clientId,
    required this.redirectUri,
    required this.context,
    required this.scopes,
  });

  /// Connects to OneDrive, handling both silent token restoration and interactive login.
  static Future<OneDriveProvider?> connect({
    required String clientId,
    required String redirectUri,
    required BuildContext context,
    String? scopes,
    bool forceInteractive = false,
  }) async {
    if (clientId.trim().isEmpty) {
      throw ArgumentError(
          'App registration required: https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade');
    }
    if (redirectUri.isEmpty) {
      redirectUri =
          'https://login.microsoftonline.com/common/oauth2/nativeclient';
    }

    final resolvedScopes = scopes ??
        "${MultiCloudStorage.cloudAccess == CloudAccessType.appStorage ? 'Files.ReadWrite.AppFolder' : 'Files.ReadWrite.All'} offline_access User.Read Sites.ReadWrite.All";

    final provider = OneDriveProvider._create(
      clientId: clientId,
      redirectUri: redirectUri,
      context: context,
      scopes: resolvedScopes,
    );

    if (forceInteractive) {
      debugPrint(
          '[OneDriveProvider] Forcing interactive login, clearing stored token.');
      await provider._clearToken();
    }

    // 1. Silent connect attempt using stored token
    if (!forceInteractive) {
      final storedToken = await provider._getToken();
      if (storedToken != null) {
        provider._token = storedToken;
        if (provider._token!.isExpired) {
          debugPrint(
              '[OneDriveProvider] Stored token is expired, attempting silent refresh.');
          final refreshed = await provider._refreshToken();
          if (refreshed) {
            provider._isAuthenticated = true;
            debugPrint(
                '[OneDriveProvider] Silently connected successfully after token refresh.');
            return provider;
          }
        } else {
          provider._isAuthenticated = true;
          debugPrint(
              '[OneDriveProvider] Silently connected successfully with stored token.');
          return provider;
        }
      }
    }

    // 2. Interactive login via InAppWebView
    debugPrint(
        '[OneDriveProvider] No valid stored token. Starting interactive login...');
    if (!context.mounted) {
      debugPrint(
          '[OneDriveProvider] Context not mounted. Aborting interactive login.');
      return null;
    }

    final token = await provider._startInteractiveAuth(context);
    if (token == null) {
      debugPrint('[OneDriveProvider] Interactive login failed or was cancelled.');
      return null;
    }

    provider._token = token;
    provider._isAuthenticated = true;
    debugPrint('[OneDriveProvider] Interactive login successful.');
    return provider;
  }

  /// Initiates interactive OAuth 2.0 PKCE login in an InAppWebView modal.
  Future<OneDriveToken?> _startInteractiveAuth(BuildContext context) async {
    final codeVerifier = _generateCodeVerifier();
    final codeChallenge = _generateCodeChallenge(codeVerifier);
    final state = _generateRandomState();

    final authUri = Uri.https(authHost, authPath, {
      'client_id': clientId,
      'response_type': 'code',
      'redirect_uri': redirectUri,
      'response_mode': 'query',
      'scope': scopes,
      'state': state,
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
      'prompt': 'select_account',
    });

    debugPrint('[OneDriveProvider] Launching OAuth screen: $authUri');
    final result = await Navigator.of(context).push<Map<String, String?>>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (ctx) => OneDriveAuthScreen(
          initialUri: authUri,
          redirectUri: redirectUri,
        ),
      ),
    );

    if (result == null) {
      debugPrint('[OneDriveProvider] User cancelled OAuth screen.');
      return null;
    }

    if (result['error'] != null) {
      debugPrint(
          '[OneDriveProvider] OAuth error from redirect: ${result['error']} - ${result['error_description']}');
      return null;
    }

    final code = result['code'];
    if (code == null || code.isEmpty) {
      debugPrint('[OneDriveProvider] No authorization code found in redirect.');
      return null;
    }

    debugPrint('[OneDriveProvider] Exchanging authorization code for tokens...');
    try {
      final response = await http.post(
        Uri.parse(tokenEndpoint),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': clientId,
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': redirectUri,
          'code_verifier': codeVerifier,
        },
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final token = OneDriveToken.fromJson(json);
        await _saveToken(token);
        debugPrint('[OneDriveProvider] Token exchange successful and token saved.');
        return token;
      } else {
        debugPrint(
            '[OneDriveProvider] Token exchange failed: ${response.statusCode} - ${response.body}');
        return null;
      }
    } catch (e, st) {
      debugPrint('[OneDriveProvider] Exception during token exchange: $e\n$st');
      return null;
    }
  }

  /// Lists all files and directories at the specified [path].
  @override
  Future<List<CloudFile>> listFiles({
    String path = '',
    bool recursive = false,
  }) {
    return _executeRequest(() async {
      final accessToken = await _getAccessToken();
      final root = _getRootFolder();
      final norm = _normalizePath(path);
      String url = (norm == '/' || norm.isEmpty)
          ? '$graphApiEndpoint/me/drive/$root/children'
          : '$graphApiEndpoint/me/drive/$root:$norm:/children';

      final List<CloudFile> files = [];
      String? nextUrl = url;

      while (nextUrl != null) {
        final response = await http.get(
          Uri.parse(nextUrl),
          headers: {'Authorization': 'Bearer $accessToken'},
        );
        if (response.statusCode == 404) {
          throw NotFoundException('Path not found: $path');
        }
        if (response.statusCode != 200) {
          throw Exception(
              'Failed to list files: ${response.statusCode} - ${response.body}');
        }
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final items = json['value'] as List? ?? [];
        for (final item in items) {
          final isDir = item['folder'] != null;
          final name = item['name'] as String? ?? '';
          final itemPath = norm == '/' ? '/$name' : '$norm/$name';
          final modifiedTime =
              DateTime.tryParse(item['lastModifiedDateTime'] as String? ?? '') ??
                  DateTime.now();
          final size = item['size'] as int?;
          files.add(CloudFile(
            path: itemPath,
            name: name,
            size: isDir ? null : size,
            modifiedTime: modifiedTime,
            isDirectory: isDir,
          ));
          if (recursive && isDir) {
            final subFiles = await listFiles(path: itemPath, recursive: true);
            files.addAll(subFiles);
          }
        }
        nextUrl = json['@odata.nextLink'] as String?;
      }
      return files;
    }, operation: 'listFiles at $path');
  }

  /// Downloads a file from a [remotePath] to a [localPath] on the device.
  @override
  Future<String> downloadFile({
    required String remotePath,
    required String localPath,
  }) {
    return _executeRequest(() async {
      final accessToken = await _getAccessToken();
      final itemUrl = '${_buildItemUrl(remotePath)}:/content';
      debugPrint('[OneDriveProvider] Downloading file from: $itemUrl');
      final request = http.Request('GET', Uri.parse(itemUrl))
        ..headers['Authorization'] = 'Bearer $accessToken'
        ..followRedirects = true;

      final streamedResponse = await request.send();
      if (streamedResponse.statusCode == 404) {
        throw NotFoundException('File not found: $remotePath');
      }
      if (streamedResponse.statusCode != 200 &&
          streamedResponse.statusCode != 201) {
        final body = await streamedResponse.stream.bytesToString();
        throw Exception(
            'Failed to download file ($remotePath): ${streamedResponse.statusCode} - $body');
      }
      final file = File(localPath);
      await file.parent.create(recursive: true);
      final sink = file.openWrite();
      await streamedResponse.stream.pipe(sink);
      await sink.close();
      debugPrint('[OneDriveProvider] File downloaded successfully to: $localPath');
      return localPath;
    }, operation: 'downloadFile from $remotePath');
  }

  /// Uploads a file from a [localPath] to a [remotePath] in OneDrive.
  @override
  Future<String> uploadFile({
    required String localPath,
    required String remotePath,
    Map<String, dynamic>? metadata,
  }) {
    return _executeRequest(() async {
      final accessToken = await _getAccessToken();
      final file = File(localPath);
      if (!await file.exists()) {
        throw NotFoundException('Local file not found: $localPath');
      }
      final bytes = await file.readAsBytes();
      final fileSize = bytes.length;
      final itemUrl = _buildItemUrl(remotePath);

      // Simple upload for files < 4MB
      if (fileSize < 4 * 1024 * 1024) {
        final uploadUrl = '$itemUrl:/content';
        debugPrint(
            '[OneDriveProvider] Uploading file (< 4MB, $fileSize bytes) to: $uploadUrl');
        final response = await http.put(
          Uri.parse(uploadUrl),
          headers: {
            'Authorization': 'Bearer $accessToken',
            'Content-Type': 'application/octet-stream',
          },
          body: bytes,
        );
        if (response.statusCode == 200 || response.statusCode == 201) {
          debugPrint('[OneDriveProvider] Upload successful.');
          return remotePath;
        } else {
          throw Exception(
              'Failed to upload file ($remotePath): ${response.statusCode} - ${response.body}');
        }
      } else {
        // Chunked upload session for files >= 4MB
        final sessionUrl = '$itemUrl:/createUploadSession';
        debugPrint(
            '[OneDriveProvider] Creating upload session for $fileSize bytes at: $sessionUrl');
        final sessionResp = await http.post(
          Uri.parse(sessionUrl),
          headers: {
            'Authorization': 'Bearer $accessToken',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'item': {'@microsoft.graph.conflictBehavior': 'replace'}
          }),
        );
        if (sessionResp.statusCode != 200) {
          throw Exception(
              'Failed to create upload session: ${sessionResp.statusCode} - ${sessionResp.body}');
        }
        final sessionJson =
            jsonDecode(sessionResp.body) as Map<String, dynamic>;
        final uploadUrl = sessionJson['uploadUrl'] as String;

        const chunkSize = 1024 * 1024; // 1MB chunks
        final totalChunks = (fileSize / chunkSize).ceil();
        for (int i = 0; i < totalChunks; i++) {
          final start = i * chunkSize;
          var end = start + chunkSize;
          if (end > fileSize) end = fileSize;
          final chunk = bytes.sublist(start, end);
          final rangeHeader = 'bytes $start-${end - 1}/$fileSize';
          debugPrint(
              '[OneDriveProvider] Uploading chunk ${i + 1}/$totalChunks ($rangeHeader)...');
          final chunkResp = await http.put(
            Uri.parse(uploadUrl),
            headers: {
              'Content-Length': '${chunk.length}',
              'Content-Range': rangeHeader,
            },
            body: chunk,
          );
          if (chunkResp.statusCode != 200 &&
              chunkResp.statusCode != 201 &&
              chunkResp.statusCode != 202) {
            throw Exception(
                'Chunk upload failed [${chunkResp.statusCode}]: ${chunkResp.body}');
          }
        }
        debugPrint('[OneDriveProvider] Chunked upload completed successfully.');
        return remotePath;
      }
    }, operation: 'uploadFile to $remotePath');
  }

  /// Deletes the file or directory at the specified [path].
  @override
  Future<void> deleteFile(String path) {
    return _executeRequest(() async {
      final accessToken = await _getAccessToken();
      final itemUrl = _buildItemUrl(path);
      debugPrint('[OneDriveProvider] Deleting item at: $itemUrl');
      final response = await http.delete(
        Uri.parse(itemUrl),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      if (response.statusCode != 204 &&
          response.statusCode != 200 &&
          response.statusCode != 404) {
        throw Exception(
            'Failed to delete file ($path): ${response.statusCode} - ${response.body}');
      }
    }, operation: 'deleteFile at $path');
  }

  /// Creates a new directory at the specified [path].
  @override
  Future<void> createDirectory(String path) {
    return _executeRequest(() async {
      final accessToken = await _getAccessToken();
      final norm = _normalizePath(path);
      final parts = norm.split('/').where((s) => s.isNotEmpty).toList();
      if (parts.isEmpty) return;
      final folderName = parts.last;
      final parentPath = parts.length > 1
          ? '/${parts.sublist(0, parts.length - 1).join('/')}'
          : '/';

      final root = _getRootFolder();
      final parentUrl = parentPath == '/'
          ? '$graphApiEndpoint/me/drive/$root/children'
          : '$graphApiEndpoint/me/drive/$root:$parentPath:/children';

      final response = await http.post(
        Uri.parse(parentUrl),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'name': folderName,
          'folder': {},
          '@microsoft.graph.conflictBehavior': 'replace',
        }),
      );
      if (response.statusCode != 200 && response.statusCode != 201) {
        throw Exception(
            'Failed to create directory ($path): ${response.statusCode} - ${response.body}');
      }
    }, operation: 'createDirectory at $path');
  }

  /// Retrieves metadata for the item at the specified [path].
  @override
  Future<CloudFile> getFileMetadata(String path) {
    return _executeRequest(() async {
      final accessToken = await _getAccessToken();
      final itemUrl = _buildItemUrl(path);
      final response = await http.get(
        Uri.parse(itemUrl),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      if (response.statusCode == 404) {
        throw NotFoundException('File not found: $path');
      }
      if (response.statusCode != 200) {
        throw Exception(
            'Failed to get metadata ($path): ${response.statusCode} - ${response.body}');
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final isDir = json['folder'] != null;
      return CloudFile(
        path: path,
        name: json['name'] as String? ?? '',
        size: isDir ? null : json['size'] as int?,
        modifiedTime:
            DateTime.tryParse(json['lastModifiedDateTime'] as String? ?? '') ??
                DateTime.now(),
        isDirectory: isDir,
      );
    }, operation: 'getFileMetadata for $path');
  }

  /// Retrieves the display name or email of the currently logged-in user.
  @override
  Future<String?> loggedInUserDisplayName() {
    return _executeRequest(() async {
      final accessToken = await _getAccessToken();
      final response = await http.get(
        Uri.parse('$graphApiEndpoint/me'),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      if (response.statusCode != 200) {
        debugPrint(
            '[OneDriveProvider] loggedInUserDisplayName returned status ${response.statusCode}');
        return null;
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      String? name = json['displayName'] as String?;
      if (name == null || name.trim().isEmpty) {
        name = json['userPrincipalName'] as String?;
      }
      if (name == null || name.trim().isEmpty) {
        name = json['mail'] as String?;
      }
      return name;
    }, operation: 'loggedInUserDisplayName');
  }

  /// Checks if the user's authentication token is expired.
  @override
  Future<bool> tokenExpired() async {
    if (!_isAuthenticated || _token == null) return true;
    return _token!.isExpired;
  }

  /// Logs out the current user and cleans up credentials and WebView cookies.
  @override
  Future<bool> logout() async {
    debugPrint('[OneDriveProvider] Logging out from OneDrive...');
    try {
      await _clearToken();
      _isAuthenticated = false;
      _token = null;
      final cookieManager = CookieManager.instance();
      await cookieManager.deleteAllCookies();
      debugPrint(
          '[OneDriveProvider] OneDrive logout successful and web cookies cleared.');
      return true;
    } catch (e) {
      debugPrint('[OneDriveProvider] Error during OneDrive logout: $e');
      return false;
    }
  }

  /// Generates a shareable link for the file or directory at [path].
  @override
  Future<Uri?> generateShareLink(String path) {
    return _executeRequest(() async {
      final accessToken = await _getAccessToken();
      final encodedPath = Uri.encodeComponent(
          path.startsWith('/') ? path.substring(1) : path);
      final driveItemPath = '/me/drive/root:/$encodedPath:/createLink';

      final response = await http.post(
        Uri.parse('$graphApiEndpoint$driveItemPath'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'type': 'edit', 'scope': 'anonymous'}),
      );
      if (response.statusCode != 200 && response.statusCode != 201) {
        debugPrint(
            'Failed to create shareable link. Status: ${response.statusCode}, Body: ${response.body}');
        return null;
      }
      final json = jsonDecode(response.body);
      final link = json['link']?['webUrl'];
      return link != null ? Uri.parse(link) : null;
    }, operation: 'generateShareLink for $path');
  }

  /// Returns the share token representation from a given share link.
  @override
  Future<String?> getShareTokenFromShareLink(Uri shareLink) async {
    return shareLink.toString();
  }

  /// Downloads a shared file to [localPath] using a [shareToken].
  @override
  Future<String> downloadFileByShareToken({
    required String shareToken,
    required String localPath,
  }) async {
    final completer = Completer<String>();
    late HeadlessInAppWebView headlessWebView;
    final initialUrl =
        Uri.parse(shareToken).replace(queryParameters: {'download': '1'});
    debugPrint(
        'Starting headless WebView to resolve download for: $initialUrl');
    headlessWebView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri.uri(initialUrl)),
      onDownloadStartRequest: (controller, downloadStartRequest) async {
        final finalUrl = downloadStartRequest.url.toString();
        debugPrint('WebView captured final download URL: $finalUrl');
        if (!completer.isCompleted) {
          completer.complete(finalUrl);
        }
      },
      onReceivedError: (controller, request, error) {
        debugPrint(
            'WebView error: Type ${error.type}, Message: ${error.description}');
        if (!completer.isCompleted) {
          completer.completeError(
              Exception('WebView error: ${error.description}'));
        }
      },
      onLoadStop: (controller, url) async {
        if (!completer.isCompleted) {
          final pageBody = await controller.getHtml() ?? '';
          if (pageBody.toLowerCase().contains('error') ||
              pageBody.toLowerCase().contains('denied')) {
            completer.completeError(NotFoundException(
                'WebView navigation ended on an error page. File may not exist or permissions are denied.'));
          }
        }
      },
    );
    try {
      await headlessWebView.run();
      final finalDownloadUrl =
          await completer.future.timeout(const Duration(seconds: 30));
      await headlessWebView.dispose();

      final dio = Dio();
      dio.interceptors.add(WebViewCookieInterceptor());
      debugPrint('Downloading with Dio using WebView cookies and Referer.');
      await dio.download(
        finalDownloadUrl,
        localPath,
        options: Options(
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36',
            'Referer': shareToken,
          },
        ),
      );
      debugPrint('File successfully downloaded to $localPath');
      return localPath;
    } catch (e) {
      debugPrint('Error during WebView download process: $e');
      await headlessWebView.dispose();
      rethrow;
    }
  }

  /// Uploads a file from [localPath] using a [shareToken].
  @override
  Future<String> uploadFileByShareToken({
    required String localPath,
    required String shareToken,
    Map<String, dynamic>? metadata,
  }) {
    return _executeRequest(() async {
      final accessToken = await _getAccessToken();
      final resolvedInfo = await _resolveShareUrlForUpload(shareToken);
      if (resolvedInfo == null) {
        throw Exception(
            'Could not resolve the provided sharing URL for upload.');
      }
      final uploadUri = Uri.parse(
          'https://graph.microsoft.com/v1.0/drives/${resolvedInfo.driveId}/items/${resolvedInfo.itemId}/content');
      final fileBytes = await File(localPath).readAsBytes();
      final uploadResponse = await http.put(
        uploadUri,
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/octet-stream',
        },
        body: fileBytes,
      );
      if (uploadResponse.statusCode >= 200 &&
          uploadResponse.statusCode < 300) {
        debugPrint('Successfully uploaded file to shared URL location.');
        return shareToken;
      } else {
        throw Exception(
            'Failed to upload file content. Status: ${uploadResponse.statusCode}, Body: ${uploadResponse.body}');
      }
    }, operation: 'uploadToSharedUrl: $shareToken');
  }

  // --- Internal Helpers ---

  Future<T> _executeRequest<T>(
    Future<T> Function() request, {
    required String operation,
  }) async {
    _checkAuth();
    try {
      debugPrint('[OneDriveProvider] Executing operation: $operation');
      return await request();
    } on SocketException catch (e) {
      debugPrint('[OneDriveProvider] No connection detected.');
      throw NoConnectionException(e.message);
    } catch (e) {
      debugPrint('[OneDriveProvider] Error during operation ($operation): $e');
      if (e.toString().contains('401') ||
          e.toString().contains('invalid_grant')) {
        _isAuthenticated = false;
        debugPrint(
            '[OneDriveProvider] Token expired or invalid. Re-authentication required.');
      }
      rethrow;
    }
  }

  void _checkAuth() {
    if (!_isAuthenticated) {
      throw AccessDeniedException(
          'OneDriveProvider: Not authenticated. Call connect() first.');
    }
  }

  Future<String> _getAccessToken() async {
    _token ??= await _getToken();
    if (_token == null) {
      throw AccessDeniedException(
          'No valid OneDrive token found. Please re-authenticate.');
    }
    if (_token!.isExpired) {
      final refreshed = await _refreshToken();
      if (!refreshed || _token == null) {
        throw AccessDeniedException(
            'OneDrive token expired and refresh failed. Please re-authenticate.');
      }
    }
    return _token!.accessToken;
  }

  Future<bool> _refreshToken() async {
    if (_token?.refreshToken == null || _token!.refreshToken!.isEmpty) {
      return false;
    }
    debugPrint('[OneDriveProvider] Refreshing access token...');
    try {
      final response = await http.post(
        Uri.parse(tokenEndpoint),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': clientId,
          'grant_type': 'refresh_token',
          'refresh_token': _token!.refreshToken!,
          'redirect_uri': redirectUri,
        },
      );
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        _token = OneDriveToken.fromJson(json);
        await _saveToken(_token);
        debugPrint('[OneDriveProvider] Token refreshed successfully.');
        return true;
      } else {
        debugPrint(
            '[OneDriveProvider] Token refresh failed (${response.statusCode}): ${response.body}');
        await _clearToken();
        return false;
      }
    } catch (e) {
      debugPrint('[OneDriveProvider] Error during token refresh: $e');
      return false;
    }
  }

  Future<void> _saveToken(OneDriveToken? token) async {
    if (token == null) {
      await _clearToken();
      return;
    }
    final tokenJson = jsonEncode(token.toJson());
    await _secureStorage.write(key: _kOneDriveTokenKey, value: tokenJson);
    debugPrint('[OneDriveProvider] Token saved to secure storage.');
  }

  Future<OneDriveToken?> _getToken() async {
    final tokenJson = await _secureStorage.read(key: _kOneDriveTokenKey);
    if (tokenJson == null) return null;
    try {
      return OneDriveToken.fromJson(
          jsonDecode(tokenJson) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[OneDriveProvider] Error reading stored token, clearing it.');
      await _clearToken();
      return null;
    }
  }

  Future<void> _clearToken() async {
    await _secureStorage.delete(key: _kOneDriveTokenKey);
    debugPrint('[OneDriveProvider] Cleared token from secure storage.');
  }

  String _getRootFolder() {
    return MultiCloudStorage.cloudAccess == CloudAccessType.appStorage
        ? 'special/approot'
        : 'root';
  }

  String _normalizePath(String path) {
    if (path.isEmpty || path == '/') return '';
    var norm = path.replaceAll('\\', '/');
    if (!norm.startsWith('/')) norm = '/$norm';
    if (norm.endsWith('/') && norm.length > 1) {
      norm = norm.substring(0, norm.length - 1);
    }
    return norm;
  }

  String _buildItemUrl(String path) {
    final root = _getRootFolder();
    final norm = _normalizePath(path);
    if (norm.isEmpty) {
      return '$graphApiEndpoint/me/drive/$root';
    }
    return '$graphApiEndpoint/me/drive/$root:$norm';
  }

  Future<_ResolvedShareInfo?> _resolveShareUrlForUpload(String shareUrl) async {
    final accessToken = await _getAccessToken();
    final String encodedUrl = _encodeShareUrlForGraphAPI(shareUrl);
    final resolveUri = Uri.parse(
        'https://graph.microsoft.com/v1.0/shares/$encodedUrl/driveItem?\$select=id,driveId,parentReference,remoteItem');
    final response = await http.get(resolveUri, headers: {
      'Authorization': 'Bearer $accessToken',
      'Prefer': 'redeemSharingLink',
    });
    if (response.statusCode != 200) {
      debugPrint(
          'Failed to resolve share URL. Status: ${response.statusCode}, Body: ${response.body}');
      return null;
    }
    final json = jsonDecode(response.body);
    final remoteItem = json['remoteItem'];
    if (remoteItem != null &&
        remoteItem['id'] != null &&
        remoteItem['driveId'] != null) {
      debugPrint('Resolved a remote item from another drive.');
      return _ResolvedShareInfo(
          driveId: remoteItem['driveId'], itemId: remoteItem['id']);
    }
    final String? itemId = json['id'];
    final String? driveId = json['parentReference']?['driveId'];
    if (itemId == null || driveId == null) {
      debugPrint(
          'Could not extract driveId and itemId from resolved share response: ${response.body}');
      return null;
    }
    debugPrint('Resolved an item from the user\'s own drive.');
    return _ResolvedShareInfo(driveId: driveId, itemId: itemId);
  }

  String _encodeShareUrlForGraphAPI(String url) {
    final String base64UrlString = base64Url.encode(utf8.encode(url));
    return 'u!$base64UrlString';
  }

  static String _generateCodeVerifier() {
    const charset =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final random = Random.secure();
    return List.generate(128, (_) => charset[random.nextInt(charset.length)])
        .join();
  }

  static String _generateCodeChallenge(String verifier) {
    return base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
  }

  static String _generateRandomState() {
    final bytes = List.generate(16, (_) => Random.secure().nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}

/// Helper class for resolved shared items.
class _ResolvedShareInfo {
  final String driveId;
  final String itemId;

  _ResolvedShareInfo({required this.driveId, required this.itemId});
}

/// In-App WebView screen for OneDrive OAuth 2.0 PKCE authentication.
class OneDriveAuthScreen extends StatefulWidget {
  final Uri initialUri;
  final String redirectUri;

  const OneDriveAuthScreen({
    super.key,
    required this.initialUri,
    required this.redirectUri,
  });

  @override
  State<OneDriveAuthScreen> createState() => _OneDriveAuthScreenState();
}

class _OneDriveAuthScreenState extends State<OneDriveAuthScreen> {
  bool _isLoading = true;
  bool _hasResult = false;

  void _checkRedirect(WebUri? uri) {
    if (_hasResult || uri == null) return;
    final uriStr = uri.toString();
    if (uriStr.startsWith(widget.redirectUri)) {
      _hasResult = true;
      final parsed = Uri.parse(uriStr);
      final code = parsed.queryParameters['code'];
      final error = parsed.queryParameters['error'];
      final errorDesc = parsed.queryParameters['error_description'];
      if (mounted) {
        Navigator.of(context).pop<Map<String, String?>>({
          'code': code,
          'error': error,
          'error_description': errorDesc,
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign in to OneDrive'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            if (!_hasResult && mounted) {
              Navigator.of(context).pop<Map<String, String?>>(null);
            }
          },
        ),
        bottom: _isLoading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(4.0),
                child: LinearProgressIndicator(),
              )
            : null,
      ),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri.uri(widget.initialUri)),
        initialSettings: InAppWebViewSettings(
          useShouldOverrideUrlLoading: true,
          useHybridComposition: true,
          transparentBackground: false,
        ),
        onLoadStart: (controller, url) {
          if (mounted) setState(() => _isLoading = true);
          _checkRedirect(url);
        },
        onLoadStop: (controller, url) {
          if (mounted) setState(() => _isLoading = false);
          _checkRedirect(url);
        },
        onReceivedError: (controller, request, error) {
          if (mounted) setState(() => _isLoading = false);
          debugPrint(
              '[OneDriveAuthScreen] WebView error: ${error.description}');
        },
        shouldOverrideUrlLoading: (controller, navigationAction) async {
          final uri = navigationAction.request.url;
          if (uri != null && uri.toString().startsWith(widget.redirectUri)) {
            _checkRedirect(uri);
            return NavigationActionPolicy.CANCEL;
          }
          return NavigationActionPolicy.ALLOW;
        },
      ),
    );
  }
}

/// Custom Dio interceptor to inject WebView cookies into outgoing requests.
class WebViewCookieInterceptor extends Interceptor {
  @override
  void onRequest(
      RequestOptions options, RequestInterceptorHandler handler) async {
    final cookieManager = CookieManager.instance();
    final cookies =
        await cookieManager.getCookies(url: WebUri.uri(options.uri));
    final cookieHeader =
        cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');
    if (cookieHeader.isNotEmpty) {
      options.headers['cookie'] = cookieHeader;
    }
    handler.next(options);
  }
}
