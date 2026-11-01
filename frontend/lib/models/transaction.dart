/// One spending record. Categories are the ten the engines were trained on.
library;

const Map<String, String> spendingCategories = {
  'food_groceries': 'Food and groceries',
  'transport': 'Transport (matatu, fuel, boda)',
  'airtime_data': 'Airtime and data',
  'entertainment': 'Eating out and fun',
  'utilities': 'Electricity, water, gas',
  'housing': 'Rent and housing',
  'mobile_money_transfers': 'Money sent to family or friends',
  'school_fees': 'School or university fees',
  'loan_repayment': 'Loan repayments',
  'savings': 'Savings',
};

class Txn {
  Txn({this.id, required this.date, required this.amount, required this.category, this.description = '',
      this.source = 'manual', this.oneOff = false});

  int? id;
  DateTime date;
  double amount;
  String category, description, source;

  /// Big, rare payments (a plot, a car deposit, a wedding): shown, but not counted as usual spending.
  bool oneOff;

  String get isoDate =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  Map<String, dynamic> toJson() =>
      {'date': isoDate, 'amount': amount, 'category': category, 'description': description, 'source': source,
       'one_off': oneOff};

  factory Txn.fromJson(Map<String, dynamic> j) => Txn(
        id: j['id'] as int?,
        date: DateTime.parse(j['date'] as String),
        amount: (j['amount'] as num).toDouble(),
        category: j['category'] as String,
        description: (j['description'] ?? '') as String,
        source: (j['source'] ?? 'manual') as String,
        oneOff: (j['one_off'] ?? false) as bool,
      );
}

/// Group transactions by month, newest month first, with totals per category.
List<MonthGroup> groupByMonth(List<Txn> txns) {
  final map = <String, MonthGroup>{};
  for (final t in txns) {
    final key = '${t.date.year}-${t.date.month.toString().padLeft(2, '0')}';
    map.putIfAbsent(key, () => MonthGroup(t.date.year, t.date.month)).add(t);
  }
  final groups = map.values.toList()..sort((a, b) => (b.year * 12 + b.month).compareTo(a.year * 12 + a.month));
  for (final g in groups) {
    g.items.sort((a, b) => b.date.compareTo(a.date));
  }
  return groups;
}

class MonthGroup {
  MonthGroup(this.year, this.month);
  final int year, month;
  final List<Txn> items = [];
  final Map<String, double> byCategory = {};
  double total = 0; // usual spending only
  double oneOffTotal = 0;

  void add(Txn t) {
    items.add(t);
    if (t.oneOff) {
      oneOffTotal += t.amount;
      return;
    }
    total += t.amount;
    byCategory[t.category] = (byCategory[t.category] ?? 0) + t.amount;
  }
}
