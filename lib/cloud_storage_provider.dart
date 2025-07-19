/// Abstract class defining the interface for cloud storage providers.
abstract class CloudStorageProvider {
  Future<String?> loggedInUserDisplayName();

  /// Uploads a file to the cloud storage.
  Future<String> uploadFile({
    required String localPath,
    required String remotePath,
    Map<String, dynamic>? metadata,
  });


  /// Downloads a file from the cloud storage.
  Future<String> downloadFile({
    required String remotePath,
    required String localPath,
  });

  /// Lists files in a directory.
  Future<List<CloudFile>> listFiles({
    required String path,
    bool recursive = false,
  });

  /// Deletes a file from the cloud storage.
  Future<void> deleteFile(String path);

  /// Creates a new directory in the cloud storage.
  Future<void> createDirectory(String path);

  /// Gets the metadata of a file.
  Future<CloudFile> getFileMetadata(String path);

  /// Logout user.
  Future<bool> logout();

  /// Checks if the suer token is still expired.
  Future<bool> tokenExpired();

  Future<Uri?> generateShareLink(String path);

  Future<String?> getShareTokenFromShareLink(Uri shareLink);

  Future<String> downloadFileByShareToken({
    required String shareToken,
    required String localPath
  });


  /// Uploads a file to the cloud storage.
  Future<String> uploadFileByShareToken({
    required String localPath,
    required String shareToken,
    Map<String, dynamic>? metadata,
  });
}

/// Represents a file in cloud storage.
class CloudFile {
  final String path;
  final String name;
  final int? size;
  final DateTime? modifiedTime;
  final bool isDirectory;
  final Map<String, dynamic>? metadata;

  CloudFile({
    required this.path,
    required this.name,
    required this.size,
    required this.modifiedTime,
    required this.isDirectory,
    this.metadata,
  });
}
