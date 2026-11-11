import 'package:flutter/material.dart';
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
      await context.read<AppState>().signIn(email, password, newAccount: _newAccount, consent: _agreed);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _form(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return AutofillGroup(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text(_newAccount ? 'Create your account' : 'Welcome back', style: theme.textTheme.headlineMedium),
        const SizedBox(height: 6),
        Text(
            _newAccount
                ? 'It takes about two minutes, and Tosha gives you a first answer straight away.'
                : 'Log in to see your score, your budget and what you can afford.',
            style: theme.textTheme.bodyLarge?.copyWith(color: c.muted)),
        const SizedBox(height: 28),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
              labelText: 'Email',
              helperText: 'Only used to sign you in and to reset your password. No marketing.',
              helperMaxLines: 2),
        ),
        const SizedBox(height: 14),
        PasswordField(
          controller: _password,
          helper: _newAccount ? 'At least 8 characters' : null,
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
          const SizedBox(height: 14),
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _agreed = !_agreed),
            child: Row(children: [
              Checkbox(value: _agreed, onChanged: (v) => setState(() => _agreed = v ?? false)),
              const Expanded(child: Text('I agree to how my data is used.')),
              TextButton(
                onPressed: () => showPrivacy(context, context.read<AppState>().api),
                child: const Text('Read it'),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 4),
            child: Text(
                "Tosha's advice comes from statistical models built mostly on survey and simulated data. It is "
                'guidance, not financial advice, and it can be wrong.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.muted)),
          ),
        ],
        if (_error != null)
          Container(
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(color: c.warnBg, borderRadius: BorderRadius.circular(14)),
            child: Text(_error!, style: TextStyle(color: c.warn)),
          ),
        const SizedBox(height: 20),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: c.lime, foregroundColor: c.onLime, minimumSize: const Size.fromHeight(54)),
          onPressed: _busy ? null : _submit,
          child: _busy
              ? BusyWords(lines: _newAccount ? signUpWords : logInWords)
              : Text(_newAccount ? 'Create account' : 'Log in'),
        ),
        const SizedBox(height: 16),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(_newAccount ? 'Already have an account?' : 'New to Tosha?', style: TextStyle(color: c.muted)),
          TextButton(
            onPressed: _busy ? null : _switch,
            child: Text(_newAccount ? 'Log in' : 'Create an account'),
          ),
        ]),
        // Google goes last, under the email form, which is where people look for it.
        GoogleButton(onError: (m) => setState(() => _error = m)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: LayoutBuilder(builder: (context, box) {
            final form = Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(28),
                child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: _form(context)),
              ),
            );
            if (box.maxWidth >= 900) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Expanded(child: _Banner()),
                  Expanded(child: form),
                ]),
              );
            }
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(children: [
                const _Banner(compact: true),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 28, 8, 0),
                  child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: _form(context)),
                ),
              ]),
            );
          }),
        ),
      );
}

/// The black side of the landing page: the name, the promise and what Tosha does.
class _Banner extends StatelessWidget {
  const _Banner({this.compact = false});
  final bool compact;

  static const _points = [
    (Icons.verified_user_rounded, 'Ask "Can I afford it?" before you take a loan, move house or buy something big.'),
    (Icons.insights_rounded, 'See how your money is really doing, read from your own M-PESA statement.'),
    (Icons.account_balance_wallet_rounded, 'A budget built from the way you actually spend, not a fixed rule.'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    const white = Colors.white;
    final muted = Colors.white.withValues(alpha: 0.7);
    final head = Row(children: [
      const ToshaLogo(size: 40),
      const SizedBox(width: 12),
      Text('Tosha', style: Theme.of(context).textTheme.titleLarge?.copyWith(color: white)),
    ]);
    return Container(
      padding: EdgeInsets.all(compact ? 24 : 48),
      decoration: BoxDecoration(color: const Color(0xFF111111), borderRadius: BorderRadius.circular(32)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
        children: [
          head,
          SizedBox(height: compact ? 20 : 0),
          if (!compact) const Spacer(),
          Text("Know if it's enough.",
              style: (compact ? Theme.of(context).textTheme.headlineMedium : Theme.of(context).textTheme.displaySmall)
                  ?.copyWith(color: white, fontWeight: FontWeight.w700, letterSpacing: -1, height: 1.1)),
          const SizedBox(height: 12),
          Text('Tosha reads your M-PESA statement and shows you what your money is really doing. Then it checks a '
              'big decision against it, before you make it.',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: muted)),
          // 11 Nov: these three points were drawn only on a wide screen, so phone users, which is everyone,
          // reached the password box without ever being told what the app does.
          SizedBox(height: compact ? 20 : 32),
          for (final (icon, text) in _points)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: c.lime, shape: BoxShape.circle),
                    child: Icon(icon, size: 18, color: c.onLime),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(text, style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: white)),
                    ),
                  ),
                ]),
              ),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(16)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.schedule_rounded, size: 18, color: c.lime),
              const SizedBox(width: 12),
              Expanded(
                child: Text('You will need your M-PESA statement. Asking Safaricom for it is free and takes about '
                    'five minutes. Setting up takes about ten.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: white)),
              ),
            ]),
          ),
          if (!compact) const Spacer(),
          SizedBox(height: compact ? 16 : 24),
          Text('Only you see your data. Tosha never moves your money, never messages anyone, and never shares what '
              'it reads. Statement files are not kept, and you can delete everything at any time.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: muted)),
        ],
      ),
    );
  }
}
