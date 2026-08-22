import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:multi_cloud_storage_platform_interface/cloud_storage_provider.dart';

export 'package:multi_cloud_storage_platform_interface/cloud_storage_provider.dart';
export 'package:multi_cloud_storage_platform_interface/exceptions/no_connection_exception.dart';
export 'package:multi_cloud_storage_platform_interface/exceptions/not_found_exception.dart';
import  'package:multi_cloud_storage/google_drive_provider.dart';
import  'package:multi_cloud_storage/google_drive_provider_desktop.dart';
import 'package:multi_cloud_storage/onedrive_provider.dart';

import 'dropbox_provider.dart';

class MultiCloudStorage {
  static CloudAccessType cloudAccess = CloudAccessType.appStorage;

  static Future<CloudStorageProvider?> connectToDropbox(
          {required String appKey,
          required String appSecret,
          required String redirectUri,
          bool forceInteractive = false,
          BuildContext? context}) =>
      DropboxProvider.connect(
          appKey: appKey,
          appSecret: appSecret,
          redirectUri: redirectUri,
          forceInteractive: forceInteractive,
          context: context);

  static Future<CloudStorageProvider?> connectToGoogleDrive(
          {bool forceInteractive = false,
          List<String>? scopes,
          String? serverClientId,
            String? clientSecret,
            int redirectPort = 8000}) {
      if (Platform.isWindows || Platform.isLinux) {
        return GoogleDriveProviderDesktop.connect(
              forceInteractive: forceInteractive,
              scopes: scopes,
              serverClientId: serverClientId,
              clientSecret: clientSecret,
              redirectPort: redirectPort);
      } else {
        return GoogleDriveProvider.connect(
            forceInteractive: forceInteractive,
            scopes: scopes,
            serverClientId: serverClientId,
            clientSecret: clientSecret,
            redirectPort: redirectPort);
      }
  }


  static Future<CloudStorageProvider?> connectToOneDrive({
    required String clientId,
    required String redirectUri,
    required BuildContext context,
    String? scopes,
  }) =>
      OneDriveProvider.connect(
          clientId: clientId,
          redirectUri: redirectUri,
          context: context,
          scopes: scopes);
}

enum CloudAccessType { appStorage, fullAccess }
