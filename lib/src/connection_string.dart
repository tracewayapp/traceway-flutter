class ParsedConnectionString {
  final String token;
  final String apiUrl;

  const ParsedConnectionString({required this.token, required this.apiUrl});
}

ParsedConnectionString parseConnectionString(String connectionString) {
  final atIndex = connectionString.indexOf('@');
  if (atIndex == -1) {
    throw ArgumentError(
      'Invalid connection string: must be in format {token}@{apiUrl}',
    );
  }
  final token = connectionString.substring(0, atIndex);
  final apiUrl = connectionString.substring(atIndex + 1);
  if (token.isEmpty || apiUrl.isEmpty) {
    throw ArgumentError(
      'Invalid connection string: token and apiUrl must not be empty',
    );
  }
  return ParsedConnectionString(token: token, apiUrl: apiUrl);
}
