import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/transaction.dart';

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
    dynamic data;
    try {
      data = r.body.isEmpty ? null : jsonDecode(r.body);
    } on FormatException {
      // A crash on the server returns an HTML error page, not JSON: report it instead of hanging.
      throw ApiException('The server had a problem (${r.statusCode}). Please try again.', r.statusCode);
    }
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

  // ---- spending ----
  Future<List<Txn>> getTransactions() async {
    final d = await get('/me/transactions') as Map<String, dynamic>;
    return (d['transactions'] as List).map((e) => Txn.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// One transaction or many (a parsed statement) in a single request.
  Future<List<Txn>> addTransactions(List<Txn> txns) async {
    final d = await post('/me/transactions', txns.map((t) => t.toJson()).toList()) as Map<String, dynamic>;
    return (d['transactions'] as List).map((e) => Txn.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> deleteTransaction(int id) => delete('/me/transactions/$id');

  /// Monthly totals per category plus income: the 'months' list the engines take.
  Future<List<Map<String, dynamic>>> months() async =>
      ((await get('/me/months') as Map<String, dynamic>)['months'] as List).cast<Map<String, dynamic>>();

  /// Everything the dashboard shows: state, score, latest month and next month's forecast.
  Future<Map<String, dynamic>> overview() async => (await get('/me/overview')) as Map<String, dynamic>;

  /// This month's dynamic budget plan, spending so far, and any budget already saved.
  Future<Map<String, dynamic>> budgetPlan() async => (await get('/me/budget-plan')) as Map<String, dynamic>;

  Future<void> saveBudget(int year, int month, Map<String, dynamic> plan) => put('/me/budgets/$year/$month', plan);

  // ---- commitments ----
  Future<Map<String, dynamic>> getCommitments() async => (await get('/me/commitments')) as Map<String, dynamic>;

  /// Saves and returns the engine's summary: monthly figures, debt plans, goal amounts, warnings.
  Future<Map<String, dynamic>> putCommitments(Map<String, dynamic> c) async =>
      ((await put('/me/commitments', c)) as Map<String, dynamic>)['summary'] as Map<String, dynamic>;
}
