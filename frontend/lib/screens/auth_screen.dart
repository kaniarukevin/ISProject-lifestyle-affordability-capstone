import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api.dart';
import '../state/app_state.dart';
import 'privacy_screen.dart';

/// First screen for a new user: create an account or log in.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _newAccount = true;
  bool _agreed = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (!email.contains('@') || password.length < 8) {
      setState(() => _error = 'Enter your email and a password of at least 8 characters.');
      return;
    }
    if (_newAccount && !_agreed) {
      setState(() => _error = 'Please read and agree to the privacy notice to create an account.');
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              Icon(Icons.account_balance_wallet, size: 56, color: theme.colorScheme.primary),
              const SizedBox(height: 12),
              Text('Lifestyle Affordability', textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text('Know what you can afford before you commit.',
                  textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 24),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Create account')),
                  ButtonSegment(value: false, label: Text('Log in')),
                ],
                selected: {_newAccount},
                onSelectionChanged: (s) => setState(() {
                  _newAccount = s.first;
                  _error = null;
                }),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: InputDecoration(
                    labelText: 'Password', helperText: _newAccount ? 'At least 8 characters' : null),
                onSubmitted: (_) => _submit(),
              ),
              if (_newAccount)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(children: [
                    Checkbox(value: _agreed, onChanged: (v) => setState(() => _agreed = v ?? false)),
                    const Expanded(child: Text('I have read and agree to how my data is used.')),
                    TextButton(
                      onPressed: () => showPrivacy(context, context.read<AppState>().api),
                      child: const Text('Read'),
                    ),
                  ]),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(_newAccount ? 'Create account' : 'Log in'),
              ),
              const SizedBox(height: 12),
              Text('Only you can see your data, statement files are never kept, and you can delete '
                  'everything at any time.',
                  textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}
