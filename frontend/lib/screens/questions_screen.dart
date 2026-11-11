import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'about_numbers_screen.dart';

/// Plain answers to the questions people actually ask (11 Nov: testers did not know what the score meant, or why
/// Tosha asks what it asks). Short sentences, no jargon. Opened from You, from the score card and from the note
/// at the bottom of each page.
class QuestionsScreen extends StatelessWidget {
  const QuestionsScreen({super.key, this.openAt});

  /// A question to have open when the page appears, matched on its first few words.
  final String? openAt;

  static const _groups = <String, List<List<String>>>{
    'The basics': [
      [
        'What is Tosha for?',
        'Tosha reads your M-PESA records and tells you three things. How your money is doing right now. What your '
            'month ahead looks like. And whether you can afford a big change, like a loan, a move or school fees, '
            'before you commit to it.',
      ],
      [
        'What will Tosha never do?',
        'Tosha never moves your money. It cannot send, withdraw or pay anything.\n\nIt never messages anyone on your '
            'behalf, and it never shares what it reads. The only emails it sends are to you, to reset your '
            'password.\n\nIt never changes anything without you pressing a button. A check is just a check until you '
            'say you are doing it.',
      ],
      [
        'What does my score mean?',
        'It runs from 0 to 100. The higher it is, the more room your money has. Above 56 your money usually covers '
            'your life with something left. Between 33 and 56 it is tight. Below 33 more is going out than coming '
            'in.\n\nThe score is not a credit score. Nobody else sees it. It changes as your months change.',
      ],
      [
        'What do Doing fine, Stretched and Struggling mean?',
        'Doing fine: what comes in covers your life, and there is room to save.\n\n'
            'Stretched: money is tight. Most of what comes in goes straight out again.\n\n'
            'Struggling: more is going out than comes in.\n\n'
            'Under the word you will see the figures it came from, like "In October about KES 32,000 went out and '
            'about KES 30,000 came in". If those figures look wrong to you, something is missing. Check your records '
            'and your money outside M-PESA.',
      ],
      [
        'How do I know Tosha is right about me?',
        'Check the figures, not the words. Every answer shows what it was worked out from: what came in, what went '
            'out, and how many months it used.\n\nIf a figure looks wrong, it is usually one of three things. Money '
            'that came in another way, which you can add under You, then Money outside M-PESA. Payments that are '
            'not sorted yet, under Who you pay. Or cash you spent that M-PESA never saw, which you can type in '
            'yourself.',
      ],
    ],
    'Your records': [
      [
        'Why does Tosha want a whole year?',
        'More months mean better answers. School fees, December and a quiet February all look different, and a year '
            'shows Tosha your real pattern instead of one unusual month. Three months still works, but the answers '
            'are rougher, and Tosha will say so.',
      ],
      [
        'Why do you need to know about money outside M-PESA?',
        'Tosha only sees M-PESA. If part of your money comes another way, like an allowance paid into a bank, or '
            'cash, your months look poorer than they are. Your budget would then be too tight and your score too '
            'low. A rough monthly figure is enough.',
      ],
      [
        'Why does it ask who I pay?',
        'Your statement shows a name, not what the payment was for. A payment to "Jane Mwangi" could be groceries or '
            'family. Telling Tosha once what each name is lets it split your spending properly, and it remembers for '
            'every future payment to them.',
      ],
      [
        'Why does it ask who depends on my money?',
        'A household of four needs more than one person on the same income. Tosha uses it to judge your spending '
            'fairly against households like yours, and to size your budget.',
      ],
      [
        'What happens to my statement?',
        'The file itself is never kept. Tosha reads it, keeps the payments inside it, and throws the file and its '
            'password away. You can delete everything at any time under You, then Delete my account.',
      ],
    ],
    'The answers it gives': [
      [
        'What does "Can I afford it?" actually do?',
        'It takes your own recent months and runs them again as if you had already made the change. You see what '
            'each month would look like, how long your savings could cover a gap, and what it would do to your '
            'goals.\n\nNothing is saved unless you press "I\'m doing this".',
      ],
      [
        'How accurate is the forecast?',
        'It is an estimate, not a promise. That is why it shows a range rather than one number, and real months land '
            'inside that range about 8 times in 10. Tosha also checks its old forecasts against what you really '
            'spent, and tells you when it was off.',
      ],
      [
        'Can it tell me what will happen in three months?',
        'Not reliably, and it does not pretend to. We tested it: the score is a fair warning for the month ahead and '
            'much weaker after that. For anything further out, use "Can I afford it?", where you say what you are '
            'planning and Tosha works out the effect.',
      ],
      [
        'Can I sign in with Google?',
        'Yes, if the button is on the sign-in screen. If you already made an account with your email, signing in '
            'with Google uses that same account, as long as it is the same address. You will not end up with two.\n\n'
            'Your password keeps working either way.',
      ],
      [
        'Is this financial advice?',
        'No. Tosha is a student project, not a licensed adviser, and its answers come from statistical models that '
            'can be wrong. Treat it as a careful second opinion. Before anything big, check the real terms with the '
            'lender or seller.',
      ],
    ],
  };

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
                Text('Tap a question to see the answer.', style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
                for (final group in _groups.entries) ...[
                  const SizedBox(height: 20),
                  Text(group.key, style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  for (final q in group.value)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(bottom: 12),
                      expandedCrossAxisAlignment: CrossAxisAlignment.start,
                      initiallyExpanded: openAt != null && q.first.startsWith(openAt!),
                      title: Text(q.first, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                      children: [Text(q.last, style: theme.textTheme.bodyMedium)],
                    ),
                ],
                const SizedBox(height: 24),
                FilledButton.tonal(
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
