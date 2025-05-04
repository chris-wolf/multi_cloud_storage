# Multi Cloud Storage

A Flutter plugin that provides a unified API for interacting with multiple cloud storage providers including Dropbox, Google Drive, and OneDrive.

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

### Dropbox

1. **Register Your App**:
    - Visit [Dropbox App Console](https://www.dropbox.com/developers/apps).
    - Click "Create app".
    - Select Scoped access and appropriate access type (`app folder` or `full Dropbox`).
    - Generate access token for testing (user login doesn't work while app is Status: Development)
    - Obtain your `App Key`, `App Secret` and `Access Token`.
    - Set Redirect URI (OAuth), not required for mobile apps.


#### Android
Add this to /android/app/src/main/AndroidManifest.xml inside the application bloc and repolace YOUR_APP_KEY with the appKey:

```dart
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

### Google Drive

1. **Setup Google Drive API**:

    - Go to [Google Cloud Console Credentials](https://console.cloud.google.com/apis/credentials).
    - Create Credentials -> OAuth client ID. ()
    - Select "Android", "iOS", or "Web" based on your needs. (Make sure all data is correct for your app or else it won't work)

### OneDrive

1. **Register Your App**:

    - Go to [Azure Portal App registration](https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade).
    - Click `New registration`.
    - For native apps set Redirect URI to `https://login.microsoftonline.com/common/oauth2/nativeclient` .
    - Obtain your `Client ID`.

---

## Usage

```dart
import 'package:flutter/cupertino.dart';
import 'package:multi_cloud_storage/multi_cloud_storage.dart';

void main() async {
  // Example: Connect to Dropbox
  final dropbox = await MultiCloudStorage.connectToDropbox(
    appKey: 'YOUR_APP_KEY',
    appSecret: 'YOUR_APP_SECRET',
    redirectUri: 'YOUR_REDIRECT_URI',
  );

  // Example: Connect to Google Drive
  final googleDrive = await MultiCloudStorage.connectToGoogleDrive();

  // Example: Connect to OneDrive
  final oneDrive = await MultiCloudStorage.connectToOneDrive(
    clientId: 'YOUR_CLIENT_ID',
    clientSecret: 'YOUR_CLIENT_SECRET',
    redirectUri: 'YOUR_REDIRECT_URI',
    context: context,
  );
}
```

---


## Features

- Unified interface for multiple cloud storage providers.
- Upload, download, delete, and manage files.
- Create and list directories.
- Retrieve file metadata.

---

## Contribution

Feel free to submit pull requests and report issues.

---

## License

Distributed under the MIT License. See `LICENSE` for more information.
