import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/profile.dart';
import '../services/api.dart';

/// What the app knows about the signed-in user. The server (PostgreSQL on Neon) is the source of truth;
/// the device keeps the log-in token and a copy of the profile so the app still opens without internet.
class AppState extends ChangeNotifier {
  AppState({Api? api}) : api = api ?? Api() {
    this.api.onUnauthorised = () => signOut();
    this.api.onWrite = (_) => dataChanged();
  }

  /// Goes up by one whenever the user's data changes anywhere in the app. Screens that show that data
  /// (ReloadOnChange) fetch fresh figures quietly, keeping the old ones on screen until the new ones arrive.
  int dataVersion = 0;

  /// A screen asks the home screen to switch tab (for example "See it in Plans" after going ahead with a check).
  final tabRequest = ValueNotifier<int?>(null);

  void openTab(int tab) {
    tabRequest.value = null;   // the same tab twice in a row still fires
    tabRequest.value = tab;
  }

  void dataChanged() {
    dataVersion++;
    notifyListeners();
  }

  static const _tokenKey = 'token_v1';
  static const _profileKey = 'profile_v1';
  static const _adminKey = 'admin_v1';

  final Api api;
  Profile? profile;
  bool loaded = false;
  /// false: the server says this user has not agreed to the current privacy notice. null: not known (offline),
  /// so the app is not blocked; the server still refuses statements without consent.
  bool? consented;
  bool get signedIn => api.token != null;
  /// The server's answer to "is this an admin account?" (from ADMIN_EMAILS on the server, never set in the app).
  /// Admins get the admin console instead of the household app.
  bool admin = false;

  Future<void> _loadRole(SharedPreferences prefs) async {
    try {
      admin = await api.isAdmin();
      await prefs.setBool(_adminKey, admin);
    } on ApiException catch (e) {
      if (e.isUnauthorised) rethrow;
      // Offline: keep the last answer.
    } catch (_) {}
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    api.token = prefs.getString(_tokenKey);
    final cached = prefs.getString(_profileKey);
    if (cached != null) profile = Profile.fromJson(jsonDecode(cached) as Map<String, dynamic>);
    admin = prefs.getBool(_adminKey) ?? false;
    if (signedIn) {
      try {
        await _loadRole(prefs);
        final remote = await api.getProfile();
        if (remote != null) await _cache(Profile.fromJson(remote));
        consented = (await api.consent())['accepted'] == true;
      } on ApiException catch (e) {
        if (e.isUnauthorised) await signOut();   // token expired or account deleted
        // Offline: keep the cached copy.
      }
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> signIn(String email, String password, {required bool newAccount, bool consent = false}) async {
    newAccount ? await api.register(email, password, consent: consent) : await api.login(email, password);
    await _afterLogin();
  }

  /// Google sign-in: the server does the checking, then this is an ordinary logged-in session.
  Future<void> signInWithGoogle(String idToken) async {
    await api.googleSignIn(idToken);
    await _afterLogin();
  }

  /// Forgot password: the emailed code and a new password. Every other device is logged out; this one is in.
  Future<void> resetPassword(String email, String code, String newPassword) async {
    await api.resetPassword(email, code, newPassword);
    await _afterLogin();
  }

  Future<void> _afterLogin() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, api.token!);
    profile = null;
    admin = false;
    await _loadRole(prefs);
    final remote = await api.getProfile();
    if (remote != null) {
      await _cache(Profile.fromJson(remote));
    } else {
      await prefs.remove(_profileKey);
    }
    try {
      consented = (await api.consent())['accepted'] == true;
    } on ApiException {
      consented = null;                         // unknown for now; asked again on the next start
    }
    notifyListeners();
  }

  /// Change the password and keep this device logged in with the new token.
  Future<void> changePassword(String current, String newPassword) async {
    await api.changePassword(current, newPassword);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, api.token!);
  }

  Future<void> acceptPrivacy(String version) async {
    await api.giveConsent(version);
    consented = true;
    notifyListeners();
  }

  /// Delete everything on the server, then forget the account on this device.
  Future<void> deleteAccount() async {
    await api.deleteAccount();
    await signOut();
  }

  /// The Log out button: tell the server, then forget the account here. If the server cannot be reached the
  /// device still logs out; the token then simply expires.
  /// Words for a whole-app wait (log out), shown over every screen; null when nothing is happening.
  List<String>? busy;

  Future<void> logOut({bool everywhere = false}) async {
    busy = const ['Logging you out…', 'Clearing your figures from this device…'];
    notifyListeners();
    try {
      await api.logout(everywhere: everywhere);
    } catch (_) {
      // Offline or the server is asleep: this device still logs out, and the token expires on its own.
    }
    busy = null;
    await signOut();
  }

  // ---- last figures, shown at once while fresh ones load (cleared on log out) ----
  static const _cachePrefix = 'cache_v1_';

  /// The last answer kept for a screen ([key] like 'overview'), or null.
  Future<Map<String, dynamic>?> cached(String key) async {
    final s = (await SharedPreferences.getInstance()).getString('$_cachePrefix$key');
    return s == null ? null : jsonDecode(s) as Map<String, dynamic>;
  }

  Future<void> keep(String key, Map<String, dynamic>? value) async {
    final prefs = await SharedPreferences.getInstance();
    value == null ? await prefs.remove('$_cachePrefix$key') : await prefs.setString('$_cachePrefix$key', jsonEncode(value));
  }

  Future<void> signOut() async {
    api.token = null;
    profile = null;
    consented = null;
    admin = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_adminKey);
    await prefs.remove(_tokenKey);
    await prefs.remove(_profileKey);
    for (final k in prefs.getKeys().where((k) => k.startsWith(_cachePrefix)).toList()) {
      await prefs.remove(k);                       // another person on this device must never see these figures
    }
    notifyListeners();
  }

  /// Save to the server first; only then update the device copy. [incomeChange]: 'from_now' (the income
  /// changed this month, earlier months keep the old figure) or 'correction' (the old figure was a mistake).
  Future<void> saveProfile(Profile p, {String incomeChange = 'from_now'}) async {
    await api.putProfile({...p.toJson(), 'incomeChange': incomeChange});
    final remote = await api.getProfile();            // picks up the email and anything the server set
    await _cache(remote != null ? Profile.fromJson(remote) : p);
    notifyListeners();
  }

  /// A profile already saved on the server (onboarding): fetch it back, keep it here and open the app.
  Future<void> useSavedProfile(Profile p) async {
    final remote = await api.getProfile();
    await _cache(remote != null ? Profile.fromJson(remote) : p);
    notifyListeners();
  }

  Future<void> _cache(Profile p) async {
    profile = p;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_profileKey, jsonEncode(p.toJson()));
  }
}
