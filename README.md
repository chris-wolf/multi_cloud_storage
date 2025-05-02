# Multi Cloud Storage

A Flutter plugin that provides a unified interface for working with multiple cloud storage providers.

## Supported Providers

- Google Drive
- Dropbox (coming soon)
- OneDrive (coming soon)
- iCloud (coming soon)

## Installation

Add the following to your `pubspec.yaml` file:

```yaml
dependencies:
  multi_cloud_storage: ^0.0.1
```

## Usage

### Google Drive

```dart
import 'package:multi_cloud_storage/multi_cloud_storage.dart';
import 'package:multi_cloud_storage/providers/google_drive_storage.dart';

void main() async {
  // Initialize Google Drive storage
  final googleDrive = GoogleDriveStorage();
  
  // Initialize the provider
  await googleDrive.initialize();
  
  // Authenticate
  final isAuthenticated = await googleDrive.authenticate();
  if (!isAuthenticated) {
    print('Failed to authenticate with Google Drive');
    return;
  }
  
  // Upload a file
  final fileId = await googleDrive.uploadFile(
    localPath: '/path/to/local/file.txt',
    remotePath: '/remote/path/file.txt',
  );
  
  // Download a file
  final localPath = await googleDrive.downloadFile(
    remotePath: '/remote/path/file.txt',
    localPath: '/path/to/save/file.txt',
  );
  
  // List files in a directory
  final files = await googleDrive.listFiles(
    path: '/remote/path',
    recursive: false,
  );
  
  // Get file metadata
  final metadata = await googleDrive.getFileMetadata('/remote/path/file.txt');
  
  // Create a directory
  final created = await googleDrive.createDirectory('/remote/path/new_folder');
  
  // Move a file
  final moved = await googleDrive.moveFile(
    sourcePath: '/remote/path/file.txt',
    destinationPath: '/remote/path/new_folder/file.txt',
  );
  
  // Copy a file
  final copied = await googleDrive.copyFile(
    sourcePath: '/remote/path/file.txt',
    destinationPath: '/remote/path/copy.txt',
  );
  
  // Delete a file
  final deleted = await googleDrive.deleteFile('/remote/path/file.txt');
  
  // Check if a file exists
  final exists = await googleDrive.fileExists('/remote/path/file.txt');
  
  // Get storage space information
  final space = await googleDrive.getStorageSpace();
  print('Total space: ${space.totalSpace} bytes');
  print('Used space: ${space.usedSpace} bytes');
  print('Free space: ${space.freeSpace} bytes');
}
```

## Features

- Unified interface for multiple cloud storage providers
- File upload and download
- Directory listing
- File metadata retrieval
- Directory creation
- File moving and copying
- File deletion
- Storage space information
- Authentication handling

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
