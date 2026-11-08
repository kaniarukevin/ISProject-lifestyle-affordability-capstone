import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/busy_words.dart';
import 'password_field.dart';

/// Forgot password: (1) the email, (2) the 6-digit code from the email and a new password. On success the user
/// is logged in on this device and every other device is logged out.
class ForgotScreen extends StatefulWidget {
  const ForgotScreen({super.key, this.email = ''});
  final String email;

  @override
  State<ForgotScreen> createState() => _ForgotScreenState();
}

class _ForgotScreenState extends State<ForgotScreen> {
  late final _email = TextEditingController(text: widget.email);
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _sent = false;
  bool _busy = false;
  String? _note;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() job) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await job();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() => _run(() async {
        final email = _email.text.trim();
        if (!email.contains('@')) throw ApiException('Enter the email you signed up with.');
        final msg = await context.read<AppState>().api.forgotPassword(email);
        if (mounted) {
          setState(() {
            _sent = true;
            _note = msg;
          });
        }
      });

  Future<void> _reset() => _run(() async {
        final code = _code.text.trim();
        if (!RegExp(r'^\d{6}$').hasMatch(code)) throw ApiException('The code is the 6 digits in the email.');
        if (_password.text.length < 8) throw ApiException('Choose a new password of at least 8 characters.');
        final state = context.read<AppState>();
        final nav = Navigator.of(context);
        await state.resetPassword(_email.text.trim(), code, _password.text);
        nav.popUntil((r) => r.isFirst);       // the app opens on its own now that this device is logged in
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Reset your password')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                  _sent
                      ? (_note ?? 'Check your email for a 6-digit code.')
                      : "Enter your email and we'll send you a 6-digit code.",
                  style: theme.textTheme.bodyLarge),
              const SizedBox(height: 16),
              TextField(
                controller: _email,
                enabled: !_sent,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              if (_sent) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  maxLength: 6,
                  decoration: const InputDecoration(labelText: '6-digit code', counterText: ''),
                ),
                const SizedBox(height: 14),
                PasswordField(
                  controller: _password,
                  label: 'New password',
                  helper: 'At least 8 characters',
                  autofillHints: const [AutofillHints.newPassword],
                  onSubmitted: (_) => _reset(),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                ),
              const SizedBox(height: 20),
              FilledButton(
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(54),
                    backgroundColor: AppColors.of(context).lime,
                    foregroundColor: AppColors.of(context).onLime),
                onPressed: _busy ? null : (_sent ? _reset : _send),
                child: _busy
                    ? BusyWords(lines: _sent ? resetWords : sendCodeWords)
                    : Text(_sent ? 'Set new password' : 'Send code'),
              ),
              if (_sent)
                TextButton(
                  onPressed: _busy ? null : _send,
                  child: const Text('Send a new code'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
