import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lifestyle_affordability/services/api.dart';

void main() {
  test('log-in stores the token and sends it on later requests', () async {
    String? seenAuth;
    final client = MockClient((req) async {
      if (req.url.path == '/auth/login') return http.Response(jsonEncode({'token': 'abc', 'user_id': 1}), 200);
      seenAuth = req.headers['Authorization'];
      return http.Response(jsonEncode({'householdSize': 1, 'incomes': []}), 200);
    });
    final api = Api(client: client, baseUrl: 'http://test');
    await api.login('a@b.com', 'password1');
    await api.getProfile();
    expect(seenAuth, 'Bearer abc');
  });

  test('a missing profile is null, not an error', () async {
    final api = Api(client: MockClient((_) async => http.Response(jsonEncode({'error': 'no profile yet'}), 404)),
        baseUrl: 'http://test');
    expect(await api.getProfile(), isNull);
  });

  test('server error messages reach the user', () async {
    final api = Api(
        client: MockClient((_) async => http.Response(jsonEncode({'error': 'wrong email or password'}), 401)),
        baseUrl: 'http://test');
    expect(() => api.login('a@b.com', 'nope12345'),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', 'wrong email or password')));
  });
}
