import 'package:flutter_test/flutter_test.dart';
import 'package:lifestyle_affordability/models/profile.dart';

void main() {
  test('per-semester income is spread across the year', () {
    final helb = IncomeSource(name: 'HELB', amount: 30000, frequency: 'semester');
    expect(helb.monthly, 5000);
  });

  test('monthly income adds up every source', () {
    final p = Profile(incomes: [
      IncomeSource(name: 'Allowance', amount: 7000),
      IncomeSource(name: 'HELB', amount: 30000, frequency: 'semester'),
    ]);
    expect(p.monthlyIncome, 12000);
  });

  test('profile survives saving and loading', () {
    final p = Profile(householdSize: 4, dependants: 2, incomes: [IncomeSource(name: 'Salary', amount: 25300)]);
    final back = Profile.fromJson(p.toJson());
    expect(back.householdSize, 4);
    expect(back.monthlyIncome, 25300);
  });

  test('onboarding answers survive saving and loading', () {
    final p = Profile(householdSize: 4, dependants: 2, name: 'Wanjiku', incomeTypes: ['salary', 'business'],
        childrenInSchool: 2, incomeLow: 52000, email: 'w@example.com');
    final back = Profile.fromJson(p.toJson());
    expect([back.name, back.childrenInSchool, back.incomeLow, back.email], ['Wanjiku', 2, 52000, 'w@example.com']);
    expect(back.incomeTypes, ['salary', 'business']);
  });
}
