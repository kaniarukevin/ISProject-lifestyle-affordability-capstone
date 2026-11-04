import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api.dart';
import '../state/app_state.dart';

/// Admin view (scoped down from the proposal's five admin functions): is the service healthy, which models are
/// deployed and how good they are, and who is using the app. Users appear with masked emails and counts only.
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  Map<String, dynamic>? d;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<AppState>().api.adminOverview();
      setState(() {
        d = r;
        error = null;
      });
    } on ApiException catch (e) {
      setState(() => error = e.message);
    }
  }

  Widget _stat(String label, Object? value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(label)),
          Text('$value', style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
      );

  Widget _card(String title, List<Widget> children) => Card(
        margin: const EdgeInsets.only(top: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...children,
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (d == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Admin')),
        body: Center(child: error != null ? Text(error!) : const CircularProgressIndicator()),
      );
    }
    final s = (d!['service'] as Map).cast<String, dynamic>();
    final u = (d!['users'] as Map).cast<String, dynamic>();
    final models = (d!['models'] as List).cast<Map<String, dynamic>>();
    final users = (d!['recent_users'] as List).cast<Map<String, dynamic>>();
    final healthy = s['status'] == 'ok' && s['forecast_data_loaded'] != false && models.every((m) => m['present'] == true);
    return Scaffold(
      appBar: AppBar(title: const Text('Admin')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _card('Service health', [
              Row(children: [
                Icon(healthy ? Icons.check_circle : Icons.error_outline,
                    color: healthy ? Colors.green.shade700 : theme.colorScheme.error),
                const SizedBox(width: 8),
                Text(healthy ? 'All systems working' : 'Something needs attention'),
              ]),
              const SizedBox(height: 6),
              _stat('API', s['status']),
              _stat('Database', s['database']),
              _stat('Web Masters forecast data', s['forecast_data_loaded'] == true ? 'loaded' : 'not loaded'),
              if (s['forecast_error'] != null) Text('${s['forecast_error']}', style: TextStyle(color: theme.colorScheme.error)),
            ]),
            _card('Users', [
              _stat('Accounts', u['total']),
              _stat('Set up a household', u['with_household']),
              _stat('Uploaded a statement', u['with_statement']),
              _stat('Joined in the last 7 days', u['joined_7_days']),
              _stat('Spending records', u['records']),
              _stat('Affordability checks', u['affordability_checks']),
            ]),
            _card('Model register', models.map((m) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(m['present'] == true ? Icons.check_circle_outline : Icons.error_outline, size: 18,
                          color: m['present'] == true ? Colors.green.shade700 : theme.colorScheme.error),
                      const SizedBox(width: 6),
                      Expanded(child: Text(m['name'] as String, style: const TextStyle(fontWeight: FontWeight.w600))),
                    ]),
                    Text('${m['kind']} · ${m['metric']}', style: theme.textTheme.bodySmall),
                    Text('Trained on: ${m['data']} · ${m['file']}'
                        '${m['size_mb'] != null ? ' (${m['size_mb']} MB, ${m['updated']})' : ' (missing)'}',
                        style: theme.textTheme.bodySmall),
                  ]),
                )).toList()),
            _card('Recent users', [
              Text('Masked emails and counts only; no one\'s spending, income or payees.', style: theme.textTheme.bodySmall),
              const SizedBox(height: 6),
              ...users.map((x) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      Expanded(child: Text('${x['email']}  ·  joined ${x['joined']}')),
                      Text('${x['records']} records${x['statement'] == true ? ' · statement' : ''}'
                          '${x['household'] == true ? '' : ' · no household'}', style: theme.textTheme.bodySmall),
                    ]),
                  )),
            ]),
          ],
        ),
      ),
    );
  }
}
