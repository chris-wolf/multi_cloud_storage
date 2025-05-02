import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:multi_cloud_storage/CloudStorageProvider.dart';
import 'package:multi_cloud_storage/dropbox_provider.dart';
import 'package:multi_cloud_storage/google_drive_provider.dart';
import 'package:multi_cloud_storage/onedrive_provider.dart';

void main() {
  runApp(const CloudStorageExample());
}

class CloudStorageExample extends StatefulWidget {
  const CloudStorageExample({super.key});

  @override
  State<CloudStorageExample> createState() => _CloudStorageExampleState();
}

class _CloudStorageExampleState extends State<CloudStorageExample> {

  CloudStorageProvider? cloudStorageProvider;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      builder: (context, builder) {
        return Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ElevatedButton(
                  onPressed: () {
                    DropboxProvider.connect(
                        appKey: 'u7rt606k8ti1ygu',
                        appSecret: 'p8iocw8zu14i2h2', redirectUri: '');
                  },
                  child: Text('Dropbox'),
                ),
                ElevatedButton(
                  onPressed: () {
                    OneDriveProvider.connect(
                        clientId: '7e4acdbb-4fb2-4964-85d7-d38c176ff5f9', redirectUri: '', clientSecret: '', context: context);
                  },
                  child: Text('Ondrive'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final provider = await GoogleDriveProvider.connect();
                    if (provider != null) {
                      cloudStorageProvider = provider as CloudStorageProvider?;
                    }
                  },
                  child: Text('Google Drive'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
