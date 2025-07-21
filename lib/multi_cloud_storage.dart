import 'package:flutter/cupertino.dart';
import 'package:multi_cloud_storage/cloud_storage_provider.dart';
import 'package:multi_cloud_storage/google_drive_provider.dart';
import 'package:multi_cloud_storage/icloud_provider.dart';
import 'package:multi_cloud_storage/onedrive_provider.dart';

import 'dropbox_provider.dart';

class MultiCloudStorage {
  static CloudAccessType cloudAccess = CloudAccessType.appStorage;

  static Future<CloudStorageProvider?> connectToDropbox(
          {required String appKey,
          required String appSecret,
          required String redirectUri,
          bool forceInteractive = false}) =>
      DropboxProvider.connect(
          appKey: appKey,
          appSecret: appSecret,
          redirectUri: redirectUri,
          forceInteractive: forceInteractive);

  static Future<CloudStorageProvider?> connectToGoogleDrive(
          {bool forceInteractive = false}) =>
      GoogleDriveProvider.connect(forceInteractive: forceInteractive);

  static Future<CloudStorageProvider?> connectToIcloud(
          {required String containerId}) =>
      ICloudProvider.connect(containerId: containerId);

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
