import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api.dart';
import '../state/app_state.dart';

/// The privacy notice, loaded from the server so there is one version of it (GET /privacy).
class PrivacyNotice extends StatelessWidget {
  const PrivacyNotice({super.key, required this.notice});
  final Map<String, dynamic> notice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sections = ((notice['sections'] as List?) ?? []).cast<Map<String, dynamic>>();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final s in sections) ...[
        Text(s['title'] as String, style: theme.textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(s['text'] as String),
        const SizedBox(height: 12),
      ],
      Text('Version ${notice['version']}', style: theme.textTheme.bodySmall),
    ]);
  }
}

/// Read-only view of the notice (from the sign-up screen and from Your household).
Future<void> showPrivacy(BuildContext context, Api api) => Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Privacy')),
        body: FutureBuilder<Map<String, dynamic>>(
          future: api.privacy(),
          builder: (context, snap) => snap.hasError
              ? const Padding(padding: EdgeInsets.all(24), child: Text('Could not load the notice. Check your connection.'))
              : !snap.hasData
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(padding: const EdgeInsets.all(16), children: [PrivacyNotice(notice: snap.data!)]),
        ),
      ),
    ));

/// Shown once to a signed-in user who has not agreed to the current notice (older accounts, or a new version).
class ConsentScreen extends StatefulWidget {
  const ConsentScreen({super.key});

  @override
  State<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends State<ConsentScreen> {
  late final Future<Map<String, dynamic>> _notice = context.read<AppState>().api.privacy();
  bool _busy = false;
  String? _error;

  Future<void> _agree(String version) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AppState>().acceptPrivacy(version);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Before you continue')),
        body: FutureBuilder<Map<String, dynamic>>(
          future: _notice,
          builder: (context, snap) {
            if (snap.hasError) {
              return const Padding(padding: EdgeInsets.all(24), child: Text('Could not load the notice. Check your connection.'));
            }
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final notice = snap.data!;
            return ListView(padding: const EdgeInsets.all(16), children: [
              Text(notice['title'] as String, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              PrivacyNotice(notice: notice),
              if (_error != null)
                Padding(padding: const EdgeInsets.only(top: 8),
                    child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
              const SizedBox(height: 16),
              FilledButton(onPressed: _busy ? null : () => _agree(notice['version'] as String),
                  child: const Text('I agree')),
              TextButton(onPressed: () => context.read<AppState>().logOut(), child: const Text('No thanks, log out')),
            ]);
          },
        ),
      );
}

/// Delete the account and everything in it, after a clear confirmation. Returns when signed out.
Future<void> confirmDeleteAccount(BuildContext context) async {
  final state = context.read<AppState>();
  final sure = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete your account?'),
      content: const Text('This removes your account and everything in it: your household, spending, imported '
          'statements, budgets, checks and tags. It cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep my account')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Delete everything'),
        ),
      ],
    ),
  );
  if (sure != true || !context.mounted) return;
  try {
    await state.deleteAccount();
    if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  } on ApiException catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
  }
}
