import 'package:flutter/material.dart';
import 'package:multi_cloud_storage/cloud_storage_provider.dart';
import 'package:multi_cloud_storage/dropbox_provider.dart';
import 'package:multi_cloud_storage/google_drive_provider.dart';
import 'package:multi_cloud_storage/multi_cloud_storage.dart';
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

class _CloudStorageExampleState extends State<CloudStorageExample> {

  CloudStorageProvider? cloudStorageProvider;


  @override
  void initState() {
    MultiCloudStorage.cloudAccess = CloudAccessType.appStorage;
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
                    child: Text('Dropbox'),
                    onPressed: () async {
                      final provider = await MultiCloudStorage.connectToDropbox(
                          appKey: '9ug7o5897zndmq0',
                          appSecret: 'up42moponx9qkbz',
                          redirectUri: '', accessToken: 'sl.u.AFuyaXaxQST3P78Oau0M31t-7e3gPDjt3RNTybzxg_lwMaprZt9adta8-EQjb8XHtwSyhoCp1mDWoju87oxxuBPjyvJvoQM9z7La6MoYt_rSHbPlJQ6wYydm2pQo_SmWDmD_cNrlSKE1Kuabs51hOLbBQJu5Ed8nPXwrtjFMAHb1ApGwK1iJcSOyTISrWbH0dLdzL7uuVjG87iHUMMCNjbEbTiI0aGpFMzK5b8Nfn71W3A0nrRQ1zVxTeTQ4c9SvYYQBt6utixdUZ4BA1IPfsruBnWa_xZZmf0p6P9TgIPRm6Fshl-MztMwaE49OBcpZY7I1HfWSoUuaFdIz-CphDdidYWQEZiuYpcPF1zNozf2HYfNtxgvHgVOAGJJ5jCR55O4wXXl3Zmk1hGEXWruV99fZmIRSZzRXgEhjxiPV3NqaU4UrDkddtQRb0ZfNrEtgJ41zjAgZue9P_HJ6zVb8G4GK7c3Lo4d1QA6Ayr9qZEv3Q-CmytEQPJq7P0XeXBKkGQRhO8WKz8I6oY2g0T15zQvKeVOgnMc7PMneIhMQFuirQXFYxqyxmZDj8WXUh6ceOabSV6LKC9ZwrPhViq1vEg9FwsJU3QH9TlG6sBfFLtGJl5Psuq4QRUHVyyidspJ-dmO5PmxucYXSdBc2cVLOobnNMFFAGCGZYW-CsRdqXjvCOsfDuSGv6ZaeeJ2Vzed8VIrPv7mJ5tR3z11-BBfjZVlAsXd4fWlK0Q7BPZDIvP1fpd4OSZqkfNjw88n4QqsYZiqzLE0KO1yaXg2kI-U2AlUaVM2PnNno9CmILslfLJ93Nb7F87HHNbSlLTIPDmsL8l9uhm63mrCDdAIAqfOjxPmP4SB1Hbg3Ic2NgKvXglt51LhDWhruvAe69Ynd4QW_IxTRrpY93yRQ40CCCzfAAwUALLCKhu7xtRpTxAmf1cX0yn9UHYRA2mJJWwzvpE2rrTtwve-2vVlswVnTniU0P7RoNnKKLsJCVYjSXjsqi2JfkoYAoQ-JOTQd-ewzuR4qhE-HiwOhG8rnXKH4_kTPy7Nptj86ovSb0ssKrTDfzfclf81z149pSE05mvd0OT3rVfuLoQa9RwHwGCzxQyiPYoxUr41-sYlzDftm-douEXYUCjEoBFseCgHd1-Lvk9UIDPWoEL4icLc0M67r-M_cD8vUc6AlDkGeABcGRV93ihMQJMAz8UiKtwFQpiPoTHc3Uw1SCW6duN1BSTjSDohDS28zXNmvtyaCrf99nbapBG-08MJS6hwyRGXECrmsFsgGsAhvM46vLq2ErzMJHjkFMUhR7d7DXjvoiaV9TEprnvkjDQ');
                      // https://www.dropbox.com/developers/apps
                      if (provider != null) {
                        openExplorer(context, provider);
                      }
                    },
                  ),
                  ElevatedButton(
                    child: Text('Onedrive'),
                    onPressed: () async  {
                      final provider = await MultiCloudStorage.connectToOneDrive(
                          clientId: '474a6523-7bc2-420c-90d3-f355d9c82011',
                          redirectUri: 'https://login.microsoftonline.com/common/oauth2/nativeclient',
                          context: context);
                      if (provider != null) {
                        openExplorer(context, provider);
                      }
                    },
                  ),
                  ElevatedButton(
                    onPressed: () async {
                      final provider = await MultiCloudStorage.connectToGoogleDrive(); // app registration required before this works: https://console.cloud.google.com/auth/overview?inv=1&invt=AbwVjA&project=serious-mariner-457313-i7
                      if (provider != null) {
                        openExplorer(context, provider);
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

  void openExplorer(BuildContext context, CloudStorageProvider provider) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (context) => CloudStorageExplorerPage(cloudStorageProvider: provider),
    ));
  }
}
