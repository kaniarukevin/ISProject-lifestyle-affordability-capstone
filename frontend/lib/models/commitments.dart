/// What the household owes and plans for. Field names in toJson() match the backend's /commitments engine.
library;

const Map<String, String> obligationCategories = {
  'housing': 'Rent or housing',
  'school_fees': 'School or university fees',
  'other_commitments': 'Other (chama, insurance, support…)',
};

const Map<String, String> obligationFrequencies = {
  'weekly': 'per week',
  'monthly': 'per month',
  'quarterly': 'per quarter',
  'termly': 'per term',
  'semester': 'per semester',
  'yearly': 'per year',
};

class Obligation {
  Obligation({required this.name, required this.amount, this.frequency = 'monthly', this.category = 'other_commitments'});
  String name, frequency, category;
  double amount;

  Map<String, dynamic> toJson() => {'name': name, 'amount': amount, 'frequency': frequency, 'category': category};
  factory Obligation.fromJson(Map<String, dynamic> j) => Obligation(
      name: j['name'] as String,
      amount: (j['amount'] as num).toDouble(),
      frequency: (j['frequency'] ?? 'monthly') as String,
      category: (j['category'] ?? 'other_commitments') as String);
}

class Debt {
  Debt({required this.name, required this.balance, required this.annualRate, required this.monthlyPayment});
  String name;
  double balance, annualRate, monthlyPayment;

  Map<String, dynamic> toJson() =>
      {'name': name, 'balance': balance, 'annual_rate': annualRate, 'monthly_payment': monthlyPayment};
  factory Debt.fromJson(Map<String, dynamic> j) => Debt(
      name: j['name'] as String,
      balance: (j['balance'] as num).toDouble(),
      annualRate: ((j['annual_rate'] ?? 0) as num).toDouble(),
      monthlyPayment: (j['monthly_payment'] as num).toDouble());
}

class Goal {
  Goal({required this.name, required this.target, this.saved = 0, required this.monthsLeft, this.done = false,
      this.doneOn});
  String name;
  double target, saved;
  int monthsLeft;

  /// Reached: the server ticks a goal off when an imported purchase matches it. Kept through every save
  /// (before 5 Nov the app dropped these two fields, so saving Commitments brought a reached goal back).
  bool done;
  String? doneOn;

  Map<String, dynamic> toJson() => {'name': name, 'target': target, 'saved': saved, 'months_left': monthsLeft,
        if (done) 'done': true, if (doneOn != null) 'done_on': doneOn};
  factory Goal.fromJson(Map<String, dynamic> j) => Goal(
      name: j['name'] as String,
      target: (j['target'] as num).toDouble(),
      saved: ((j['saved'] ?? 0) as num).toDouble(),
      monthsLeft: (j['months_left'] as num).toInt(),
      done: j['done'] == true,
      doneOn: j['done_on'] as String?);
}

class Commitments {
  Commitments({List<Obligation>? obligations, List<Debt>? debts, List<Goal>? goals, this.extraPerMonth = 0})
      : obligations = obligations ?? [],
        debts = debts ?? [],
        goals = goals ?? [];

  List<Obligation> obligations;
  List<Debt> debts;
  List<Goal> goals;
  double extraPerMonth;

  Map<String, dynamic> toJson() => {
        'obligations': obligations.map((o) => o.toJson()).toList(),
        'debts': debts.map((d) => d.toJson()).toList(),
        'goals': goals.map((g) => g.toJson()).toList(),
        'extra_per_month': extraPerMonth,
      };

  factory Commitments.fromJson(Map<String, dynamic> j) => Commitments(
        obligations: ((j['obligations'] ?? []) as List).map((e) => Obligation.fromJson(e as Map<String, dynamic>)).toList(),
        debts: ((j['debts'] ?? []) as List).map((e) => Debt.fromJson(e as Map<String, dynamic>)).toList(),
        goals: ((j['goals'] ?? []) as List).map((e) => Goal.fromJson(e as Map<String, dynamic>)).toList(),
        extraPerMonth: ((j['extra_per_month'] ?? 0) as num).toDouble(),
      );
}
