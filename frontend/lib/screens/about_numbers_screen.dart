import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/panel.dart';
import '../widgets/tosha_logo.dart';

/// "About these numbers": which models make Tosha's figures, what they learned from, and what they cannot do.
/// Opened from You and from the note under every page of figures. The figures match backend/model_register.py.
class AboutNumbersScreen extends StatelessWidget {
  const AboutNumbersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: c.muted);
    const gap = SizedBox(height: 20);
    return Scaffold(
      appBar: AppBar(title: const Text('About these numbers')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                Panel(
                  color: c.warnBg,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const PanelTitle('Guidance, not financial advice',
                        icon: Icons.shield_outlined, tone: TitleTone.warn),
                    const SizedBox(height: 12),
                    Text(
                      'Tosha\'s scores, budgets and forecasts are estimates from statistical models. They can be wrong, '
                      'and they only know what is in your records. Tosha is a student research project, not a licensed '
                      'financial adviser. Before a big decision, such as a loan, a move or a large purchase, check the real '
                      'terms with the lender or seller and, if you can, talk to a qualified adviser.',
                      style: theme.textTheme.bodyLarge?.copyWith(height: 1.4),
                    ),
                  ]),
                ),
                gap,
                const PanelTitle('What each number comes from', icon: Icons.calculate_outlined),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Text('Five models, each doing one job. Every page of figures in the app comes from one of '
                      'these.', style: muted),
                ),
                const _Model(
                  icon: Icons.speed_rounded,
                  title: 'How you\'re doing (doing fine, stretched, struggling)',
                  text: 'A Random Forest model reads your recent months. When much of your spending is not sorted '
                      'yet, a second model that uses only totals from your statement takes over.',
                  fact: 'Agreed with the expected state 80% of the time on test households',
                ),
                const _Model(
                  icon: Icons.score_rounded,
                  title: 'Affordability score (0 to 100)',
                  text: 'Gradient-boosting models give the chance your months look like doing fine or stretched, '
                      'turned into a score from 0 to 100. "Why this score?" shows how each part of your figures '
                      'moved it.',
                  fact: 'Built so a bigger cost can never raise your score',
                ),
                const _Model(
                  icon: Icons.pie_chart_outline_rounded,
                  title: 'Your budget',
                  text: 'Bills, debts and at least 10% savings come first. The rest is shared across your categories '
                      'by a model of how stable households spend, moved towards how you actually spend as your own '
                      'months come in.',
                ),
                const _Model(
                  icon: Icons.show_chart_rounded,
                  title: 'The forecast',
                  text: 'A model predicts this month and the next two from your own usual spending, including '
                      'school-fee months and December. The shaded band is the likely range, not a promise.',
                  fact: 'Real months land inside the band about 8 times in 10',
                ),
                const _Model(
                  icon: Icons.sort_rounded,
                  title: 'Sorting your payments',
                  text: 'A list of Kenyan businesses and simple rules suggest what each payee is.',
                  fact: 'Your own choices always win',
                ),
                gap,
                Panel(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const PanelTitle('What the models learned from', icon: Icons.school_outlined),
                    const SizedBox(height: 14),
                    Wrap(spacing: 10, runSpacing: 10, children: [
                      _Stat(value: '21,773', label: 'Kenyan households surveyed'),
                      _Stat(value: 'KIHBS', label: 'Kenya\'s own 2015/16 survey'),
                    ]),
                    const SizedBox(height: 14),
                    Text(
                      'The Kenya Integrated Household Budget Survey 2015/16 for how Kenyan households spend, and '
                      'simulated households built from it for month-by-month patterns. The models have not yet been '
                      'checked on many real households, so treat their answers as a careful second opinion.',
                      style: theme.textTheme.bodyLarge?.copyWith(height: 1.4),
                    ),
                  ]),
                ),
                gap,
                Panel(
                  color: c.warnBg,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const PanelTitle('Known limits', icon: Icons.report_problem_outlined, tone: TitleTone.warn),
                    const SizedBox(height: 14),
                    for (final l in const [
                      'Money that never passes through M-PESA is missing unless you add it.',
                      'The score looks mostly at your last 3 to 6 months; your year\'s track record is shown beside it.',
                      'The score is a fair warning for next month, and weaker after that. It shows where you are now; '
                          '"Can I afford it?" is how Tosha looks further ahead, by trying a change on your own months.',
                      'Savings goals are not part of the score; each check says what it does to them.',
                      'A few months of records give rougher answers than a full year.',
                    ])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 7, right: 12),
                            child: CircleAvatar(radius: 3.5, backgroundColor: c.warn),
                          ),
                          Expanded(child: Text(l, style: theme.textTheme.bodyLarge?.copyWith(height: 1.4))),
                        ]),
                      ),
                  ]),
                ),
                gap,
                Column(children: [
                  const ToshaLogo(size: 32),
                  const SizedBox(height: 8),
                  Text('Built by Kevin Kaniaru, Strathmore University, as a final-year project.',
                      textAlign: TextAlign.center, style: muted),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One model, in its own card: what it does, and the one figure that says how well, where there is one.
class _Model extends StatelessWidget {
  const _Model({required this.icon, required this.title, required this.text, this.fact});
  final IconData icon;
  final String title, text;
  final String? fact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Panel(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(color: c.field, shape: BoxShape.circle),
              child: Icon(icon, size: 18, color: theme.colorScheme.onSurface),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(title, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 12),
          Text(text, style: theme.textTheme.bodyMedium?.copyWith(height: 1.4)),
          if (fact != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: c.lime, borderRadius: BorderRadius.circular(14)),
              child: Row(children: [
                Icon(Icons.check_rounded, size: 16, color: c.onLime),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(fact!,
                      style: theme.textTheme.bodySmall?.copyWith(color: c.onLime, fontWeight: FontWeight.w600)),
                ),
              ]),
            ),
          ],
        ]),
      ),
    );
  }
}

/// A figure worth seeing on its own: 21,773 households, KIHBS.
class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});
  final String value, label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: c.field, borderRadius: BorderRadius.circular(18)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        Text(label, style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
      ]),
    );
  }
}
