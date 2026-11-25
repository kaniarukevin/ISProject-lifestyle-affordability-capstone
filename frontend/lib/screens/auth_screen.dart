import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../widgets/google_button.dart';
import '../services/api.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/busy_words.dart';
import '../widgets/tosha_logo.dart';
import 'forgot_screen.dart';
import 'password_field.dart';
import 'privacy_screen.dart';

/// The landing page: log in (the default) or create an account. Wide screens get the black side banner with what
/// Tosha does; phones get a short version of it above the form.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _newAccount = false;          // most people opening the app already have an account
  bool _agreed = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    context.read<AppState>().api.wake();   // start waking the server while they type
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _switch() => setState(() {
        _newAccount = !_newAccount;
        _error = null;
      });

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (!email.contains('@')) {
      setState(() => _error = 'Enter your email address.');
      return;
    }
    if (password.length < 8) {
      setState(() => _error = 'Passwords are at least 8 characters.');
      return;
    }
    if (_newAccount && !_agreed) {
      setState(() => _error = 'Please read and agree to how your data is used to create an account.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final app = context.read<AppState>();
      await app.signIn(email, password, newAccount: _newAccount, consent: _agreed);
      // Tell the browser the sign-in form is done, so Google Password Manager saves the password at once
      // instead of waiting on a form that has already left the screen (it used to hang).
      TextInput.finishAutofillContext();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Pill fields like the reference designs (25 Nov): rounded, filled, an icon in front.
  InputDecorationThemeData _pillFields(BuildContext context, {required bool dark}) {
    final c = AppColors.of(context);
    OutlineInputBorder line(Color color, [double w = 1]) =>
        OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide(color: color, width: w));
    final fill = dark ? const Color(0xFF1C1C1C) : Theme.of(context).colorScheme.surface;
    final edge = dark ? const Color(0xFF2A2A2A) : c.muted.withValues(alpha: 0.35);
    return Theme.of(context).inputDecorationTheme.copyWith(
          filled: true,
          fillColor: fill,
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          border: line(edge),
          enabledBorder: line(edge),
          focusedBorder: line(c.lime, 1.6),
          prefixIconColor: dark ? c.lime : c.muted,
        );
  }

  Widget _form(BuildContext context, {required bool dark}) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final ink = dark ? Colors.white : theme.colorScheme.onSurface;
    final quiet = dark ? Colors.white.withValues(alpha: 0.6) : c.muted;
    final link = dark ? c.lime : theme.colorScheme.onSurface;
    return Theme(
      data: theme.copyWith(inputDecorationTheme: _pillFields(context, dark: dark)),
      child: AutofillGroup(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(_newAccount ? 'Create your account' : 'Welcome back',
              style: theme.textTheme.headlineMedium?.copyWith(color: ink, fontWeight: FontWeight.w700, letterSpacing: -0.6)),
          const SizedBox(height: 6),
          Text(_newAccount ? 'Two minutes to your first answer.' : 'Log in to see how your money is doing.',
              style: theme.textTheme.bodyLarge?.copyWith(color: quiet)),
          const SizedBox(height: 28),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            textInputAction: TextInputAction.next,
            style: TextStyle(color: ink),
            decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.mail_rounded)),
          ),
          const SizedBox(height: 14),
          PasswordField(
            controller: _password,
            prefixIcon: const Icon(Icons.lock_rounded),
            helper: _newAccount ? '8+ characters, not a common one' : null,
            autofillHints: [_newAccount ? AutofillHints.newPassword : AutofillHints.password],
            onSubmitted: (_) => _submit(),
          ),
          if (!_newAccount)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                style: TextButton.styleFrom(foregroundColor: link),
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => ForgotScreen(email: _email.text.trim()))),
                child: const Text('Forgot password?'),
              ),
            ),
          if (_newAccount) ...[
            const SizedBox(height: 8),
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _agreed = !_agreed),
              child: Row(children: [
                Checkbox(value: _agreed, onChanged: (v) => setState(() => _agreed = v ?? false)),
                Expanded(child: Text('I agree to how my data is used', style: TextStyle(color: ink))),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: link),
                  onPressed: () => showPrivacy(context, context.read<AppState>().api),
                  child: const Text('Read'),
                ),
              ]),
            ),
          ],
          if (_error != null)
            Container(
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(color: c.warnBg, borderRadius: BorderRadius.circular(14)),
              child: Text(_error!, style: TextStyle(color: c.warn)),
            ),
          const SizedBox(height: 18),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: c.lime, foregroundColor: c.onLime, minimumSize: const Size.fromHeight(56),
                shape: const StadiumBorder()),
            onPressed: _busy ? null : _submit,
            child: _busy
                ? BusyWords(lines: _newAccount ? signUpWords : logInWords)
                : Text(_newAccount ? 'Create account' : 'Log in',
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          ),
          const SizedBox(height: 18),
          GoogleButton(onError: (m) => setState(() => _error = m)),
          const SizedBox(height: 18),
          Wrap(alignment: WrapAlignment.center, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(_newAccount ? 'Already have an account?' : 'Don\'t have an account yet?', style: TextStyle(color: quiet)),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: link),
              onPressed: _busy ? null : _switch,
              child: Text(_newAccount ? 'Log in' : 'Sign up', style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.lock_outline_rounded, size: 14, color: quiet),
            const SizedBox(width: 6),
            Text(_newAccount ? 'Only you see your data · Guidance, not financial advice' : 'Only you see your data',
                style: theme.textTheme.bodySmall?.copyWith(color: quiet)),
          ]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        if (box.maxWidth >= 900) {
          // Desktop (reference 2): the form alone on the left, the promise on a dark panel on the right.
          // 25 Nov: the phone's lime glow kept on desktop too, behind the form side.
          final dark = Theme.of(context).brightness == Brightness.dark;
          final bg = dark ? const Color(0xFF0B0B0B) : Theme.of(context).scaffoldBackgroundColor;
          return Scaffold(
            backgroundColor: bg,
            body: DecoratedBox(
             decoration: BoxDecoration(
               gradient: RadialGradient(
                 center: const Alignment(-1.05, -1.1),
                 radius: 1.2,
                 colors: [AppColors.of(context).lime.withValues(alpha: dark ? 0.28 : 0.45), bg.withValues(alpha: 0)],
               ),
             ),
             child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Padding(
                          padding: const EdgeInsets.fromLTRB(24, 16, 0, 0),
                          child: _Brand(onDark: Theme.of(context).brightness == Brightness.dark)),
                      Expanded(
                        child: Center(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(32),
                            child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 400),
                                child: _form(context, dark: Theme.of(context).brightness == Brightness.dark)),
                          ),
                        ),
                      ),
                    ]),
                  ),
                  const Expanded(child: _Banner()),
                ]),
              ),
            ),
          ),
          );
        }
        // Phone (reference 1): follows the app's light or dark mode. Dark = the reference: near-black with a lime glow;
        // light = the same layout on the stone background with a softer glow.
        final dark = Theme.of(context).brightness == Brightness.dark;
        final bg = dark ? const Color(0xFF0B0B0B) : Theme.of(context).scaffoldBackgroundColor;
        return Scaffold(
          backgroundColor: bg,
          body: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-1.1, -1.05),
                radius: 1.1,
                colors: [AppColors.of(context).lime.withValues(alpha: dark ? 0.28 : 0.45), bg.withValues(alpha: 0)],
              ),
            ),
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      _Brand(onDark: dark),
                      const SizedBox(height: 56),
                      _form(context, dark: dark),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        );
      });
}

/// Logo and name, the same on every screen size.
class _Brand extends StatelessWidget {
  const _Brand({this.onDark = false});
  final bool onDark;

  @override
  Widget build(BuildContext context) => Row(children: [
        // 25 Nov: on a light screen the lime ring vanished into the lime glow, so it sits on a black badge there
        // (as the app's own sidebar shows it).
        if (onDark)
          const ToshaLogo(size: 34)
        else
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(color: const Color(0xFF111111), borderRadius: BorderRadius.circular(12)),
            child: const ToshaLogo(size: 30),
          ),
        const SizedBox(width: 10),
        Text('Tosha',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700, color: onDark ? Colors.white : null)),
      ]);
}

/// Desktop only: a dark panel with the promise and a sample of what the app shows.
class _Banner extends StatelessWidget {
  const _Banner();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(48),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [const Color(0xFF1A2108), const Color(0xFF0B0B0B), Color.lerp(const Color(0xFF0B0B0B), c.lime, 0.12)!],
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Spacer(),
        Text('Know if it\'s\nenough.',
            style: theme.textTheme.displayMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.w700, letterSpacing: -1.5, height: 1.05)),
        const SizedBox(height: 14),
        Text('Check big decisions against your M-PESA first.',
            style: theme.textTheme.titleMedium?.copyWith(color: Colors.white.withValues(alpha: 0.7))),
        const Spacer(),
        // A sample card, the way Home shows a score: what the person gets, not a list of features.
        Align(
          alignment: Alignment.bottomRight,
          child: Container(
            width: 300,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: c.lime, borderRadius: BorderRadius.circular(24)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Your money score', style: TextStyle(color: c.onLime.withValues(alpha: 0.75))),
              const SizedBox(height: 4),
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('72', style: theme.textTheme.displaySmall?.copyWith(color: c.onLime, fontWeight: FontWeight.w700)),
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 6),
                  child: Text('/ 100', style: TextStyle(color: c.onLime.withValues(alpha: 0.75))),
                ),
              ]),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: const Color(0x14000000), borderRadius: BorderRadius.circular(14)),
                child: Row(children: [
                  Icon(Icons.verified_user_rounded, size: 18, color: c.onLime),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Phone on credit: Affordable',
                        style: TextStyle(color: c.onLime, fontWeight: FontWeight.w600)),
                  ),
                ]),
              ),
              const SizedBox(height: 6),
              Text('Example', style: theme.textTheme.bodySmall?.copyWith(color: c.onLime.withValues(alpha: 0.6))),
            ]),
          ),
        ),
      ]),
    );
  }
}
