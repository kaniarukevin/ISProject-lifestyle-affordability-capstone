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

  test('an expired login signs the app out', () async {
    var signedOut = false;
    final api = Api(
        client: MockClient((_) async => http.Response(jsonEncode({'error': 'your session has expired, log in again'}), 401)),
        baseUrl: 'http://test')
      ..token = 'old'
      ..onUnauthorised = () => signedOut = true;
    await expectLater(api.getProfile(), throwsA(isA<ApiException>()));
    expect(signedOut, isTrue);
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

  test('changing the password keeps the new token for later requests', () async {
    final client = MockClient((req) async {
      expect(jsonDecode(req.body), {'current': 'old-pass-1', 'new': 'new-pass-2'});
      return http.Response(jsonEncode({'token': 'fresh', 'changed': true}), 200);
    });
    final api = Api(client: client, baseUrl: 'http://test')..token = 'stale';
    expect(await api.changePassword('old-pass-1', 'new-pass-2'), 'fresh');
    expect(api.token, 'fresh');
  });

  test('editing a record sends a PATCH with only the changed fields', () async {
    late http.Request seen;
    final api = Api(client: MockClient((req) async {
      seen = req;
      return http.Response(jsonEncode({'updated': 1}), 200);
    }), baseUrl: 'http://test');
    await api.editTransaction(7, {'amount': 650, 'one_off': false});
    expect(seen.method, 'PATCH');
    expect(seen.url.path, '/me/transactions/7');
    expect(jsonDecode(seen.body), {'amount': 650, 'one_off': false});
  });
}
