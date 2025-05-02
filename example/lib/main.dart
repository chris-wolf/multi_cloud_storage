import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:multi_cloud_storage/cloud_storage_provider.dart';
import 'package:multi_cloud_storage/dropbox_provider.dart';
import 'package:multi_cloud_storage/google_drive_provider.dart';
import 'package:multi_cloud_storage/onedrive_provider.dart';

import 'CloudStorageExplorer.dart';

void main() {
  runApp(const CloudStorageExample());
}

class CloudStorageExample extends StatefulWidget {
  const CloudStorageExample({super.key});

  @override
  State<CloudStorageExample> createState() => _CloudStorageExampleState();
}

enum CloudAccess {
  appStorage,
  fullAccess
}

class _CloudStorageExampleState extends State<CloudStorageExample> {

  CloudStorageProvider? cloudStorageProvider;


  @override
  void initState() {
    CloudStorageProvider.cloudAccess = CloudAccessType.appStorage;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ElevatedButton(
                    onPressed: () {
                      DropboxProvider.connect(
                          appKey: 'u7rt606k8ti1ygu',
                          appSecret: 'p8iocw8zu14i2h2',
                          redirectUri: '');
                    },
                    child: Text('Dropbox'),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      OneDriveProvider.connect(
                          clientId: '7e4acdbb-4fb2-4964-85d7-d38c176ff5f9',
                          redirectUri: '',
                          clientSecret: '',
                          context: context);
                    },
                    child: Text('Onedrive'),
                  ),
                  ElevatedButton(
                    onPressed: () async {
                      final provider = await GoogleDriveProvider.login(); // app registration required before this works: https://console.cloud.google.com/auth/overview?inv=1&invt=AbwVjA&project=serious-mariner-457313-i7
                      if (provider != null) {
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (context) => CloudStorageExplorerPage(cloudStorageProvider: provider),
                        ));
                      }
                    },
                    child: Text('Google Drive'),
                  ),
                ],
              ),
            );
          }
        ),
      ),
    );
  }
}
