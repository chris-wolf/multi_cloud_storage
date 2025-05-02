import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'multi_cloud_storage_platform_interface.dart';

/// An implementation of [MultiCloudStoragePlatform] that uses method channels.
class MethodChannelMultiCloudStorage extends MultiCloudStoragePlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('multi_cloud_storage');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
