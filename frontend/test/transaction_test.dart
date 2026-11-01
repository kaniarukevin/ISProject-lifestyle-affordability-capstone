import 'package:flutter_test/flutter_test.dart';
import 'package:lifestyle_affordability/models/transaction.dart';

void main() {
  test('dates are sent the way the backend expects', () {
    final t = Txn(date: DateTime(2026, 11, 1), amount: 450, category: 'transport');
    expect(t.toJson()['date'], '2026-11-01');
  });

  test('spending is grouped by month, newest first, with category totals', () {
    final groups = groupByMonth([
      Txn(date: DateTime(2026, 10, 3), amount: 4000, category: 'housing'),
      Txn(date: DateTime(2026, 11, 1), amount: 300, category: 'transport'),
      Txn(date: DateTime(2026, 11, 2), amount: 200, category: 'transport'),
    ]);
    expect(groups.map((g) => g.month).toList(), [11, 10]);
    expect(groups.first.total, 500);
    expect(groups.first.byCategory['transport'], 500);
  });

  test('categories match the ten the engines were trained on', () {
    expect(spendingCategories.length, 10);
    expect(spendingCategories.containsKey('mobile_money_transfers'), isTrue);
  });

  test('one-off purchases are kept apart from usual spending', () {
    final g = groupByMonth([
      Txn(date: DateTime(2026, 10, 3), amount: 3000, category: 'food_groceries'),
      Txn(date: DateTime(2026, 10, 20), amount: 1000000, category: 'housing', oneOff: true),
    ]).single;
    expect(g.total, 3000);
    expect(g.oneOffTotal, 1000000);
    expect(g.byCategory.containsKey('housing'), isFalse);
    expect(Txn(date: DateTime(2026, 10, 20), amount: 1, category: 'housing', oneOff: true).toJson()['one_off'], isTrue);
  });
}
