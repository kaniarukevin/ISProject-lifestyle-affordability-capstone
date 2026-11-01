import 'package:flutter_test/flutter_test.dart';
import 'package:lifestyle_affordability/models/commitments.dart';

void main() {
  test('commitments use the field names the backend engine expects', () {
    final c = Commitments(
      obligations: [Obligation(name: 'Fees', amount: 15000, frequency: 'termly', category: 'school_fees')],
      debts: [Debt(name: 'SACCO', balance: 20000, annualRate: 12, monthlyPayment: 2000)],
      goals: [Goal(name: 'Phone', target: 30000, saved: 5000, monthsLeft: 5)],
      extraPerMonth: 1000,
    );
    final j = c.toJson();
    expect(j['debts'][0], {'name': 'SACCO', 'balance': 20000.0, 'annual_rate': 12.0, 'monthly_payment': 2000.0});
    expect(j['goals'][0]['months_left'], 5);
    expect(j['extra_per_month'], 1000.0);
  });

  test('commitments survive a round trip through JSON', () {
    final back = Commitments.fromJson(Commitments(goals: [Goal(name: 'Phone', target: 30000, monthsLeft: 5)]).toJson());
    expect(back.goals.single.name, 'Phone');
    expect(back.debts, isEmpty);
  });
}
