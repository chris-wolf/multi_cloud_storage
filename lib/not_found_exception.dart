class NotFoundException implements Exception {
  final String message;
  final String? resourceId;

  NotFoundException(this.message, {this.resourceId});

  @override
  String toString() => 'NotFoundException: $message (resourceId: $resourceId)';
}