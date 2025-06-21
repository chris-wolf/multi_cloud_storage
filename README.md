# Multi Cloud Storage

A Flutter plugin that provides a unified API for interacting with multiple cloud storage providers including Dropbox, Google Drive, and OneDrive.



## Features

- Unified interface for multiple cloud storage providers.
- Upload, download, delete, and manage files.
- Create and list directories.
- Retrieve file metadata.

---

## Supported Platforms

| Service       | Android | iOS | Mac  | Windows |
| ------------- |:-------:|:---:|:----:|:-------:|
| OneDrive      |    ✅    | ✅  | ✅   |   ✅    |
| Google Drive  |    ✅    | ✅  | ✅   |   ❌    |
| Dropbox       |    ✅    | ✅  | ❌   |   ❌    |
---

## Installation

Add the following to your `pubspec.yaml` file:

```yaml
dependencies:
  multi_cloud_storage: ^your_version_here
```

Run:

```shell
flutter pub get
```

---

## Cloud Providers Setup


### Google Drive

1. **Setup Google Drive API**:

   - Go to [Google Cloud Console Credentials](https://console.cloud.google.com/apis/credentials).
   - Create Credentials -> OAuth client ID. ()
   - Select "Android", "iOS", or "Web" based on your needs. (Make sure all data is correct for your app or else it won't work)


### Dropbox

1. **Register Your App**:
   - Visit [Dropbox App Console](https://www.dropbox.com/developers/apps).
   - Click "Create app".
   - Select Scoped access and appropriate access type (`app folder` or `full Dropbox`).
   - Obtain your `App Key`, `App Secret` and `Access Token`.
   - Set Redirect URI (OAuth), not required for mobile apps.
   - Under Permissions tab select the following permissions:
      - files.metadata.read
      - files.metadata.write
      - files.content.read
      - files.content.write
`
`
#### Android
Add this to /android/app/src/main/AndroidManifest.xml inside the application bloc and replace YOUR_APP_KEY with the appKey:

```xml
        <!-- Add Dropbox Auth Activity -->
        <activity
            android:name="com.dropbox.core.android.AuthActivity"
            android:exported="true"
            android:launchMode="singleTask">
            <intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
                <data
                    android:scheme="db-YOUR_APP_KEY"  />
            </intent-filter>
        </activity>
```  


#### iOS/MacOS

### 1. Add the following to `Info.plist`
**(Replace `DROPBOXKEY` with your actual Dropbox key):**

```xml
        <key>CFBundleURLTypes</key>
<array>
<dict>
   <key>CFBundleURLSchemes</key>
   <array>
      <string>db-DROPBOXKEY</string>
   </array>
   <key>CFBundleURLName</key>
   <string></string>
</dict>
</array>
        <key>LSApplicationQueriesSchemes</key>
          <array>
              <string>dbapi-8-emm</string>
              <string>dbapi-2</string>
          </array>

```


2**Add below code to AppDelegate.swift**:

```swift
        import ObjectiveDropboxOfficial

        // should be inside AppDelegate class
        override func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
          if let authResult = DBClientsManager.handleRedirectURL(url) {
              if authResult.isSuccess() {
                  print("dropbox auth success")
              } else if (authResult.isCancel()) {
                  print("dropbox auth cancel")
              } else if (authResult.isError()) {
                  print("dropbox auth error \(authResult.errorDescription)")
              }
          }
          return true
        }

        // if your are linked with ObjectiveDropboxOfficial 6.x use below code instead

        override func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
          DBClientsManager.handleRedirectURL(url, completion:{ (authResult) in
            if let authResult = authResult {
                if authResult.isSuccess() {
                    print("dropbox auth success")
                } else if (authResult.isCancel()) {
                    print("dropbox auth cancel")
                } else if (authResult.isError()) {
                    print("dropbox auth error \(authResult.errorDescription)")
                }
            }
          });
          return true
        }
```

### OneDrive

1. **Register Your App**:

    - Go to [Azure Portal App registration](https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade).
    - Click `New registration`.
    - For native apps set Redirect URI to `https://login.microsoftonline.com/common/oauth2/nativeclient` .
    - Obtain your `Client ID`.
    - On the left side go to Manage -> API permissions
    - Click add a Permission
    - Selected "Delegated permission"
    - Search for the Permissions your app needs like:
      - Files.Read, Files.ReadWrite, Files.Read.All, Files.ReadWrite.All

---

## Usage

```dart
import 'package:multi_cloud_storage/multi_cloud_storage.dart';

void main() async {
   // Connect to GoogleDrive
   final googleDrive = await MultiCloudStorage.connectToGoogleDrive(); // App registration required: https://console.cloud.google.com/apis/credentials

   // Upload a file
   final uploadedPath = await googleDrive.uploadFile(
      localPath: '/local/path/to/file.txt',
      remotePath: '/remote/path/file.txt',
   );
   print('Uploaded to: $uploadedPath');

   // List files in a folder
   final files = await googleDrive.listFiles(path: '/remote/path');
   for (final file in files) {
      print('Found file: ${file.name} (${file.path})');
   }

   // Download a file
   final localFile = await googleDrive.downloadFile(
      remotePath: '/remote/path/file.txt',
      localPath: '/local/path/downloaded.txt',
   );
   print('Downloaded to: $localFile');

   // Delete a file
   await googleDrive.deleteFile('/remote/path/file.txt');
   print('File deleted');
}

```

---


## Contribution

Feel free to submit pull requests and report issues.

---

## License

Distributed under the MIT License. See `LICENSE` for more information.
