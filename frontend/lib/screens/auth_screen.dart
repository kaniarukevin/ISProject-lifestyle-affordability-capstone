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

  /// "Log in | Create account" at the top, so switching is one obvious tap instead of a link under the button.
  Widget _modeSwitch(AppColors c) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: c.field, borderRadius: BorderRadius.circular(16)),
        child: Row(children: [
          for (final (isNew, label) in const [(false, 'Log in'), (true, 'Create account')])
            Expanded(
              child: GestureDetector(
                onTap: _busy || _newAccount == isNew ? null : _switch,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  decoration: BoxDecoration(
                    color: _newAccount == isNew ? Theme.of(context).colorScheme.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: _newAccount == isNew
                        ? const [BoxShadow(color: Color(0x14000000), blurRadius: 6, offset: Offset(0, 2))]
                        : null,
                  ),
                  child: Text(label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontWeight: FontWeight.w600, color: _newAccount == isNew ? null : c.muted)),
                ),
              ),
            ),
        ]),
      );

  Widget _form(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return AutofillGroup(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        _modeSwitch(c),
        const SizedBox(height: 24),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: 'Email'),
        ),
        const SizedBox(height: 12),
        PasswordField(
          controller: _password,
          helper: _newAccount ? '8+ characters, not a common one' : null,
          autofillHints: [_newAccount ? AutofillHints.newPassword : AutofillHints.password],
          onSubmitted: (_) => _submit(),
        ),
        if (!_newAccount)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
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
              const Expanded(child: Text('I agree to how my data is used')),
              TextButton(
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
        const SizedBox(height: 16),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: c.lime, foregroundColor: c.onLime, minimumSize: const Size.fromHeight(54)),
          onPressed: _busy ? null : _submit,
          child: _busy
              ? BusyWords(lines: _newAccount ? signUpWords : logInWords)
              : Text(_newAccount ? 'Create account' : 'Log in',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        ),
        if (GoogleButton.available) ...[
          const SizedBox(height: 18),
          Row(children: [
            const Expanded(child: Divider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('or', style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
            ),
            const Expanded(child: Divider()),
          ]),
          const SizedBox(height: 14),
          GoogleButton(onError: (m) => setState(() => _error = m)),
        ],
        const SizedBox(height: 20),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.lock_outline_rounded, size: 14, color: c.muted),
          const SizedBox(width: 6),
          Text(_newAccount ? 'Only you see your data · Guidance, not financial advice' : 'Only you see your data',
              style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
        ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: LayoutBuilder(builder: (context, box) {
            final form = ConstrainedBox(constraints: const BoxConstraints(maxWidth: 400), child: _form(context));
            if (box.maxWidth >= 900) {
              // Desktop: the black panel on the left says what Tosha is; the form sits alone on the right.
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Expanded(child: _Banner()),
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(padding: const EdgeInsets.all(32), child: form),
                    ),
                  ),
                ]),
              );
            }
            // Phone: the name, one promise, and the form. Nothing else competes with it.
            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const _Brand(),
                    const SizedBox(height: 28),
                    Text("Know if it's enough.",
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w700, letterSpacing: -0.8)),
                    const SizedBox(height: 6),
                    Text('Check big decisions against your M-PESA first.',
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: AppColors.of(context).muted)),
                    const SizedBox(height: 28),
                    form,
                  ]),
                ),
              ),
            );
          }),
        ),
      );
}

/// Logo and name, the same on every screen size.
class _Brand extends StatelessWidget {
  const _Brand({this.onDark = false});
  final bool onDark;

  @override
  Widget build(BuildContext context) => Row(children: [
        const ToshaLogo(size: 36),
        const SizedBox(width: 10),
        Text('Tosha',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700, color: onDark ? Colors.white : null)),
      ]);
}

/// Desktop only: the black panel with the promise and three one-line points.
class _Banner extends StatelessWidget {
  const _Banner();

  static const _points = [
    (Icons.verified_user_rounded, 'Test a loan, a move or a big buy before you commit'),
    (Icons.insights_rounded, 'See how your money is really doing'),
    (Icons.account_balance_wallet_rounded, 'A budget built from how you actually spend'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final muted = Colors.white.withValues(alpha: 0.7);
    return Container(
      padding: const EdgeInsets.all(48),
      decoration: BoxDecoration(color: const Color(0xFF111111), borderRadius: BorderRadius.circular(32)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const _Brand(onDark: true),
        const Spacer(),
        Text("Know if it's enough.",
            style: Theme.of(context).textTheme.displaySmall
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.w700, letterSpacing: -1, height: 1.1)),
        const SizedBox(height: 12),
        Text('Check big decisions against your M-PESA first.',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(color: muted)),
        const SizedBox(height: 36),
        for (final (icon, text) in _points)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(color: c.lime, shape: BoxShape.circle),
                child: Icon(icon, size: 16, color: c.onLime),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(text, style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Colors.white)),
              ),
            ]),
          ),
        const Spacer(),
        Text('You\'ll need your M-PESA statement (free from Safaricom).',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: muted)),
      ]),
    );
  }
}
