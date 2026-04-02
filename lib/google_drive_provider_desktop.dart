import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in_all_platforms/google_sign_in_all_platforms.dart'
    as all_platforms;
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:http/http.dart' as client;
import 'package:http/retry.dart';
import 'package:multi_cloud_storage/exceptions/no_connection_exception.dart';
import 'google_drive_provider.dart';

class GoogleDriveProviderDesktop extends GoogleDriveProvider {
  /// The authenticated Google Drive API client.
  static GoogleDriveProviderDesktop? _instance;
  static all_platforms.GoogleSignIn? _googleSignIn;

  // This one is correct because it explicitly calls super.internal()
  GoogleDriveProviderDesktop.internal() : super.internal();

  static GoogleDriveProviderDesktop? get instance => _instance;
  String? _accessToken;

  /// Connects to Google Drive, authenticating the user.
  ///
  /// This method handles the Google Sign-In flow. It will attempt to sign in
  /// silently first, unless [forceInteractive] is true.
  ///
  /// [scopes] a list of additional Google API scopes to request.
  /// The default scopes are `drive.DriveApi.driveAppdataScope` or
  /// `drive.DriveApi.driveScope` depending on `MultiCloudStorage.cloudAccess`.
  /// [serverClientId] The server client ID for requesting an ID token if you
  /// need to authenticate to a backend server.
  ///
  /// Returns a connected [GoogleDriveProvider] instance on success, or null on failure/cancellation.
  static Future<GoogleDriveProvider?> connect({
    bool forceInteractive = false,
    List<String>? scopes,
    // NEW: Client ID and Secret are required for the desktop flow.
    String? serverClientId,
    String? clientSecret, // Secret is needed for the web app flow on desktop
    int redirectPort = 8000, // Default port used by the package
  }) async {
    debugPrint("connect Google Drive,  forceInteractive: $forceInteractive");
    // Return existing instance if already connected and not forcing a new interactive session.
    if (_instance != null && _instance!.isAuthenticated && !forceInteractive) {
      return _instance;
    }
    if (scopes != null) {
      GoogleDriveProvider.scopes = scopes;
    }
    try {
      // 1. CONFIGURE: The new package uses a parameters object for configuration.
      final signInParams = all_platforms.GoogleSignInParams(
        clientId: serverClientId,
        clientSecret: clientSecret, // May be null for other client types
        scopes: GoogleDriveProvider.scopes,
        redirectPort: redirectPort,
      );

      // 2. INITIALIZE: Create the GoogleSignIn instance with the params.
      _googleSignIn ??= all_platforms.GoogleSignIn(params: signInParams);

      // 3. SIGN IN: The sign-in flow is simplified.
      // signIn() attempts offline (silent) first, then falls back to online.
      // signInOnline() forces the interactive flow.
      all_platforms.GoogleSignInCredentials? credentials;
      if (forceInteractive) {
        credentials = await _googleSignIn!.signInOnline();
      } else {
        credentials = await _googleSignIn!.signIn();
      }

      if (credentials == null) {
        debugPrint('User cancelled Google Sign-In process.');
        return null;
      }

      // 4. GET CLIENT: The authenticatedClient getter is now used.
      // The separate requestScopes() call is no longer needed as scopes are
      // handled during the signIn process.
      final http.Client? client = await _googleSignIn!.authenticatedClient;

      if (client == null) {
        debugPrint('Failed to get authenticated Google client.');
        await signOut();
        return null;
      }

      // Wrap the client in a RetryClient to handle transient network errors (5xx).
      final retryClient = RetryClient(
        client,
        retries: 3,
        when: (response) => {500, 502, 503, 504}.contains(response.statusCode),
        onRetry: (request, response, retryCount) => debugPrint(
            'Retrying request to ${request.url} (Retry #$retryCount)'),
      );

      // Create or update the singleton instance with the authenticated client.
      final provider = _instance ?? GoogleDriveProviderDesktop.internal();
      provider.driveApi = drive.DriveApi(retryClient);
      provider.isAuthenticated = true;
      provider._accessToken = credentials.accessToken;
      _instance = provider;
      debugPrint('Google Drive user signed in successfully.');
      return _instance;
    } on SocketException catch (e) {
      debugPrint(
          'No internet connection during Google Drive sign-in: ${e.message}');
      throw NoConnectionException(e.message);
    } catch (error) {
      debugPrint(
        'Error occurred during the Google Drive connect process: $error',
      );
      if (error is PlatformException && error.code == 'network_error') {
        throw NoConnectionException(error.toString());
      }
      await signOut(); // Clean up on error.
      return null;
    }
  }

  @override
  Future<String?> loggedInUserDisplayName() async {
    try {
      final response = await client.get(
        Uri.parse('https://www.googleapis.com/oauth2/v3/userinfo'),
      );

      if (response.statusCode == 200) {
        final userInfo = jsonDecode(response.body);
        return userInfo['name'];
      } else {
        debugPrint(
            'Failed to fetch user info. Status: ${response.statusCode}, Body: ${response.body}');
      }
    } catch (e) {
      debugPrint('Error fetching user info: $e');
    }
    return null;
  }

  /// Signs the user out of Google and disconnects the app.
  static Future<void> signOut() async {
    try {
      await _googleSignIn?.signOut();
    } catch (error) {
      debugPrint('Failed to sign out or disconnect from Google. $error');
    } finally {
      // Clear all state regardless of success or failure.
      _googleSignIn = null;
      if (_instance != null) {
        _instance!.isAuthenticated = false;
        _instance = null;
      }
      debugPrint('User signed out from Google Drive.');
    }
  }

  /// A helper to handle auth errors by reconnecting and retrying the request.
  ///
  /// This is called when a 401/403 error occurs, indicating an expired token.
  /// It attempts a silent reconnect to refresh the token and then retries the
  /// original function `request`.
  @override
  Future<T> handleAuthErrorAndRetry<T>(
      Future<T> Function() request, Object error, StackTrace stackTrace) async {
    debugPrint('Authentication error occurred. Attempting to reconnect...');
    isAuthenticated = false;
    // Silently try to reconnect to refresh the auth token.
    final reconnectedProvider = await GoogleDriveProviderDesktop.connect();
    if (reconnectedProvider != null && reconnectedProvider.isAuthenticated) {
      debugPrint('Successfully reconnected. Retrying the original request.');
      // Retry the original request closure.
      return await request();
    } else {
      debugPrint(
          'Failed to reconnect after auth error. Throwing original error.');
      // If reconnection fails, rethrow the original error to the caller.
      throw error;
    }
  }

  @override
  Future<String?> getAccessToken() async {
    return _accessToken;
  }
}

Future<GoogleDriveProvider?> connectToGoogleDrive(
        {bool forceInteractive = false,
        List<String>? scopes,
        String? serverClientId,
        String? clientSecret,
        int redirectPort = 8000}) =>
    GoogleDriveProviderDesktop.connect(
        forceInteractive: forceInteractive,
        scopes: scopes,
        serverClientId: serverClientId,
        clientSecret: clientSecret,
        redirectPort: redirectPort);
