import 'package:flutter_test/flutter_test.dart';
import 'package:lifestyle_affordability/models/presets.dart';

void main() {
  test('a pay cut is sent as a negative income change', () {
    final cut = anyonePresets.firstWhere((p) => p.id == 'paycut');
    expect(buildChoice(cut, {'amount': 3000}), {'preset': 'income_change', 'amount': -3000});
  });

  test('fixed fields such as the category are sent with the inputs', () {
    final gym = studentPresets.firstWhere((p) => p.id == 'gym');
    expect(buildChoice(gym, {'amount': 2500}),
        {'preset': 'new_expense', 'category': 'entertainment', 'label': 'Gym or subscription', 'amount': 2500});
  });

  test('every preset points at a preset the server knows', () {
    const known = {'move_house', 'new_expense', 'new_baby', 'purchase', 'loan', 'savings_goal', 'income_change'};
    for (final p in [...anyonePresets, ...familyPresets, ...studentPresets]) {
      expect(known.contains(p.server), isTrue, reason: p.id);
    }
  });
}
