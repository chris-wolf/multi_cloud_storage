import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_onedrive/flutter_onedrive.dart';
import 'package:flutter_onedrive/token.dart';
import 'package:http/http.dart' as http;

// Assuming your global logger is accessible via main.dart
import 'cloud_storage_provider.dart';
import 'file_log_output.dart'; // Assuming you have these custom classes
import 'multi_cloud_storage.dart';
import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'not_found_exception.dart';

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

  static Future<OneDriveProvider?> connect(
      {required String clientId,
      required String redirectUri,
      required BuildContext context,
      String? scopes}) async {
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
      scopes: scopes ??
          "${MultiCloudStorage.cloudAccess == CloudAccessType.appStorage ? OneDrive.permissionFilesReadWriteAppFolder : OneDrive.permissionFilesReadWriteAll} offline_access User.Read Sites.ReadWrite.All",
    );

    // 1. First, try to connect silently by checking for an existing token
    final bool alreadyConnected = await provider.client.isConnected();

    if (alreadyConnected) {
      provider._isAuthenticated = true;
      logger.i("OneDriveProvider: Silently connected successfully.");
      return provider;
    }

    // 2. If not connected, proceed with the interactive login
    logger
        .i("OneDriveProvider: Not connected, attempting interactive login...");
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
      if (e.toString().contains('401') ||
          e.toString().contains('invalid_grant')) {
        _isAuthenticated = false;
        logger.w(
            'OneDrive token appears to be expired. User re-authentication is required.');
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
                modifiedTime:
                    DateTime.now(), // OneDrive SDK doesn't provide this
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
  Future<Uri?> generateShareLink(String path) {
    return _executeRequest(
      () async {
        final accessToken = await _getAccessToken();
        if (accessToken.isEmpty) {
          logger.w(
              "OneDriveProvider: No access token available for generating share link.");
          return null;
        }

        final encodedPath = Uri.encodeComponent(
            path.startsWith('/') ? path.substring(1) : path);
        final driveItemPath = "/me/drive/root:/$encodedPath:/createLink";

        final response = await http.post(
          Uri.parse("https://graph.microsoft.com/v1.0$driveItemPath"),
          headers: {
            'Authorization': 'Bearer $accessToken',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({"type": "edit", "scope": "anonymous"}),
        );

        if (response.statusCode != 200 && response.statusCode != 201) {
          logger.e(
              "Failed to create shareable link. Status: ${response.statusCode}, Body: ${response.body}");
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

    // Get the InAppWebView CookieManager instance
    final cookieManager = CookieManager.instance();

    if (_isAuthenticated) {
      try {
        // 1. Disconnect the client (clears local tokens)
        await client.disconnect();
        _isAuthenticated = false;

        // 2. Clear all webview cookies to force a fresh login prompt next time
        await cookieManager.deleteAllCookies();

        logger.i("OneDrive logout successful and web cookies cleared.");
        return true;
      } catch (error, stackTrace) {
        logger.e("Error during OneDrive logout.",
            error: error, stackTrace: stackTrace);
        return false;
      }
    }

    // Also clear cookies even if not authenticated, just to be safe
    await cookieManager.deleteAllCookies();
    logger.d("Already logged out from OneDrive, ensuring cookies are cleared.");
    return false;
  }

  Future<String> _getAccessToken() async {
    final accessToken = await DefaultTokenManager(
      tokenEndpoint: OneDrive.tokenEndpoint,
      clientID: client.clientID,
      redirectURL: client.redirectURL,
      scope: client.scopes,
    ).getAccessToken();

    if (accessToken == null || accessToken.isEmpty) {
      throw Exception(
          'Failed to retrieve a valid access token. Please re-authenticate.');
    }
    return accessToken;
  }

  @override
  Future<bool> tokenExpired() async {
    if (!_isAuthenticated) return true;
    try {
      // Perform a lightweight, authenticated call to check token validity
      await _executeRequest(
        () => client.listFiles(
          '/',
          isAppFolder:
              MultiCloudStorage.cloudAccess == CloudAccessType.appStorage,
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
  Future<String?> getShareTokenFromShareLink(Uri shareLink) async {
    return shareLink.toString(); // use full url as shareToken
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
        final accessToken = await _getAccessToken();
        if (accessToken.isEmpty) return null;

        final response = await http.get(
          Uri.parse('https://graph.microsoft.com/v1.0/me'),
          headers: {'Authorization': 'Bearer $accessToken'},
        );
        if (response.statusCode != 200) return null;
        final json = jsonDecode(response.body);
        String? name = json['displayName'] as String?;
        if (name?.trim().isEmpty ?? true) {
          name = json['userPrincipalName'] as String?;
        }
        return name;
      },
      operation: 'loggedInUserDisplayName',
    );
  }

  @override
  Future<String> downloadFileByShareToken({
    required String shareToken,
    required String localPath,
  }) async {
    final completer = Completer<String>();
    late HeadlessInAppWebView headlessWebView;

    final initialUrl =
        Uri.parse(shareToken).replace(queryParameters: {'download': '1'});

    logger.i("Starting headless WebView to resolve download for: $initialUrl");

    headlessWebView = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri.uri(initialUrl)),
        onDownloadStartRequest: (controller, downloadStartRequest) async {
          final finalUrl = downloadStartRequest.url.toString();
          logger.i("WebView captured final download URL: $finalUrl");
          if (!completer.isCompleted) {
            completer.complete(finalUrl);
          }
        },
        onLoadError: (controller, url, code, message) {
          logger.e("WebView error: Code $code, Message: $message");
          if (!completer.isCompleted) {
            completer.completeError(Exception("WebView error: $message"));
          }
        },
        onLoadStop: (controller, url) async {
          if (!completer.isCompleted) {
            final pageBody = await controller.getHtml() ?? "";
            if (pageBody.toLowerCase().contains("error") ||
                pageBody.toLowerCase().contains("denied")) {
              if (pageBody.contains('-1007')) {
                completer.completeError(NotFoundException(
                    "WebView navigation ended on an error page."));
              } else {
                completer.completeError(
                    Exception("WebView navigation ended on an error page."));
              }
            }
          }
        });

    try {
      await headlessWebView.run();
      final finalDownloadUrl =
          await completer.future.timeout(const Duration(seconds: 30));
      await headlessWebView.dispose();

      // --- FINAL DIO DOWNLOAD ---
      // Create a Dio instance and add our custom interceptor.
      final dio = Dio();
      dio.interceptors.add(WebViewCookieInterceptor());

      logger.i("Downloading with Dio using WebView cookies and Referer.");

      // This request will now have User-Agent, Referer, AND Cookies.
      final result = await dio.download(
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

      logger.i("File successfully downloaded to $localPath");
      return localPath;
    } catch (e, stackTrace) {
      logger.e("Error during WebView download process",
          error: e, stackTrace: stackTrace);
      await headlessWebView.dispose();
      rethrow;
    }
  }

  // The _ResolvedShareInfo class from Section 3 is reused.
// The _resolveShareUrl function needs a slight modification to include remoteItem.

  Future<_ResolvedShareInfo?> _resolveShareUrlForUpload(String shareUrl) async {
    final accessToken = await _getAccessToken();
    final String encodedUrl = _encodeShareUrlForGraphAPI(shareUrl);
    // Request remoteItem to handle cross-drive scenarios
    final resolveUri = Uri.parse(
        'https://graph.microsoft.com/v1.0/shares/$encodedUrl/driveItem?\$select=id,driveId,parentReference,remoteItem');

    final response = await http.get(resolveUri, headers: {
      'Authorization': 'Bearer $accessToken',
      'Prefer': 'redeemSharingLink',
    });

    if (response.statusCode != 200) {
      logger.e(
          'Failed to resolve share URL. Status: ${response.statusCode}, Body: ${response.body}');
      return null;
    }

    final json = jsonDecode(response.body);

    // Check for remoteItem first, as it indicates a shared-in file from another drive.
    final remoteItem = json['remoteItem'];
    if (remoteItem != null &&
        remoteItem['id'] != null &&
        remoteItem['driveId'] != null) {
      logger.i("Resolved a remote item from another drive.");
      return _ResolvedShareInfo(
        driveId: remoteItem['driveId'],
        itemId: remoteItem['id'],
      );
    }

    // Fallback for items in the user's own drive.
    final String? itemId = json['id'];
    // CORRECTED LINE: Access driveId from within parentReference.
    final String? driveId = json['parentReference']?['driveId'];

    if (itemId == null || driveId == null) {
      logger.e(
          'Could not extract driveId and itemId from resolved share response. Body: ${response.body}');
      return null;
    }

    logger.i("Resolved an item from the user's own drive.");
    return _ResolvedShareInfo(driveId: driveId, itemId: itemId);
  }

  @override
  Future<String> uploadFileByShareToken({
    required String localPath,
    required String shareToken,
    Map<String, dynamic>? metadata,
  }) {
    return _executeRequest(
      () async {
        final accessToken = await _getAccessToken();
        // Step 1: Resolve the sharing URL to get the correct, stable identifiers.
        // This version of resolve handles the remoteItem facet.
        final resolvedInfo = await _resolveShareUrlForUpload(shareToken);
        if (resolvedInfo == null) {
          throw Exception(
              'Could not resolve the provided sharing URL for upload.');
        }

        // Step 2: Prepare and execute the PUT request to overwrite the file content.
        final uploadUri = Uri.parse(
            'https://graph.microsoft.com/v1.0/drives/${resolvedInfo.driveId}/items/${resolvedInfo.itemId}/content');

        final fileBytes = await File(localPath).readAsBytes();

        final uploadResponse = await http.put(
          uploadUri,
          headers: {
            'Authorization':
                'Bearer $accessToken', // Replace with actual token retrieval
            // Use a generic content type, or determine it from the file extension.
            'Content-Type': 'application/octet-stream',
          },
          body: fileBytes,
        );

        // A successful upload returns a 200 or 201 status code.
        if (uploadResponse.statusCode >= 200 &&
            uploadResponse.statusCode < 300) {
          logger.i('Successfully uploaded file to shared URL location.');
          // Return the original shareUrl to signify success on the target resource.
          return shareToken;
        } else {
          throw Exception(
              'Failed to upload file content. Status: ${uploadResponse.statusCode}, Body: ${uploadResponse.body}');
        }
      },
      operation: 'uploadToSharedUrl: $shareToken',
    );
  }

  /// Encodes a sharing URL into the format required by the Microsoft Graph API's /shares endpoint.
  /// See: https://learn.microsoft.com/en-us/graph/api/shares-get?view=graph-rest-1.0
  String _encodeShareUrlForGraphAPI(String url) {
    // Use the built-in URL-safe Base64 encoder. It omits padding correctly.
    final String base64UrlString = base64Url.encode(utf8.encode(url));
    return 'u!$base64UrlString';
  }
}

// Helper class to hold the resolved identifiers
class _ResolvedShareInfo {
  final String driveId;
  final String itemId;

  _ResolvedShareInfo({required this.driveId, required this.itemId});
}

// This custom interceptor bridges the WebView's cookies to Dio's requests.
class WebViewCookieInterceptor extends Interceptor {
  @override
  void onRequest(
      RequestOptions options, RequestInterceptorHandler handler) async {
    // **CORRECTION IS HERE**: Change .instance to .instance()
    final cookieManager = CookieManager.instance();

    // Get the cookies for the request's URL.
    final cookies =
        await cookieManager.getCookies(url: WebUri.uri(options.uri));

    // Format the cookies into a single string.
    final cookieHeader =
        cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');

    // Add the cookie header to the request if it's not empty.
    if (cookieHeader.isNotEmpty) {
      options.headers['cookie'] = cookieHeader;
    }

    // Continue with the request.
    handler.next(options);
  }
}
