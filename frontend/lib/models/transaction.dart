/// One spending record. Categories are the ten the engines were trained on.
library;

const Map<String, String> spendingCategories = {
  'food_groceries': 'Food',
  'transport': 'Transport',
  'airtime_data': 'Airtime and data',
  'entertainment': 'Eating out and fun',
  'utilities': 'Power, water and internet',
  'housing': 'Rent',
  'mobile_money_transfers': 'Family, friends and giving',
  'school_fees': 'School fees',
  'loan_repayment': 'Loan repayments',
  'savings': 'Savings',
};

/// Labels for values that are not spending categories you can pick when adding a record.
const Map<String, String> extraCategories = {
  'shopping': 'Shopping',
  'health': 'Health',
  'personal_care': 'Personal care',
  'other': 'Other',
  'charges': 'M-PESA charges',
  'unsorted': 'Not sorted yet',
  'own_account': 'My own account (not spending)',
  'one_off': 'Bonus or one-off',
};

/// Spending with no budget line of its own (shopping, health, personal care, other, not sorted yet).
const List<String> outsideCategories = ['charges', 'shopping', 'health', 'personal_care', 'other', 'unsorted'];

/// What money coming in can be (the statement cannot tell your own bank transfer from someone paying you).
const Map<String, String> inTagLabels = {
  'income': 'Pay or allowance',
  'mixed': 'My bank: my pay or allowance arrives here first',
  'own_account': 'My own money',
  'received': 'Paid back or a gift',
  'one_off': 'Bonus or one-off',
};

/// The label for any category key, including 'unsorted' (statement payments the app was not sure about).
String categoryLabel(String key) => spendingCategories[key] ?? extraCategories[key] ?? key;

/// What a payee can be tagged as, in plain words (the app's categories, or the user's own account).
const Map<String, String> tagLabels = {
  'housing': 'Rent',
  'food_groceries': 'Food',
  'transport': 'Transport',
  'utilities': 'Power, water and internet',
  'airtime_data': 'Airtime and data',
  'mobile_money_transfers': 'Family, friends and giving',
  'school_fees': 'School fees',
  'loan_repayment': 'Loan repayments',
  'entertainment': 'Eating out and fun',
  'shopping': 'Shopping',
  'health': 'Health',
  'personal_care': 'Personal care',
  'other': 'Other',
  'own_account': 'My own account',
  'unsorted': 'Not sorted yet',
};

/// M-PESA's own transaction types (always right, because Safaricom writes them on the statement).
const Map<String, String> mpesaTypes = {
  'sent': 'Sent to people',
  'pochi': 'Pochi la Biashara',
  'buy_goods': 'Buy goods',
  'pay_bill': 'Pay bill',
  'cash': 'Cash withdrawal',
  'airtime': 'Airtime & bundles',
  'charges': 'M-PESA charges',
  'loan': 'Loan repayment',
  'savings': 'Savings',
};

class Txn {
  Txn({this.id, required this.date, required this.amount, required this.category, this.description = '',
      this.source = 'manual', this.oneOff = false, this.type, this.payee, this.payeeKey, this.label,
      this.pinned = false});

  int? id;
  DateTime date;
  double amount;
  String category, description, source;

  /// Big, rare payments (a plot, a car deposit, a wedding): shown, but not counted as usual spending.
  bool oneOff;

  /// From an M-PESA statement: the M-PESA type, who was paid, and the label shown (e.g. "M-PESA charges").
  String? type, payee, payeeKey, label;

  /// Changed by hand for this one payment, so a payee-wide change leaves it alone.
  bool pinned;

  /// What to call this record in lists: the label or payee for statement records, else the description.
  String get title => (label != null && label!.isNotEmpty)
      ? label!
      : (description.isNotEmpty ? description : categoryLabel(category));

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
        type: j['type'] as String?,
        payee: j['payee'] as String?,
        payeeKey: j['payee_key'] as String?,
        label: j['label'] as String?,
        pinned: (j['pinned'] ?? false) as bool,
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
    if (t.category == 'own_account') return; // the user's own money moving: not spending
    if (t.oneOff) {
      oneOffTotal += t.amount;
      return;
    }
    total += t.amount;
    byCategory[t.category] = (byCategory[t.category] ?? 0) + t.amount;
  }
}
