import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:provider/provider.dart';

import '../services/api.dart';
import '../state/app_state.dart';
import 'google_button_target.dart' if (dart.library.js_interop) 'google_button_target_web.dart';

/// "Continue with Google" (11 Nov). The server checks the token with Google, then either opens a new account or
/// links an existing email account with the same verified address, so nobody ends up with two accounts.
///
/// The client id is passed in at build time:
///   flutter build web --release --dart-define=GOOGLE_CLIENT_ID=xxx.apps.googleusercontent.com
/// Without it the button is simply not shown, and signing in with an email and password still works.
class GoogleButton extends StatefulWidget {
  const GoogleButton({super.key, this.onError});

  /// Shown on the sign-in screen when Google works but the server refuses the sign-in.
  final ValueChanged<String>? onError;

  static const clientId = String.fromEnvironment('GOOGLE_CLIENT_ID');
  static bool get available => kIsWeb && clientId.isNotEmpty;

  @override
  State<GoogleButton> createState() => _GoogleButtonState();
}

class _GoogleButtonState extends State<GoogleButton> {
  bool _ready = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (GoogleButton.available) _start();
  }

  Future<void> _start() async {
    try {
      await GoogleSignIn.instance.initialize(clientId: GoogleButton.clientId);
      GoogleSignIn.instance.authenticationEvents.listen(_onEvent, onError: (_) {});
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      // Google's script blocked, offline, or a bad client id: leave the button out rather than show a dead one.
    }
  }

  Future<void> _onEvent(GoogleSignInAuthenticationEvent event) async {
    if (event is! GoogleSignInAuthenticationEventSignIn) return;
    final idToken = event.user.authentication.idToken;
    if (idToken == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.read<AppState>().signInWithGoogle(idToken);
    } on ApiException catch (e) {
      widget.onError?.call(e.message);
    } catch (_) {
      widget.onError?.call('Could not sign in with Google. Try your email and password.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!GoogleButton.available || !_ready) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(children: [
      const SizedBox(height: 20),
      if (_busy)
        const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator())
      else
        googleSignInButton(),
      const SizedBox(height: 18),
      Row(children: [
        const Expanded(child: Divider()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text('or use your email', style: theme.textTheme.bodySmall),
        ),
        const Expanded(child: Divider()),
      ]),
      const SizedBox(height: 4),
    ]);
  }
}
