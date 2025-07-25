import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:multi_cloud_storage/cloud_storage_provider.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as path;
import 'package:permission_handler/permission_handler.dart';

class CloudStorageExplorerPage extends StatefulWidget {
  final CloudStorageProvider cloudStorageProvider;

  const CloudStorageExplorerPage(
      {super.key, required this.cloudStorageProvider});

  @override
  _CloudStorageExplorerPageState createState() =>
      _CloudStorageExplorerPageState();
}

class _CloudStorageExplorerPageState extends State<CloudStorageExplorerPage> {
  String currentPath = '/';
  List<CloudFile> files = [];
  bool isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    setState(() {
      isLoading = true;
    });
    final listedFiles =
        await widget.cloudStorageProvider.listFiles(path: currentPath);
    setState(() {
      files = listedFiles;
    });
    setState(() {
      isLoading = false;
    });
  }

  Future<void> _uploadFile() async {
    final result = await FilePicker.platform.pickFiles();
    if (result != null && result.files.single.path != null) {
      final localPath = result.files.single.path!;
      final fileName = result.files.single.name;
      final remotePath = path.join(currentPath, fileName);
      try {
        await widget.cloudStorageProvider
            .uploadFile(localPath: localPath, remotePath: remotePath);
        _loadFiles();
      } catch (e) {
        _showError('Upload failed: $e');
      }
    }
  }

  Future<void> _downloadFile(CloudFile file) async {
    try {
      final hasPermission = await _requestStoragePermission();
      if (!hasPermission) {
        _showError('Storage permission denied. Cannot download the file.');
        return;
      }

      // Find the Downloads folder
      final downloadsDir = Directory('/storage/emulated/0/Download');
      if (!await downloadsDir.exists()) {
        _showError('Downloads folder not found.');
        return;
      }

      final localPath = path.join(downloadsDir.path, file.name);

      await widget.cloudStorageProvider.downloadFile(
        remotePath: file.path,
        localPath: localPath,
      );

      _showMessage('Downloaded to $localPath', localPath);
    } catch (e) {
      _showError('Download failed: $e');
    }
  }

  Future<void> _deleteFile(CloudFile file) async {
    try {
      await widget.cloudStorageProvider.deleteFile(file.path);
      _loadFiles();
    } catch (e) {
      _showError('Delete failed: $e');
    }
  }

  Future<void> _logout() async {
    await widget.cloudStorageProvider.logout();
    Navigator.pop(context);
  }

  Future<void> _createDirectory() async {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('New Directory'),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(hintText: 'Directory Name'),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final dirName = controller.text.trim();
              if (dirName.isNotEmpty) {
                final dirPath = path.join(currentPath, dirName);
                try {
                  await widget.cloudStorageProvider.createDirectory(dirPath);
                  _loadFiles();
                } catch (e) {
                  _showError('Create directory failed: $e');
                }
              }
              Navigator.of(context).pop();
            },
            child: Text('Create'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel'),
          ),
        ],
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red));
  }

  void _showMessage(String message, String? filePath) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: filePath == null
            ? null
            : SnackBarAction(
                label: 'Open',
                onPressed: () {
                  OpenFile.open(filePath);
                },
              ),
      ),
    );
  }

  void _enterDirectory(CloudFile file) {
    setState(() {
      currentPath = file.path;
    });
    _loadFiles();
  }

  Future<void> _refresh() async {
    await _loadFiles();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
        onWillPop: _onWillPop,
        child: Scaffold(
          appBar: AppBar(
            title: Text('Cloud Explorer: $currentPath'),
            actions: [
              IconButton(
                icon: Icon(Icons.logout),
                onPressed: _logout,
                tooltip: 'Logout',
              ),
              IconButton(
                icon: Icon(Icons.create_new_folder),
                onPressed: _createDirectory,
                tooltip: 'New Directory',
              ),
              IconButton(
                icon: Icon(Icons.upload_file),
                onPressed: _uploadFile,
                tooltip: 'Upload File',
              ),
              IconButton(
                icon: Icon(Icons.refresh),
                onPressed: _refresh,
                tooltip: 'Refresh',
              ),
            ],
          ),
          body: isLoading
              ? Center(child: CircularProgressIndicator())
              : files.isEmpty
                  ? Center(child: Text('No files here'))
                  : ListView.builder(
                      itemCount: files.length,
                      itemBuilder: (context, index) {
                        final file = files[index];
                        return ListTile(
                          leading: Icon(file.isDirectory
                              ? Icons.folder
                              : Icons.insert_drive_file),
                          title: Text(file.name),
                          subtitle: Text(file.isDirectory
                              ? 'Directory'
                              : file.size == null
                                  ? ''
                                  : '${file.size} bytes'),
                          onTap: () {
                            if (file.isDirectory) {
                              _enterDirectory(file);
                            } else {
                              _downloadFile(file);
                            }
                          },
                          trailing: IconButton(
                            icon: Icon(Icons.delete, color: Colors.red),
                            onPressed: () => _deleteFile(file),
                          ),
                        );
                      },
                    ),
        ));
  }

  Future<bool> _requestStoragePermission() async {
    if (await Permission.manageExternalStorage.isGranted) {
      return true;
    }

    final status = await Permission.manageExternalStorage.request();
    return status.isGranted;
  }

  Future<bool> _onWillPop() async {
    if (currentPath == '/' || currentPath.isEmpty) {
      // We are at root: allow normal back (pop the page)
      return true;
    } else {
      // Not at root: go one level up instead of popping
      _goOneLevelUp();
      return false;
    }
  }

  void _goOneLevelUp() {
    if (currentPath == '/' || currentPath.isEmpty) {
      // Already at root, do nothing
      return;
    }

    final parentPath = path.dirname(currentPath);

    setState(() {
      // If the parent is '.', means we were one level under root
      currentPath = (parentPath == '.' || parentPath == '') ? '/' : parentPath;
    });
    _loadFiles();
  }
}
