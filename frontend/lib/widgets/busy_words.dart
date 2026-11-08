import 'dart:async';

import 'package:flutter/material.dart';

/// What "Can I afford it?" is doing while it works (each line is a real step on the server).
const checkingWords = [
  'Looking at your last few months…',
  'Adding the change to your budget…',
  'Checking your savings…',
  'Working out your score…',
];

/// What reading an M-PESA statement does, in order.
const statementWords = [
  'Opening your statement…',
  'Reading every transaction…',
  'Checking totals against your statement…',
  'Sorting shops and bills…',
  'Finding who pays you…',
];

const startWords = ['Opening Tosha…', 'Checking you are still logged in…', 'Getting your figures…'];
const overviewWords = ['Loading your overview…', 'Working out your score…', 'Looking at the months ahead…'];
const forecastWords = ['Loading your forecast…', 'Looking at your usual months…', 'Working out your budget…'];
const plansWords = ['Loading your bills, debts and goals…', 'Working out what is due…'];
const recordsWords = ['Loading your records…', 'Grouping them by month…'];
const monthWords = ['Loading this month…'];
const budgetWords = ['Loading your budget…', 'Splitting your money…', 'Checking this month so far…'];
const whyWords = ['Working out why…', 'Weighing each part of your score…'];
const payeeWords = ['Loading who you pay…', 'Grouping payments by person and shop…'];
const privacyWords = ['Loading the privacy notice…'];
const adminWords = ['Loading the console…', 'Checking the service…', 'Collecting the model results…'];
const logInWords = ['Logging you in…', 'Getting your figures…'];
const signUpWords = ['Creating your account…', 'Setting things up…'];
const logOutWords = ['Logging you out…', 'Clearing your figures from this device…'];
const sendCodeWords = ['Sending your code…'];
const resetWords = ['Checking your code…', 'Saving your new password…', 'Logging you in…'];
const onboardingWords = ['Saving your household…', 'Working out your first answer…'];
const savingWords = ['Saving…'];

/// A small spinner with words that change every 1.6 seconds, so a wait says what is happening. Screen readers
/// hear the first line only, not every change.
class BusyWords extends StatefulWidget {
  const BusyWords({super.key, required this.lines, this.light = false});
  final List<String> lines;
  /// Force white text and spinner. Otherwise they take the surrounding text colour, so inside a button they
  /// match the button in light and dark mode.
  final bool light;

  @override
  State<BusyWords> createState() => _BusyWordsState();
}

class _BusyWordsState extends State<BusyWords> {
  int _i = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 1600), (_) {
      if (mounted && _i < widget.lines.length - 1) setState(() => _i++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.light
        ? Colors.white
        : (DefaultTextStyle.of(context).style.color ?? Theme.of(context).colorScheme.onSurface);
    return Semantics(
      liveRegion: false,
      label: widget.lines.first,
      child: ExcludeSemantics(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: color)),
          const SizedBox(width: 12),
          Flexible(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(widget.lines[_i], key: ValueKey(_i), overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: color, fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
      ),
    );
  }
}


/// A whole area that is loading: the spinner and its words in the middle, with room around them.
class BusyCenter extends StatelessWidget {
  const BusyCenter(this.lines, {super.key});
  final List<String> lines;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
            child: BusyWords(lines: lines),
          ),
        ),
      );
}
