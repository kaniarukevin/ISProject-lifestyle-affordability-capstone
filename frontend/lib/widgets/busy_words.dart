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

/// A small spinner with words that change every 1.6 seconds, so a wait says what is happening. Screen readers
/// hear the first line only, not every change.
class BusyWords extends StatefulWidget {
  const BusyWords({super.key, required this.lines, this.light = false});
  final List<String> lines;
  /// On a black button: white text and spinner.
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
    final color = widget.light ? Colors.white : Theme.of(context).colorScheme.onSurface;
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
