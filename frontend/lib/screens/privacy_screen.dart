import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/panel.dart';

IconData _iconFor(String title) => switch (title.toLowerCase()) {
      final t when t.startsWith('who runs') => Icons.school_outlined,
      final t when t.contains('never') => Icons.delete_sweep_outlined,
      final t when t.startsWith('what we keep') => Icons.inventory_2_outlined,
      final t when t.startsWith('why') => Icons.lightbulb_outline,
      final t when t.startsWith('where') => Icons.cloud_outlined,
      final t when t.startsWith('who can') => Icons.visibility_outlined,
      final t when t.startsWith('your rights') => Icons.gavel_outlined,
      final t when t.startsWith('how long') => Icons.schedule_outlined,
      _ => Icons.info_outline,
    };

String _date(String iso) {
  const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October',
      'November', 'December'];
  final d = DateTime.tryParse(iso);
  return d == null ? iso : '${d.day} ${months[d.month - 1]} ${d.year}';
}

/// The privacy notice, loaded from the server so there is one version of it (GET /privacy).
/// Each section is its own card; [actions] adds Download and Delete under "Your rights" (not on the sign-up view).
class PrivacyNotice extends StatelessWidget {
  const PrivacyNotice({super.key, required this.notice, this.actions = false});
  final Map<String, dynamic> notice;
  final bool actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final sections = ((notice['sections'] as List?) ?? []).cast<Map<String, dynamic>>();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 12, children: [
      Panel(
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: c.lime, borderRadius: BorderRadius.circular(12)),
            child: Icon(Icons.lock_outline, color: c.onLime),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(notice['title'] as String? ?? 'How Tosha uses your data', style: theme.textTheme.titleMedium),
              const SizedBox(height: 2),
              Text('Version of ${_date(notice['version'] as String? ?? '')}',
                  style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
            ]),
          ),
        ]),
      ),
      for (final s in sections) _Section(section: s, actions: actions),
    ]);
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.section, required this.actions});
  final Map<String, dynamic> section;
  final bool actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final title = section['title'] as String;
    final never = title.toLowerCase().contains('never');
    final rights = title.toLowerCase().startsWith('your rights');
    final ink = never ? c.onLime : null;
    return Panel(
      color: never ? c.lime : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(_iconFor(title), size: 20, color: ink ?? theme.colorScheme.onSurface),
          const SizedBox(width: 10),
          Expanded(child: Text(title, style: theme.textTheme.titleSmall?.copyWith(color: ink))),
        ]),
        const SizedBox(height: 8),
        Text(section['text'] as String, style: theme.textTheme.bodyMedium?.copyWith(color: ink, height: 1.45)),
        if (rights && actions) ...[
          const SizedBox(height: 14),
          Wrap(spacing: 10, runSpacing: 10, children: [
            OutlinedButton.icon(
              onPressed: () => downloadMyData(context),
              icon: const Icon(Icons.download_outlined, size: 18),
              label: const Text('Download my data'),
            ),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
              onPressed: () => confirmDeleteAccount(context),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Delete my account'),
            ),
          ]),
        ],
      ]),
    );
  }
}

Widget _loading(AsyncSnapshot snap, Widget Function(Map<String, dynamic>) done) => snap.hasError
    ? const Padding(padding: EdgeInsets.all(24), child: Text('Could not load the notice. Check your connection.'))
    : !snap.hasData
        ? const Center(child: CircularProgressIndicator())
        : done(snap.data as Map<String, dynamic>);

/// Read-only view of the notice (from the sign-up screen and from You). Signed in, it also offers the rights actions.
Future<void> showPrivacy(BuildContext context, Api api) {
  final signedIn = context.read<AppState>().profile != null;
  return Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => Scaffold(
      appBar: AppBar(title: const Text('Privacy')),
      body: FutureBuilder<Map<String, dynamic>>(
        future: api.privacy(),
        builder: (context, snap) => _loading(
          snap,
          (notice) => ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
            PageWidth(child: PrivacyNotice(notice: notice, actions: signedIn)),
          ]),
        ),
      ),
    ),
  ));
}

/// Shown once to a signed-in user who has not agreed to the current notice (older accounts, or a new version).
/// "I agree" stays fixed at the bottom so nobody has to scroll to find it.
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Before you continue'), automaticallyImplyLeading: false),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _notice,
        builder: (context, snap) => _loading(
          snap,
          (notice) => Column(children: [
            Expanded(
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), children: [
                PageWidth(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('Please read how your data is used. You can delete your account and everything in it at '
                        'any time.', style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 12),
                    PrivacyNotice(notice: notice),
                  ]),
                ),
              ]),
            ),
            Material(
              color: theme.colorScheme.surface,
              elevation: 6,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: PageWidth(
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                        ),
                      FilledButton(
                        onPressed: _busy ? null : () => _agree(notice['version'] as String),
                        child: Text(_busy ? 'Saving…' : 'I agree'),
                      ),
                      TextButton(
                        onPressed: _busy ? null : () => context.read<AppState>().logOut(),
                        child: const Text('No thanks, log out'),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Save everything the app keeps about the user as a JSON file (downloads on the web, a save dialog on phones).
Future<void> downloadMyData(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final data = await context.read<AppState>().api.exportData();
    final now = DateTime.now();
    final name = 'my-tosha-data-${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}.json';
    final bytes = Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(data)));
    final saved = await FilePicker.saveFile(dialogTitle: 'Save your data', fileName: name, bytes: bytes);
    if (saved != null) messenger.showSnackBar(SnackBar(content: Text('Saved $name')));
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  }
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
