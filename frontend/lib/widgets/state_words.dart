/// Plain words for the model's three financial states (10 Nov: testers did not know what "Strained" or a bare
/// score meant). The models and the API keep Stable, Strained and Critical; only the screen says these.
const _plain = {'Stable': 'Doing fine', 'Strained': 'Stretched', 'Critical': 'Struggling'};

String stateLabel(String state) => _plain[state] ?? state;

/// One sentence on what the state means for the household.
const _meaning = {
  'Stable': 'What comes in covers your usual way of life, with room to save.',
  'Strained': 'Money is tight: most of what comes in goes straight out again.',
  'Critical': 'More is going out than comes in. Acting early makes it easier.',
};

String stateMeaning(String state) => _meaning[state] ?? '';

/// A score with its scale, so it never stands alone: "62 out of 100".
String scoreOutOf(num score) => '${score.round()} out of 100';
