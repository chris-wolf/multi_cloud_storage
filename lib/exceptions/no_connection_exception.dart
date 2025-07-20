class NoConnectionException implements Exception {
  final String message;
  final String? resourceId;

  NoConnectionException(this.message, {this.resourceId});

  @override
  String toString() => 'NoConnectionException: $message (resourceId: $resourceId)';
}
