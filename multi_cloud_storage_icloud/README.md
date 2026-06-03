# multi_cloud_storage_icloud

iCloud storage provider implementation for `multi_cloud_storage`.

## Getting Started

Add this package to your `pubspec.yaml`:

```yaml
dependencies:
  multi_cloud_storage: ^latest
  multi_cloud_storage_icloud: ^latest
```

Then initialize the iCloud provider:

```dart
import 'package:multi_cloud_storage/cloud_storage_provider.dart';
import 'package:multi_cloud_storage_icloud/multi_cloud_storage_icloud.dart';

final provider = await ICloudProvider.connect(containerId: 'your_icloud_container_id');
```
