import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

Future<bool> sendReport(String apiUrl, String token, String jsonBody) async {
  final bytes = utf8.encode(jsonBody);
  final compressed = gzip.encode(bytes);

  try {
    final response = await http.post(
      Uri.parse(apiUrl),
      headers: {
        'Content-Type': 'application/json',
        'Content-Encoding': 'gzip',
        'Authorization': 'Bearer $token',
      },
      body: compressed,
    );
    return response.statusCode == 200;
  } catch (_) {
    return false;
  }
}
