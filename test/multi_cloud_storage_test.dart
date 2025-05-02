import 'package:flutter_test/flutter_test.dart';
import 'package:multi_cloud_storage/multi_cloud_storage.dart';
import 'package:multi_cloud_storage/multi_cloud_storage_platform_interface.dart';
import 'package:multi_cloud_storage/multi_cloud_storage_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockMultiCloudStoragePlatform
    with MockPlatformInterfaceMixin
    implements MultiCloudStoragePlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final MultiCloudStoragePlatform initialPlatform = MultiCloudStoragePlatform.instance;

  test('$MethodChannelMultiCloudStorage is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelMultiCloudStorage>());
  });

  test('getPlatformVersion', () async {
    MultiCloudStorage multiCloudStoragePlugin = MultiCloudStorage();
    MockMultiCloudStoragePlatform fakePlatform = MockMultiCloudStoragePlatform();
    MultiCloudStoragePlatform.instance = fakePlatform;

  });
}
