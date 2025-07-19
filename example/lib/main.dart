import 'dart:io';

import 'package:flutter/material.dart';
import 'package:multi_cloud_storage/cloud_storage_provider.dart';
import 'package:multi_cloud_storage/multi_cloud_storage.dart';

import 'CloudStorageExplorer.dart';

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
  void initState() {
    super.initState();
    MultiCloudStorage.cloudAccess = CloudAccessType.appStorage;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (Platform.isIOS || Platform.isMacOS)
                  ElevatedButton(
                    child: Text('iCloud'),
                    onPressed: () async {
                      final provider = await MultiCloudStorage.connectToIcloud(
                          containerId: '');
                      if (provider != null && context.mounted) {
                        openExplorer(context, provider);
                      }
                    },
                  ),
                ElevatedButton(
                  child: Text('Dropbox'),
                  onPressed: () async {
                    final provider = await MultiCloudStorage.connectToDropbox(
                        appKey: 'eh6ej2fozvdi5xr',
                        appSecret: 'oe6cdadvla68x5h',
                        redirectUri:
                            'sample://auth.my.app'); // App registration required: https://www.dropbox.com/developers/apps
                    if (provider != null && context.mounted) {
                      openExplorer(context, provider);
                    }
                  },
                ),
                ElevatedButton(
                  child: Text('Onedrive'),
                  onPressed: () async {
                    final provider = await MultiCloudStorage.connectToOneDrive(
                        clientId: '',
                        redirectUri: '',
                        context:
                            context); // App registration required: https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade
                    if (provider != null && context.mounted) {
                      openExplorer(context, provider);
                    }
                  },
                ),
                ElevatedButton(
                  onPressed: () async {
                    final provider = await MultiCloudStorage
                        .connectToGoogleDrive(); // App registration required: https://console.cloud.google.com/apis/credentials
                    if (provider != null && context.mounted) {
                      openExplorer(context, provider);
                    }
                  },
                  child: Text('Google Drive'),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  void openExplorer(BuildContext context, CloudStorageProvider provider) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (context) =>
          CloudStorageExplorerPage(cloudStorageProvider: provider),
    ));
  }
}
