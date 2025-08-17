import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_onedrive/flutter_onedrive.dart';
import 'package:flutter_onedrive/token.dart';
import 'package:http/http.dart' as http;
import 'cloud_storage_provider.dart';
import 'exceptions/no_connection_exception.dart';
import 'multi_cloud_storage.dart';
import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'exceptions/not_found_exception.dart';

class OneDriveProvider extends CloudStorageProvider {
  late OneDrive client;
  bool _isAuthenticated = false;
  final String clientId;
  final String redirectUri;
  final BuildContext context;

  /// Private constructor to ensure a provider is created via the static [connect] method.
  OneDriveProvider._create({
    required this.clientId,
    required this.redirectUri,
    required this.context,
  });

  /// Connects to OneDrive, handling both silent and interactive authentication.
  static Future<OneDriveProvider?> connect({
    required String clientId,
    required String redirectUri,
    required BuildContext context,
    String? scopes,
  }) async {
    // Client ID is mandatory for Azure App registration.
    if (clientId.trim().isEmpty) {
      throw ArgumentError(
          'App registration required: https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade');
    }
    // Provides a fallback native client redirect URI if none is supplied.
    if (redirectUri.isEmpty) {
      redirectUri =
          'https://login.microsoftonline.com/common/oauth2/nativeclient';
    }
    try {
      final provider = OneDriveProvider._create(
          clientId: clientId, redirectUri: redirectUri, context: context);
      // Configure the client with appropriate scopes based on the desired access level.
      provider.client = OneDrive(
        clientID: clientId,
        redirectURL: redirectUri,
        scopes: scopes ??
            "${MultiCloudStorage.cloudAccess == CloudAccessType.appStorage ? OneDrive.permissionFilesReadWriteAppFolder : OneDrive.permissionFilesReadWriteAll} offline_access User.Read Sites.ReadWrite.All",
      );
      // 1. First, attempt to connect silently using a stored token.
      if (await provider.client.isConnected()) {
        provider._isAuthenticated = true;
        debugPrint("OneDriveProvider: Silently connected successfully.");
        return provider;
      }
      // 2. If silent connection fails, fall back to interactive login via a WebView.
      debugPrint(
          "OneDriveProvider: Not connected, attempting interactive login...");
      final bool connected = await provider.client.connect(context);
      if (!context.mounted) return null; // Check if context is still valid
      if (connected == false) {
        debugPrint(
            "OneDriveProvider: Interactive login failed or was cancelled.");
        return null; // User cancelled or login failed.
      }
      provider._isAuthenticated = true;
      debugPrint("OneDriveProvider: Interactive login successful.");
      return provider;
    } on SocketException catch (e) {
      debugPrint('No connection detected.');
      throw NoConnectionException(e.message);
    } catch (e) {
      debugPrint('Exception ${e.toString()}');
      rethrow;
    }
  }

  /// Lists all files and directories at the specified [path].
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
        // Map the OneDrive-specific file objects to the generic CloudFile model.
        return files
            .map((oneDriveFile) => CloudFile(
                path: oneDriveFile.path,
                name: oneDriveFile.name,
                size: oneDriveFile.size,
                modifiedTime:
                    DateTime.now(), // HACK: SDK does not provide this field.
                isDirectory: oneDriveFile.isFolder))
            .toList();
      },
      operation: 'listFiles at $path',
    );
  }

  /// Downloads a file from a [remotePath] to a [localPath] on the device.
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

        if (response.statusCode == 404) {
          throw NotFoundException(response.message ?? response.toString());
        }
        if (response.message?.contains('SocketException') ?? false) {
          throw NoConnectionException(response.message ?? response.toString());
        }
        final file = File(localPath);
        if (response.bodyBytes == null) {
          throw Exception(response.message);
        } else {
          await file.writeAsBytes(response.bodyBytes!);
        }
        return localPath; // Return local path on success.
      },
      operation: 'downloadFile from $remotePath',
    );
  }

  /// Uploads a file from a [localPath] to a [remotePath] in OneDrive.
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
        // The `isAppFolder` flag directs the upload to the special "App Root" folder.
        final response = await client.push(bytes, remotePath,
            isAppFolder:
                MultiCloudStorage.cloudAccess == CloudAccessType.appStorage);
        if (response.message?.contains('SocketException') ?? false) {
          throw NoConnectionException(response.message ?? response.toString());
        }
        return remotePath; // Return remote path on success.
      },
      operation: 'uploadFile to $remotePath',
    );
  }

  /// Deletes the file or directory at the specified [path].
  @override
  Future<void> deleteFile(String path) {
    return _executeRequest(
      () async {
        final response = await client.deleteFile(path,
            isAppFolder:
                MultiCloudStorage.cloudAccess == CloudAccessType.appStorage);
        if (response.message?.contains('SocketException') ?? false) {
          throw NoConnectionException(response.message ?? response.toString());
        }
      },
      operation: 'deleteFile at $path',
    );
  }

  /// Creates a new directory at the specified [path].
  @override
  Future<void> createDirectory(String path) {
    return _executeRequest(
      () async {
        final response = await client.createDirectory(path,
            isAppFolder:
                MultiCloudStorage.cloudAccess == CloudAccessType.appStorage);
        if (response.message?.contains('SocketException') ?? false) {
          throw NoConnectionException(response.message ?? response.toString());
        }
      },
      operation: 'createDirectory at $path',
    );
  }

  /// File Metadata not supported since flutter_onedrive does not provide it.
  @override
  Future<CloudFile> getFileMetadata(String path) {
    return _executeRequest(
      () async {
        // The underlying package doesn't have a dedicated metadata fetch method.
        throw UnimplementedError('Get metadata functionality not implemented');
      },
      operation: 'getFileMetadata for $path',
    );
  }

  /// Retrieves the display name of the currently logged-in user.
  @override
  Future<String?> loggedInUserDisplayName() {
    return _executeRequest(
      () async {
        final accessToken = await _getAccessToken();
        if (accessToken.isEmpty) return null;
        // Fetch user profile info from the Microsoft Graph `/me` endpoint.
        final response = await http.get(
          Uri.parse('https://graph.microsoft.com/v1.0/me'),
          headers: {'Authorization': 'Bearer $accessToken'},
        );
        if (response.statusCode != 200) return null;
        final json = jsonDecode(response.body);
        // Prefer `displayName`, but fall back to `userPrincipalName` if it's not available.
        String? name = json['displayName'] as String?;
        if (name?.trim().isEmpty ?? true) {
          name = json['userPrincipalName'] as String?;
        }
        return name;
      },
      operation: 'loggedInUserDisplayName',
    );
  }

  /// Checks if the current user's authentication token is expired.
  @override
  Future<bool> tokenExpired() async {
    if (!_isAuthenticated) return true;
    try {
      // Check token validity by making a lightweight, authenticated API call.
      // A successful call means the token is valid.
      final _response = await _executeRequest(
        () => client.listFiles(
          '/',
          isAppFolder:
              MultiCloudStorage.cloudAccess == CloudAccessType.appStorage,
        ),
        operation: 'tokenExpiredCheck',
      );
      return false; // Success means token is not expired.
    } catch (e) {
      // Any exception here implies the token is invalid or expired.
      // The error is already logged by _executeRequest.
      return true;
    }
  }

  /// Logs out the current user from the cloud service.
  @override
  Future<bool> logout() async {
    debugPrint("Logging out from OneDrive...");
    final cookieManager = CookieManager.instance();
    if (_isAuthenticated) {
      try {
        // 1. Disconnect the client to clear local tokens.
        await client.disconnect();
        _isAuthenticated = false;
        // 2. Clear all WebView cookies to ensure a fresh login prompt on the next connect attempt.
        await cookieManager.deleteAllCookies();
        debugPrint("OneDrive logout successful and web cookies cleared.");
        return true;
      } catch (error) {
        debugPrint(
          "Error during OneDrive logout.",
        );
        return false;
      }
    }
    // Ensure cookies are cleared even if the client was already disconnected.
    await cookieManager.deleteAllCookies();
    debugPrint(
        "Already logged out from OneDrive, ensuring cookies are cleared.");
    return false;
  }

  /// Generates a shareable link for the file or directory at the [path].
  @override
  Future<Uri?> generateShareLink(String path) {
    return _executeRequest(
      () async {
        final accessToken = await _getAccessToken();
        if (accessToken.isEmpty) {
          debugPrint(
              "OneDriveProvider: No access token available for generating share link.");
          return null;
        }
        // Construct the Microsoft Graph API path to create a share link for the item.
        final encodedPath = Uri.encodeComponent(
            path.startsWith('/') ? path.substring(1) : path);
        final driveItemPath = "/me/drive/root:/$encodedPath:/createLink";

        final response = await http.post(
          Uri.parse("https://graph.microsoft.com/v1.0$driveItemPath"),
          headers: {
            'Authorization': 'Bearer $accessToken',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            "type": "edit",
            "scope": "anonymous"
          }), // Request an editable, public link.
        );
        if (response.statusCode != 200 && response.statusCode != 201) {
          debugPrint(
              "Failed to create shareable link. Status: ${response.statusCode}, Body: ${response.body}");
          return null;
        }
        // Parse the link from the JSON response.
        final json = jsonDecode(response.body);
        final link = json['link']?['webUrl'];
        return link != null ? Uri.parse(link) : null;
      },
      operation: 'generateSharableLink for $path',
    );
  }

  /// Share token is just the share link for OneDrive.
  @override
  Future<String?> getShareTokenFromShareLink(Uri shareLink) async {
    // For OneDrive, the full shareable URL itself acts as the "share token".
    return shareLink.toString();
  }

  /// Downloads a file to [localPath] using a [shareToken].
  /// Wasn't able to make the download work via the microsoft graph api,
  /// therefore this functions uses the shareLink with &download=1 to download the file via a headless browser.
  /// Would be glad if someone could rewrite this to use the microsoft graph api if possible.
  @override
  Future<String> downloadFileByShareToken({
    required String shareToken,
    required String localPath,
  }) async {
    final completer = Completer<String>();
    late HeadlessInAppWebView headlessWebView;
    // Append `?download=1` to the share link to hint at a direct download.
    final initialUrl =
        Uri.parse(shareToken).replace(queryParameters: {'download': '1'});
    debugPrint(
        "Starting headless WebView to resolve download for: $initialUrl");
    headlessWebView = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri.uri(initialUrl)),
        // This callback captures the final download URL after all redirects.
        onDownloadStartRequest: (controller, downloadStartRequest) async {
          final finalUrl = downloadStartRequest.url.toString();
          debugPrint("WebView captured final download URL: $finalUrl");
          if (!completer.isCompleted) {
            completer.complete(finalUrl);
          }
        },
        onReceivedError: (controller, request, error) {
          debugPrint("WebView error: Code ${error.type.name}, Message: ${error.description}");
          if (!completer.isCompleted) {
            completer.completeError(Exception("WebView error: ${error.description}"));
          }
        },
        // Handles cases where the WebView lands on an error page instead of triggering a download.
        onLoadStop: (controller, url) async {
          if (!completer.isCompleted) {
            final pageBody = await controller.getHtml() ?? "";
            if (pageBody.toLowerCase().contains("error") ||
                pageBody.toLowerCase().contains("denied")) {
              completer.completeError(NotFoundException(
                  "WebView navigation ended on an error page. File may not exist or permissions are denied."));
            }
          }
        });
    try {
      await headlessWebView.run();
      // Wait for the download URL to be captured, with a timeout.
      final finalDownloadUrl =
          await completer.future.timeout(const Duration(seconds: 30));
      await headlessWebView.dispose();
      // --- Use Dio with a custom interceptor for the final download ---
      final dio = Dio();
      // This interceptor will attach the cookies gathered by the WebView to the Dio request.
      dio.interceptors.add(WebViewCookieInterceptor());
      debugPrint("Downloading with Dio using WebView cookies and Referer.");
      await dio.download(
        finalDownloadUrl,
        localPath,
        options: Options(
          headers: {
            // Set a common User-Agent and Referer to mimic a browser request.
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36',
            'Referer': shareToken,
          },
        ),
      );
      debugPrint("File successfully downloaded to $localPath");
      return localPath;
    } catch (e) {
      debugPrint("Error during WebView download process");
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
    return _executeRequest(
      () async {
        final accessToken = await _getAccessToken();
        // 1. Resolve the share URL to get the file's stable driveId and itemId.
        final resolvedInfo = await _resolveShareUrlForUpload(shareToken);
        if (resolvedInfo == null) {
          throw Exception(
              'Could not resolve the provided sharing URL for upload.');
        }
        // 2. Construct the Graph API URL to overwrite the file's content using its resolved IDs.
        final uploadUri = Uri.parse(
            'https://graph.microsoft.com/v1.0/drives/${resolvedInfo.driveId}/items/${resolvedInfo.itemId}/content');
        final fileBytes = await File(localPath).readAsBytes();
        // 3. Perform a PUT request with the file bytes to replace the content.
        final uploadResponse = await http.put(
          uploadUri,
          headers: {
            'Authorization': 'Bearer $accessToken',
            'Content-Type':
                'application/octet-stream', // Generic byte stream type.
          },
          body: fileBytes,
        );
        // A 200 or 201 status indicates a successful upload.
        if (uploadResponse.statusCode >= 200 &&
            uploadResponse.statusCode < 300) {
          debugPrint('Successfully uploaded file to shared URL location.');
          return shareToken; // Return the original token on success.
        } else {
          throw Exception(
              'Failed to upload file content. Status: ${uploadResponse.statusCode}, Body: ${uploadResponse.body}');
        }
      },
      operation: 'uploadToSharedUrl: $shareToken',
    );
  }

  /// A robust wrapper for executing all OneDrive API requests.
  /// Handles authentication checks and centralized error logging.
  /// It also detects token expiry errors to update the authentication state.
  Future<T> _executeRequest<T>(
    Future<T> Function() request, {
    required String operation,
  }) async {
    _checkAuth();
    try {
      debugPrint('Executing OneDrive operation: $operation');
      return await request();
    } on SocketException catch (e) {
      debugPrint('No connection detected.');
      throw NoConnectionException(e.message);
    } catch (e) {
      debugPrint('Error during OneDrive operation: $operation');
      // If a 401 Unauthorized or invalid_grant error occurs, the token is likely expired.
      if (e.toString().contains('401') ||
          e.toString().contains('invalid_grant')) {
        _isAuthenticated = false;
        debugPrint(
            'OneDrive token appears to be expired. User re-authentication is required.');
      }
      rethrow; // Rethrow the error to be handled by the calling function.
    }
  }

  /// Throws an exception if the user is not authenticated.
  void _checkAuth() {
    if (!_isAuthenticated) {
      throw Exception(
          'OneDriveProvider: Not authenticated. Call connect() first.');
    }
  }

  /// Retrieves the current access token from the underlying token manager.
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

  /// Encodes a URL into a Base64 string for use in API calls.
  String encodeShareUrl(Uri url) {
    final bytes = utf8.encode(url.toString());
    final base64Str = base64UrlEncode(bytes);
    return base64Str.replaceAll('=', ''); // Remove padding.
  }

  /// Resolves a sharing URL to get the stable drive and item identifiers needed for API calls.
  /// This is crucial because a share link can point to an item on a different user's OneDrive.
  Future<_ResolvedShareInfo?> _resolveShareUrlForUpload(String shareUrl) async {
    final accessToken = await _getAccessToken();
    final String encodedUrl = _encodeShareUrlForGraphAPI(shareUrl);
    // Request `remoteItem` to handle files shared from another user's drive.
    final resolveUri = Uri.parse(
        'https://graph.microsoft.com/v1.0/shares/$encodedUrl/driveItem?\$select=id,driveId,parentReference,remoteItem');
    final response = await http.get(resolveUri, headers: {
      'Authorization': 'Bearer $accessToken',
      'Prefer':
          'redeemSharingLink', // Special header to process the share link.
    });
    if (response.statusCode != 200) {
      debugPrint(
          'Failed to resolve share URL. Status: ${response.statusCode}, Body: ${response.body}');
      return null;
    }
    final json = jsonDecode(response.body);
    // If `remoteItem` exists, the file is on another drive. Use its identifiers.
    final remoteItem = json['remoteItem'];
    if (remoteItem != null &&
        remoteItem['id'] != null &&
        remoteItem['driveId'] != null) {
      debugPrint("Resolved a remote item from another drive.");
      return _ResolvedShareInfo(
          driveId: remoteItem['driveId'], itemId: remoteItem['id']);
    }
    // Otherwise, it's an item on the current user's own drive.
    final String? itemId = json['id'];
    final String? driveId = json['parentReference']?['driveId'];
    if (itemId == null || driveId == null) {
      debugPrint(
          'Could not extract driveId and itemId from resolved share response. Body: ${response.body}');
      return null;
    }
    debugPrint("Resolved an item from the user's own drive.");
    return _ResolvedShareInfo(driveId: driveId, itemId: itemId);
  }

  /// Encodes a sharing URL into the special format required by the Microsoft Graph API.
  /// Format: `u!{base64-encoded-url}`
  /// See: https://learn.microsoft.com/en-us/graph/api/shares-get?view=graph-rest-1.0
  String _encodeShareUrlForGraphAPI(String url) {
    final String base64UrlString = base64Url.encode(utf8.encode(url));
    return 'u!$base64UrlString';
  }
}

/// A helper class to store the resolved Drive ID and Item ID from a share link.
class _ResolvedShareInfo {
  final String driveId;
  final String itemId;

  _ResolvedShareInfo({required this.driveId, required this.itemId});
}

/// A custom Dio interceptor that injects cookies from a `flutter_inappwebview`
/// instance into outgoing HTTP requests. This is essential for authenticated downloads.
class WebViewCookieInterceptor extends Interceptor {
  @override
  void onRequest(
      RequestOptions options, RequestInterceptorHandler handler) async {
    final cookieManager = CookieManager.instance();
    // Get all cookies associated with the request's domain.
    final cookies =
        await cookieManager.getCookies(url: WebUri.uri(options.uri));
    // Format the cookies into a single `Cookie` header string.
    final cookieHeader =
        cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');
    // Add the cookie header to the request if any cookies were found.
    if (cookieHeader.isNotEmpty) {
      options.headers['cookie'] = cookieHeader;
    }
    // Continue with the modified request.
    handler.next(options);
  }
}
