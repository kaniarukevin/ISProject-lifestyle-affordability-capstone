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

  /// Called when the server says the login is no longer valid (expired, logged out elsewhere, password changed),
  /// so the app returns to the log-in screen instead of showing errors on every screen (audit A-16).
  void Function()? onUnauthorised;

  /// Called after a request that changed the user's data succeeded (a record added, a plan saved, a check run),
  /// so the screens showing that data refresh by themselves. Requests that change nothing are left out.
  void Function(String path)? onWrite;

  static bool _changesNothing(String path) =>
      path.startsWith('/auth/') ||
      path.startsWith('/me/explain') ||
      path.startsWith('/me/statements/preview') ||
      path.startsWith('/me/messages/preview') ||
      path.startsWith('/me/password') ||
      path.startsWith('/me/consent') ||
      path.startsWith('/me/ratings');

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
    final data = _decode(r);
    if (method != 'GET' && !_changesNothing(path)) onWrite?.call(path);
    return data;
  }

  dynamic _decode(http.Response r) {
    dynamic data;
    try {
      data = r.body.isEmpty ? null : jsonDecode(r.body);
    } on FormatException {
      // A crash on the server returns an HTML error page, not JSON: report it instead of hanging.
      throw ApiException('The server had a problem (${r.statusCode}). Please try again.', r.statusCode);
    }
    if (r.statusCode == 401 && token != null) onUnauthorised?.call();
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
  /// [consent]: the user ticked "I agree to the privacy notice" on the sign-up screen.
  Future<String> register(String email, String password, {bool consent = false}) async {
    final d = await post('/auth/register', {'email': email, 'password': password, 'consent': consent});
    return token = d['token'] as String;
  }

  // ---- privacy (Data Protection Act 2019) ----
  Future<Map<String, dynamic>> privacy() async => (await get('/privacy')) as Map<String, dynamic>;

  /// Whether this user agreed to the current notice: {version, accepted, accepted_at}.
  Future<Map<String, dynamic>> consent() async => (await get('/me/consent')) as Map<String, dynamic>;

  Future<void> giveConsent(String version) => post('/me/consent', {'accept': true, 'version': version});

  /// Everything the app keeps about this user (Data Protection Act: the right to a copy).
  Future<Map<String, dynamic>> exportData() async => (await get('/me/export')) as Map<String, dynamic>;

  /// Remove the account and all its data on the server.
  Future<void> deleteAccount() => delete('/me');

  /// End this session on the server too (the token stops working at once); everywhere: every device.
  Future<void> logout({bool everywhere = false}) => post('/auth/logout', {'everywhere': everywhere});

  Future<String> login(String email, String password) async {
    final d = await post('/auth/login', {'email': email, 'password': password});
    return token = d['token'] as String;
  }

  /// Forgot password, step 1: email a 6-digit code. The answer is the same whether or not the email has an account.
  Future<String> forgotPassword(String email) async =>
      ((await post('/auth/forgot', {'email': email})) as Map<String, dynamic>)['message'] as String;

  /// Forgot password, step 2: the code and a new password; logs this device in.
  Future<String> resetPassword(String email, String code, String newPassword) async {
    final d = await post('/auth/reset', {'email': email, 'code': code, 'new': newPassword});
    return token = d['token'] as String;
  }

  /// "Does this match your real finances?" (1 to 5), on the overview or on one affordability check.
  Future<void> rate(String where, int score, {int? scenarioId}) =>
      post('/me/ratings', {'where': where, 'score': score, 'scenario_id': ?scenarioId});

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
  /// All records, or one month's ([month] like '2026-10').
  Future<List<Txn>> getTransactions({String? month}) async {
    final d = await get(month == null ? '/me/transactions' : '/me/transactions?month=$month') as Map<String, dynamic>;
    return (d['transactions'] as List).map((e) => Txn.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// One transaction or many (a parsed statement) in a single request.
  /// One line per month (totals by category, record count), newest first, and whether a statement was imported.
  Future<Map<String, dynamic>> spendingSummary() async =>
      (await get('/me/transactions/summary')) as Map<String, dynamic>;

  /// The Records screen in one trip: every month's summary and one month's records (default the newest).
  Future<Map<String, dynamic>> records({String? month}) async =>
      (await get(month == null ? '/me/records' : '/me/records?month=$month')) as Map<String, dynamic>;

  Future<List<Txn>> addTransactions(List<Txn> txns) async {
    final d = await post('/me/transactions', txns.map((t) => t.toJson()).toList()) as Map<String, dynamic>;
    return (d['transactions'] as List).map((e) => Txn.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> deleteTransaction(int id) => delete('/me/transactions/$id');

  /// Change a payment's category: just this one ('one') or always for its payee ('payee'). Returns
  /// {updated, offer}; offer is set when tagging rent or school fees could become a commitment.
  Future<Map<String, dynamic>> correctTransaction(int id, String category, {String scope = 'one'}) async =>
      (await _send('PATCH', '/me/transactions/$id', {'category': category, 'scope': scope})) as Map<String, dynamic>;

  /// Change fields of one record: amount, date, description (typed-in records only), category, one_off.
  Future<void> editTransaction(int id, Map<String, dynamic> fields) => _send('PATCH', '/me/transactions/$id', fields);

  /// Change the password; returns the new token (other devices are logged out).
  Future<String> changePassword(String current, String newPassword) async {
    final d = await post('/me/password', {'current': current, 'new': newPassword});
    return token = d['token'] as String;
  }

  /// Whether this account is an admin (named in the server's ADMIN_EMAILS).
  Future<bool> isAdmin() async => ((await get('/me/role')) as Map<String, dynamic>)['admin'] == true;

  /// Service health, model register and users (admins only; no one's finances are included).
  Future<Map<String, dynamic>> adminOverview() async => (await get('/admin/overview')) as Map<String, dynamic>;

  /// Each model and dataset with its results against the baseline (admins only; from model_register.py).
  Future<Map<String, dynamic>> adminReports() async => (await get('/admin/reports')) as Map<String, dynamic>;

  /// Response times, database time, errors and recent events since the server started (admins only).
  Future<Map<String, dynamic>> adminPerformance() async => (await get('/admin/performance')) as Map<String, dynamic>;

  /// Remove an account and all its data (admins only; admin accounts cannot be removed this way).
  Future<void> adminDeleteUser(int id) => delete('/admin/users/$id');

  /// Pause an account (it cannot log in; its data is kept) or let it back in (admins only).
  Future<void> adminBlockUser(int id, bool blocked) => post('/admin/users/$id/block', {'blocked': blocked});

  /// Ratings, sorting kept or corrected, feature use and admin actions, pooled (admins only).
  Future<Map<String, dynamic>> adminValidation() async => (await get('/admin/validation')) as Map<String, dynamic>;

  /// Everyone you pay (from statements), with their tags and suggestions.
  Future<Map<String, dynamic>> payees() async => (await get('/me/payees')) as Map<String, dynamic>;

  Future<Map<String, dynamic>> tagPayee(String key, String tag) async =>
      (await put('/me/payees', {'key': key, 'tag': tag})) as Map<String, dynamic>;

  /// The payments from one source of money coming in, newest first.
  Future<List<Map<String, dynamic>>> moneyIn(String key) async =>
      (((await get('/me/money-in?key=${Uri.encodeQueryComponent(key)}')) as Map<String, dynamic>)['payments'] as List)
          .cast<Map<String, dynamic>>();

  /// This payment only: what one payment coming in was. The source's tag leaves it alone from then on.
  Future<void> changeMoneyIn(int id, String kind) => _send('PATCH', '/me/money-in/$id', {'kind': kind});

  Future<void> untagPayee(String key) => delete('/me/payees?key=${Uri.encodeQueryComponent(key)}');

  /// Accept an offer to add rent or school fees to commitments.
  Future<void> acceptCommitmentOffer(Map<String, dynamic> offer) => post('/me/payees/commitment', offer);

  /// Remove everything imported from statements (to re-import cleanly).
  Future<int> undoStatements() async => ((await delete('/me/statements')) as Map<String, dynamic>)['removed'] as int;

  /// Monthly totals per category plus income: the 'months' list the engines take.
  Future<List<Map<String, dynamic>>> months() async =>
      ((await get('/me/months') as Map<String, dynamic>)['months'] as List).cast<Map<String, dynamic>>();

  /// Everything the dashboard shows: state, score, latest month and next month's forecast.
  Future<Map<String, dynamic>> overview() async => (await get('/me/overview')) as Map<String, dynamic>;

  /// This month's dynamic budget plan, spending so far, and any budget already saved.
  /// The next three months at the usual pace against the budget, the savings path and what to put aside.
  Future<Map<String, dynamic>> budgetForecast() async => (await get('/me/budget-forecast')) as Map<String, dynamic>;

  Future<Map<String, dynamic>> budgetPlan() async => (await get('/me/budget-plan')) as Map<String, dynamic>;

  /// Set one everyday budget line by hand (remembered for later months); returns the rebuilt budget.
  Future<Map<String, dynamic>> editBudgetLine(String category, double amount) async =>
      (await post('/me/budget-plan/edit', {'category': category, 'amount': amount})) as Map<String, dynamic>;

  /// Money that never touches M-PESA, roughly per month (income in, card or cash spending out).
  Future<void> setOutsideMoney(double income, double spending) =>
      post('/me/outside-money', {'income': income, 'spending': spending});

  /// "What the statement shows is right": stop asking about the income gap.
  Future<void> dismissIncomeGap() => post('/me/income-gap/dismiss', {});

  /// One month's money in, set by the user (wins for that month only), or cleared.
  Future<void> setMonthIncome(int year, int month, double amount) =>
      put('/me/months/$year/$month/income', {'amount': amount});
  Future<void> clearMonthIncome(int year, int month) => delete('/me/months/$year/$month/income');

  /// Past months' budgets against what was really spent, newest first.
  Future<List<Map<String, dynamic>>> budgetHistory() async =>
      ((await get('/me/budgets/history') as Map<String, dynamic>)['months'] as List).cast<Map<String, dynamic>>();

  /// Forget the lines set by hand and go back to the recommended budget.
  Future<Map<String, dynamic>> resetBudget() async => (await post('/me/budget-plan/reset', {})) as Map<String, dynamic>;

  Future<void> saveBudget(int year, int month, Map<String, dynamic> plan) => put('/me/budgets/$year/$month', plan);

  /// 'Can I afford this?' on the user's own data. [choice] is a preset with its inputs.
  Future<Map<String, dynamic>> afford(Map<String, dynamic> choice) async =>
      (await post('/me/afford', choice)) as Map<String, dynamic>;

  /// 'Why this score?': the dashboard score explained, or with a [choice] the score after it and what moved.
  Future<Map<String, dynamic>> explain([Map<String, dynamic>? choice]) async =>
      (await post('/me/explain', choice ?? <String, dynamic>{})) as Map<String, dynamic>;

  /// Read an M-PESA statement (PDF) on the server and return what would be imported. Nothing is saved yet;
  /// the file and password are only used for this request.
  Future<Map<String, dynamic>> previewStatement(List<int> bytes, String filename, String? password) async {
    final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/me/statements/preview'));
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    req.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    if (password != null && password.isNotEmpty) req.fields['password'] = password;
    late http.Response r;
    try {
      r = await http.Response.fromStream(await _client.send(req).timeout(_timeout));
    } catch (_) {
      throw ApiException('Could not reach the server. Check your internet connection and try again.');
    }
    return _decode(r) as Map<String, dynamic>;
  }

  /// Save a reviewed statement: the preview's transactions, the answers to its questions, finished goals.
  /// Pasted M-PESA SMS confirmations, read like a statement (same review screen, nothing saved yet).
  Future<Map<String, dynamic>> previewMessages(String text) async =>
      (await post('/me/messages/preview', {'text': text})) as Map<String, dynamic>;

  Future<Map<String, dynamic>> importStatement(Map<String, dynamic> body) async =>
      (await post('/me/statements/import', body)) as Map<String, dynamic>;

  Future<List<Map<String, dynamic>>> scenarios() async =>
      ((await get('/me/scenarios') as Map<String, dynamic>)['scenarios'] as List).cast<Map<String, dynamic>>();

  /// "I'm doing this": turn a check into a real debt, commitment, goal or profile change.
  /// [how] is 'instalments' or 'from_savings' for purchases. Returns what changed, in words.
  Future<List<String>> applyScenario(int id, {String how = 'instalments'}) async =>
      (((await post('/me/scenarios/$id/apply', {'how': how})) as Map<String, dynamic>)['notes'] as List)
          .cast<String>();

  Future<void> deleteScenario(int id) => delete('/me/scenarios/$id');

  // ---- commitments ----
  Future<Map<String, dynamic>> getCommitments() async => (await get('/me/commitments')) as Map<String, dynamic>;

  /// Saves and returns the engine's summary: monthly figures, debt plans, goal amounts, warnings.
  /// A bill was paid: the server records it and moves its due date on. Returns the new summary.
  Future<Map<String, dynamic>> markPaid(int index) async =>
      ((await post('/me/commitments/paid', {'index': index})) as Map<String, dynamic>)['summary'] as Map<String, dynamic>;

  Future<Map<String, dynamic>> putCommitments(Map<String, dynamic> c) async =>
      ((await put('/me/commitments', c)) as Map<String, dynamic>)['summary'] as Map<String, dynamic>;
}
