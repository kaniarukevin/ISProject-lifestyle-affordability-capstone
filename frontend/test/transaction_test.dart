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
}
