import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/panel.dart';
import 'about_numbers_screen.dart';

/// Plain answers to the questions people actually ask (11 Nov: testers did not know what the score meant, or why
/// Tosha asks what it asks). Short sentences, no jargon. Opened from You and from the note under every page.
class QuestionsScreen extends StatefulWidget {
  const QuestionsScreen({super.key, this.openAt});

  /// A question to have open when the page appears, matched on its first few words.
  final String? openAt;

  @override
  State<QuestionsScreen> createState() => _QuestionsScreenState();
}

class _Q {
  const _Q(this.icon, this.question, this.answer);
  final IconData icon;
  final String question, answer;
}

const _groups = <String, List<_Q>>{
  'The basics': [
    _Q(Icons.waving_hand_rounded, 'What is Tosha for?',
        'Tosha reads your M-PESA records and tells you three things. How your money is doing right now. What your '
            'month ahead looks like. And whether you can afford a big change, like a loan, a move or school fees, '
            'before you commit to it.'),
    _Q(Icons.block_rounded, 'What will Tosha never do?',
        'Tosha never moves your money. It cannot send, withdraw or pay anything.\n\n'
            'It never messages anyone on your behalf, and it never shares what it reads. The only emails it sends '
            'are to you, to reset your password.\n\n'
            'It never changes anything without you pressing a button. A check is just a check until you say you are '
            'doing it.'),
    _Q(Icons.speed_rounded, 'What does my score mean?',
        'It runs from 0 to 100. The higher it is, the more room your money has. Above 56 your money usually covers '
            'your life with something left. Between 33 and 56 it is tight. Below 33 more is going out than coming '
            'in.\n\n'
            'It is not a credit score. Nobody else sees it. It changes as your months change.'),
    _Q(Icons.mood_rounded, 'What do Doing fine, Stretched and Struggling mean?',
        'Doing fine: what comes in covers your life, and there is room to save.\n\n'
            'Stretched: money is tight. Most of what comes in goes straight out again.\n\n'
            'Struggling: more is going out than comes in.\n\n'
            'Under the word you will see the figures it came from. If those look wrong to you, something is '
            'missing: check your records, and your money outside M-PESA.'),
    _Q(Icons.fact_check_rounded, 'How do I know Tosha is right about me?',
        'Check the figures, not the words. Every answer shows what it was worked out from: what came in, what went '
            'out, and how many months it used.\n\n'
            'If a figure looks wrong, it is usually one of three things. Money that came in another way, which you '
            'can add under You, then Money outside M-PESA. Payments that are not sorted yet, under Who you pay. Or '
            'cash you spent that M-PESA never saw, which you can type in yourself.'),
  ],
  'Your records': [
    _Q(Icons.calendar_today_rounded, 'Why does Tosha want a whole year?',
        'More months mean better answers. School fees, December and a quiet February all look different, and a year '
            'shows Tosha your real pattern instead of one unusual month. Three months still works, but the answers '
            'are rougher, and Tosha will say so.'),
    _Q(Icons.account_balance_rounded, 'Why do you need to know about money outside M-PESA?',
        'Tosha only sees M-PESA. If part of your money comes another way, like an allowance paid into a bank, or '
            'cash, your months look poorer than they are. Your budget would then be too tight and your score too '
            'low. A rough monthly figure is enough.'),
    _Q(Icons.people_alt_rounded, 'Why does it ask who I pay?',
        'Your statement shows a name, not what the payment was for. A payment to "Jane Mwangi" could be groceries '
            'or family. Telling Tosha once what each name is lets it split your spending properly, and it remembers '
            'for every future payment to them.'),
    _Q(Icons.family_restroom_rounded, 'Why does it ask who depends on my money?',
        'A household of four needs more than one person on the same income. Tosha uses it to judge your spending '
            'fairly against households like yours, and to size your budget.'),
    _Q(Icons.lock_rounded, 'What happens to my statement?',
        'The file itself is never kept. Tosha reads it, keeps the payments inside it, and throws the file and its '
            'password away. You can delete everything at any time under You, then Delete my account.'),
  ],
  'The answers it gives': [
    _Q(Icons.verified_user_rounded, 'What does "Can I afford it?" actually do?',
        'It takes your own recent months and runs them again as if you had already made the change. You see what '
            'each month would look like, how long your savings could cover a gap, and what it would do to your '
            'goals.\n\n'
            'Nothing is saved unless you press "I\'m doing this".'),
    _Q(Icons.show_chart_rounded, 'How accurate is the forecast?',
        'It is an estimate, not a promise. That is why it shows a range rather than one number, and real months '
            'land inside that range about 8 times in 10. Tosha also checks its old forecasts against what you '
            'really spent, and tells you when it was off.'),
    _Q(Icons.history_toggle_off_rounded, 'Can it tell me what will happen in three months?',
        'Not reliably, and it does not pretend to. We tested it: the score is a fair warning for the month ahead '
            'and much weaker after that. For anything further out, use "Can I afford it?", where you say what you '
            'are planning and Tosha works out the effect.'),
    _Q(Icons.login_rounded, 'Can I sign in with Google?',
        'Yes, if the button is on the sign-in screen. If you already made an account with your email, signing in '
            'with Google uses that same account, as long as it is the same address. You will not end up with '
            'two.\n\nYour password keeps working either way.'),
    _Q(Icons.gavel_rounded, 'Is this financial advice?',
        'No. Tosha is a student project, not a licensed adviser, and its answers come from statistical models that '
            'can be wrong. Treat it as a careful second opinion. Before anything big, check the real terms with the '
            'lender or seller.'),
  ],
};

class _QuestionsScreenState extends State<QuestionsScreen> {
  String? _open;

  @override
  void initState() {
    super.initState();
    _open = widget.openAt;
  }

  bool _isOpen(_Q q) => _open != null && q.question.startsWith(_open!);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Questions')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                Panel(
                  color: c.lime,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Everything, in plain words',
                        style: theme.textTheme.titleLarge?.copyWith(color: c.onLime)),
                    const SizedBox(height: 6),
                    Text('What Tosha does, what the numbers mean, and why it asks what it asks. Tap a question.',
                        style: theme.textTheme.bodyMedium?.copyWith(color: const Color(0xFF2B3110))),
                  ]),
                ),
                for (final group in _groups.entries) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 26, 4, 10),
                    child: Text(group.key, style: theme.textTheme.titleMedium?.copyWith(color: c.muted)),
                  ),
                  for (final q in group.value)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _Card(
                        q: q,
                        open: _isOpen(q),
                        onTap: () => setState(() => _open = _isOpen(q) ? null : q.question),
                      ),
                    ),
                ],
                const SizedBox(height: 26),
                FilledButton.tonal(
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      backgroundColor: c.field,
                      foregroundColor: theme.colorScheme.onSurface),
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AboutNumbersScreen())),
                  child: const Text('More about where the numbers come from'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One question as a card that opens in place: lime icon, the question, then the answer.
class _Card extends StatelessWidget {
  const _Card({required this.q, required this.open, required this.onTap});
  final _Q q;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return Material(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(color: open ? c.lime : c.field, shape: BoxShape.circle),
                child: Icon(q.icon, size: 18, color: open ? c.onLime : theme.colorScheme.onSurface),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(q.question,
                      style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700, height: 1.3)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Icon(open ? Icons.remove_rounded : Icons.add_rounded, size: 20, color: c.muted),
              ),
            ]),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 160),
              firstChild: const SizedBox(width: double.infinity),
              secondChild: Padding(
                padding: const EdgeInsets.only(left: 48, top: 10),
                child: Text(q.answer, style: theme.textTheme.bodyMedium?.copyWith(height: 1.5)),
              ),
              crossFadeState: open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            ),
          ]),
        ),
      ),
    );
  }
}
