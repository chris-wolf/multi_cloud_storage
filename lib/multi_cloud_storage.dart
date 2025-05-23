import 'package:flutter/cupertino.dart';
import 'package:multi_cloud_storage/google_drive_provider.dart';
import 'package:multi_cloud_storage/onedrive_provider.dart';

import 'cloud_storage_provider.dart';
import 'dropbox_provider.dart';

class MultiCloudStorage {
  static CloudAccessType cloudAccess = CloudAccessType.appStorage;

  static Future<CloudStorageProvider?> connectToDropbox(
          {required String appKey,
          required String appSecret,
          required String redirectUri,
          String? accessToken}) =>
      DropboxProvider.connect(
          appKey: appKey,
          appSecret: appSecret,
          redirectUri: redirectUri,
          accessToken: accessToken);

  static Future<CloudStorageProvider?> connectToGoogleDrive() =>
      GoogleDriveProvider.connect();

  static Future<CloudStorageProvider?> connectToOneDrive({
    required String clientId,
    required String redirectUri,
    required BuildContext context,
  }) =>
      OneDriveProvider.connect(
          clientId: clientId, redirectUri: redirectUri, context: context);
}

enum CloudAccessType { appStorage, fullAccess }
