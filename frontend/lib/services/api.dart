import 'dart:convert';

import 'package:http/http.dart' as http;

/// Where the backend lives. Override when running locally:
///   flutter run -d chrome --dart-define=API_URL=http://localhost:8000
const String apiUrl = String.fromEnvironment('API_URL', defaultValue: 'https://budget-forecast-cdc0.onrender.com');

class ApiException implements Exception {
  ApiException(this.message, [this.status]);
  final String message;
  final int? status;

  bool get isUnauthorised => status == 401;

  @override
  String toString() => message;
}

/// The one place the app talks to the server. Every request goes through here,
/// so the log-in token, time-outs and error messages are handled the same way everywhere.
class Api {
  Api({http.Client? client, this.baseUrl = apiUrl}) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  String? token;

  // The free server can take up to a minute to wake up, so allow for it.
  static const _timeout = Duration(seconds: 60);

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<dynamic> _send(String method, String path, [Object? body]) async {
    final uri = Uri.parse('$baseUrl$path');
    late http.Response r;
    try {
      final req = http.Request(method, uri)..headers.addAll(_headers);
      if (body != null) req.body = jsonEncode(body);
      r = await http.Response.fromStream(await _client.send(req).timeout(_timeout));
    } catch (_) {
      throw ApiException('Could not reach the server. Check your internet connection and try again.');
    }
    final data = r.body.isEmpty ? null : jsonDecode(r.body);
    if (r.statusCode >= 400) {
      final msg = data is Map && data['error'] != null ? data['error'].toString() : 'Something went wrong (${r.statusCode}).';
      throw ApiException(msg, r.statusCode);
    }
    return data;
  }

  Future<dynamic> get(String path) => _send('GET', path);
  Future<dynamic> post(String path, Object body) => _send('POST', path, body);
  Future<dynamic> put(String path, Object body) => _send('PUT', path, body);
  Future<dynamic> delete(String path) => _send('DELETE', path);

  // ---- accounts ----
  Future<String> register(String email, String password) async {
    final d = await post('/auth/register', {'email': email, 'password': password});
    return token = d['token'] as String;
  }

  Future<String> login(String email, String password) async {
    final d = await post('/auth/login', {'email': email, 'password': password});
    return token = d['token'] as String;
  }

  // ---- profile ----
  /// The saved profile, or null if this account has not set one up yet.
  Future<Map<String, dynamic>?> getProfile() async {
    try {
      return (await get('/me/profile')) as Map<String, dynamic>;
    } on ApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  Future<void> putProfile(Map<String, dynamic> profile) => put('/me/profile', profile);
}
