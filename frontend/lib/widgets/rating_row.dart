import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'panel.dart';

/// "Does this match your real finances?" on a 1 to 5 scale: the volunteers' judgement of the outputs that the
/// study reports (deviation D16). One tap, then a thank-you. The overview asks again after two weeks; a check is
/// asked once.
class RatingCard extends StatefulWidget {
  const RatingCard({super.key, required this.where, this.scenarioId, this.question});
  final String where;          // overview | afford
  final int? scenarioId;
  final String? question;

  @override
  State<RatingCard> createState() => _RatingCardState();
}

class _RatingCardState extends State<RatingCard> {
  bool? _show;                 // null while checking whether it was answered recently
  int? _picked;
  bool _sending = false;

  String get _key => widget.scenarioId != null ? 'rated_afford_${widget.scenarioId}' : 'rated_${widget.where}';

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final prefs = await SharedPreferences.getInstance();
    final at = DateTime.tryParse(prefs.getString(_key) ?? '');
    final recent = at != null && (widget.scenarioId != null || DateTime.now().difference(at).inDays < 14);
    if (mounted) setState(() => _show = !recent);
  }

  Future<void> _rate(int score) async {
    setState(() {
      _picked = score;
      _sending = true;
    });
    try {
      await context.read<AppState>().api.rate(widget.where, score, scenarioId: widget.scenarioId);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, DateTime.now().toIso8601String());
    } on ApiException {
      if (mounted) setState(() => _picked = null);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_show != true) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final done = _picked != null && !_sending;
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.question ?? 'Does this match your real finances?', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(done ? 'Thank you. Your answer helps test whether Tosha gets it right.' : '1 is not at all, 5 is exactly.',
            style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
        const SizedBox(height: 12),
        Row(children: [
          for (var i = 1; i <= 5; i++) ...[
            if (i > 1) const SizedBox(width: 8),
            Expanded(
              child: Semantics(
                button: true,
                selected: _picked == i,
                label: '$i out of 5',
                excludeSemantics: true,
                child: Material(
                  color: _picked == i ? c.lime : c.field,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: _sending || done ? null : () => _rate(i),
                    child: SizedBox(
                      height: 44,
                      child: Center(
                        child: Text('$i',
                            style: TextStyle(fontWeight: FontWeight.w700, color: _picked == i ? c.onLime : null)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ]),
      ]),
    );
  }
}
