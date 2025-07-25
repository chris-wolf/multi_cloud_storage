# Multi Cloud Storage

A Flutter plugin that provides a unified API for interacting with multiple cloud storage providers including Dropbox, Google Drive, OneDrive and iCloud.

> ⚠️ **Disclaimer:** This package is in active development. Breaking changes may occur, and certain features or platforms may be incomplete or untested. Use with caution in production.


## Features

- Unified interface for multiple cloud storage providers.
- Upload, download, delete, and manage files.
- Create and list directories.
- Retrieve file metadata.

---

## Supported Platforms

| Service     | Android | iOS | Mac | Windows | Linux |
|-------------|:-------:|:---:|:----:|:-------:|:-----:|
| OneDrive    | ✅      | ✅  | ⚠️   | ⚠️      | ❌    |
| Google Drive| ✅      | ✅  | ⚠️   | ❌      | ❌    |
| Dropbox     | ✅      | ✅  | ⚠️   | ⚠️      | ⚠️    |
| iCloud      | ❌      | ✅  | ⚠️   | ⚠️      | ❌    |


⚠️ = Still untested, but should work with correct setup.




## Supported Functions
| Functions                  | OneDrive | Google Drive | Dropbox | iCloud |
|----------------------------|----------|--------------|---------|--------|
| App Folder                 | ✅       | ✅           | ✅      | ✅     |
| Full Access                | ✅       | ✅           | ✅      | ❌     |
| listFiles                  | ✅       | ✅           | ✅      | ✅     |
| uploadFile                 | ✅       | ✅           | ✅      | ✅     |
| downloadFile               | ✅       | ✅           | ✅      | ✅     |
| deleteFile                 | ✅       | ✅           | ✅      | ✅     |
| createDirectory            | ✅       | ✅           | ✅      | ❌     |
| getFileMetadata            | ❌       | ✅           | ✅      | ✅     |
| logout                     | ✅       | ✅           | ✅      | ✅     |
| tokenExpired               | ✅       | ✅           | ✅      | ✅     |
| loggedInUserDisplayName    | ✅       | ✅           | ✅      | ❌     |
| generateShareLink          | ✅       | ✅           | ✅      | ❌     |
| getShareTokenFromShareLink | ✅       | ✅           | ❌      | ❌     |
| downloadFileByShareToken   | ✅       | ✅           | ❌      | ❌     |
| uploadFileByShareToken     | ✅       | ✅           | ❌      | ❌     |

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

#### iOS

- After authorization download the .plist file and rename it to GoogleService-Info.plist
- Open the ios project in xCode (/ios/Runner.xcworkspace)
- Drag and drop GoogleService-Info.plist into Runner/Runner/
- Click on GoogleService-Info.plist and press the two arrows top right to see the code
- Copy the values of CLIENT_ID and REVERSED_CLIENT_ID into Info.plist inside the dict block:
```xml
<key>GIDClientID</key>
<string>YOUR_CLIENT_ID.apps.googleusercontent.com</string>
<key>CFBundleURLTypes</key>
<array>
<dict>
   <key>CFBundleTypeRole</key>
   <string>Editor</string>
   <key>CFBundleURLSchemes</key>
   <array>
      <string>com.googleusercontent.apps.YOUR_REVERSED_CLIENT_ID</string>
   </array>
</dict>
</array>
```


### OneDrive

1. **Register Your App**:

    - Go to [Azure Portal App registration](https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade).
    - Click `New registration`.
    - For native apps set Redirect URI to `https://login.microsoftonline.com/common/oauth2/nativeclient` .
    - Obtain your `Client ID`.
    - Selected Manage -> "API Permissons"
    - Add the Microsoft Graph Permissions your app needs:
      - Files.Read
      - Files.ReadWrite
      - Files.Read.All
      - Files.ReadWrite.All
      - User.Read
      - Sites.ReadWrite.All
    - Click on `Grant admin consent for Default Directory` to enable these permissions.



### Dropbox

1. **Register Your App**:
   - Visit [Dropbox App Console](https://www.dropbox.com/developers/apps).
   - Click "Create app".
   - Select Scoped access and appropriate access type (`app folder` or `full Dropbox`).
   - Click`Enable additonal users` to let other accounts authenticate.
   - Obtain your `App Key`, `App Secret`.
   - Add a redirect URI, like `sample://auth.my.app` (use a custom one to prevent conflicts with other apps)
   - Under Permissions tab select the following permissions:
      - files.metadata.read
      - files.metadata.write
      - files.content.read
      - files.content.write


#### Android
#### Add this to /android/app/src/main/AndroidManifest.xml inside your MainActivity blocl
**(Replace `sample` and `auth.my.app` with your redirect URI defined above)**

```xml
<!-- Deep Link for dropbox auth result -->
<intent-filter>
   <action android:name="android.intent.action.VIEW" />
   <category android:name="android.intent.category.DEFAULT" />
   <category android:name="android.intent.category.BROWSABLE" />
   <!-- Add optional android:host to distinguish your app
         from others in case of conflicting scheme name -->
   <data android:scheme="sample" android:host="auth.my.app" />
</intent-filter>
```  


#### iOS/MacOS
#### Add the following to `Info.plist` in your ios/macOs folder: runner/Info.plist
**(Replace `sample` with your redirect URI defined above)**

```xml
<key>CFBundleURLTypes</key>
<array>
<dict>
   <key>CFBundleURLSchemes</key>
   <array>
      <string>sample</string>
   </array>
</dict>
</array>
```

#### Other platforms are untested but should work when following app_links documentation: https://pub.dev/packages/app_links


### iCloud
#### Follow the instructions here: https://pub.dev/packages/icloud_storage_sync#-how-to-set-up-icloud-container-and-enable-the-capability
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
