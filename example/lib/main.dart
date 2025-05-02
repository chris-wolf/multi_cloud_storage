import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:multi_cloud_storage/multi_cloud_storage.dart';

void main() {
  runApp(const CloudStorageExample());
}

class CloudStorageExample extends StatefulWidget {
  const CloudStorageExample({super.key});

  @override
  State<CloudStorageExample> createState() => _CloudStorageExampleState();
}

class _CloudStorageExampleState extends State<CloudStorageExample> {
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
                    MultiCloudStorage.loginDropbox(context,
                        appKey: 'u7rt606k8ti1ygu',
                        appSecret: 'p8iocw8zu14i2h2');
                  },
                  child: Text('Dropbox'),
                ),
                ElevatedButton(
                  onPressed: () {
                    MultiCloudStorage.loginOneDrive(context,
                        clientId: '7e4acdbb-4fb2-4964-85d7-d38c176ff5f9', redirectUrl: '');
                  },
                  child: Text('Ondrive'),
                ),
                ElevatedButton(
                  onPressed: () {
                    MultiCloudStorage.loginGoogleDrive(context);
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
