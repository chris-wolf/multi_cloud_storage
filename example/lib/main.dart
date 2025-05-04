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
                          redirectUri: '', accessToken: 'sl.u.AFtzdsxBRBiP9IQxSSXbXvAJXgQ9t5fvGMsUdIq8Q6uy-fEn7eTGr5TjUydx13vzLdi4gCIIFfL74LELtoCTrMTjP_Rcf4ca59NER8629H090VUXQ0e_JWJPa1gB4SgHIDlZQne1pOaYSVwFlhSXJ2-5a3Mpg3cy9JIpyH4QVLzGl6TaLhdNZSCwW-I2zOBpzEB9gfZWJCyTCAQJfvelL231Sz6vxqUwre-ip3cVCnKU4SrnYzeScic_Pf7A14qQoM0p6VM6wgtcrYQ7yGgM9TrGQl9ff5qF5NaMrejpT8xeMKT10h-z4lMG8j1nRLaOQaNz3eG8pww_MRqrS9t6jdJXACvuKlsV8YAM7mmprIV1gGF6WON2c_199qL-Jwz-2ezKG8daGCIoHXwPKC_rmXsqrBpgW-JSJd5mbE-fYFJznvUl8tp4wuE2dPer3AIYgSWw7hxVZ0bqtDXSJs0UZN_5DpIk-osMkvIEkfU1w2d-_5C0YLsRRCgsFCGM3DupHduUiCGlaemRveYRb4JLZv1WOSdq3rTPNeFdi3J9MLXNzTJBicekYsEeelC6qHNGEqNNZBeZ_S8SgL5Vu-Wt1XYVT70wNZdPQE3irC63ArNU8Ij_900KhaeTyEbPoyhZ-pFOkpXIDQe7Z6pWHqcSMBnOVJL6eLOlXD_ZPJK4jhgxAIa-1asqZkID0TaV1_42ZYjtxEfvsM9HyeCw8Aa0KGGWnuY0puMII780bAYRoidIVxnQHHfKe_Tlohu8iLVil5J0i8yaJtwB9sbvf22DPBUHh_JggMq_rHs_d_SS3SvHFncZZMsjDduMm9aNvIOXYiC8yOexgtVCVEwS1fvtfehYt88Np_S1fFx9dDTeo3Gbr2Pas5o-YYpHnWV_AoBhmOa4vadsENXWaaQ6KE9xpwzA6z_-v5jzrRemLPAZTWJSPXbTY2KqLmyWaF2pFaIaoaN_LLrLkc6NQPXs_PhETcO4-i_eqAwZa0zt_AEoG3bbaMnbsyUKZyN73DOqv54S2b3fcxKXLS4iKY1ofGE9dCyH0KDIvzjifp5pGBg-RJ4MMe5dTwy4DovqB9Li5uDEV6ncJ0_tVciAR2boJa127ZyqcngMK7T9ZgEZ4K78ILy7M3z8LwK7-rbfHPkuvF0D2GB0UdPSg52ba0Ha7_Z7Nl0vOlKH4fkbJU_CCsQCYCsJGcU0Ea-_f6Weq6P6pkgPeipKlnCNSwvz-1esikF7MRs0l4S3592CAkLQVfg6ah9cZGj6xEhr7ThWCB4VR2dM1O59Jud8DMKyQVxWjwARCfBG8sYOgDklCl2o9KIdngTh9w');
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
