/// The household as the user describes it. Everything is stored per month,
/// because every engine in the backend works in KES per month.
library;

/// How often money arrives. Values are times per year (termly = 3 school terms).
const Map<String, int> frequencyPerYear = {
  'weekly': 52,
  'monthly': 12,
  'termly': 3,
  'semester': 2,
  'yearly': 1,
};

const Map<String, String> frequencyLabel = {
  'weekly': 'per week',
  'monthly': 'per month',
  'termly': 'per term',
  'semester': 'per semester',
  'yearly': 'per year',
};

class IncomeSource {
  IncomeSource({required this.name, required this.amount, this.frequency = 'monthly'});

  String name;
  double amount;
  String frequency;

  /// A HELB payment of 30,000 per semester counts as 5,000 a month. Spreading lump sums
  /// avoids false alarms in the months between payments (found in the student check).
  double get monthly => amount * frequencyPerYear[frequency]! / 12;

  Map<String, dynamic> toJson() => {'name': name, 'amount': amount, 'frequency': frequency};

  factory IncomeSource.fromJson(Map<String, dynamic> j) => IncomeSource(
        name: j['name'] as String,
        amount: (j['amount'] as num).toDouble(),
        frequency: j['frequency'] as String,
      );
}

class Profile {
  Profile({
    this.householdSize = 1,
    this.dependants = 0,
    this.urbanRural = 'urban',
    this.formalJob = false,
    this.paysOwnFees = false,
    this.savingsBalance = 0,
    List<IncomeSource>? incomes,
  }) : incomes = incomes ?? [];

  int householdSize;
  int dependants;
  String urbanRural; // urban, peri_urban or rural
  bool formalJob;
  bool paysOwnFees;
  double savingsBalance; // money already saved: M-Shwari, SACCO, bank
  List<IncomeSource> incomes;

  double get monthlyIncome => incomes.fold(0, (sum, s) => sum + s.monthly);

  /// The household block the backend's /budget and /affordability endpoints expect.
  Map<String, dynamic> toHouseholdJson() => {
        'household_size': householdSize,
        'num_dependants': dependants,
        'urban_rural': urbanRural,
        'formal_job': formalJob,
      };

  Map<String, dynamic> toJson() => {
        'householdSize': householdSize,
        'dependants': dependants,
        'urbanRural': urbanRural,
        'formalJob': formalJob,
        'paysOwnFees': paysOwnFees,
        'savingsBalance': savingsBalance,
        'incomes': incomes.map((s) => s.toJson()).toList(),
      };

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        householdSize: j['householdSize'] as int,
        dependants: j['dependants'] as int,
        urbanRural: j['urbanRural'] as String,
        formalJob: j['formalJob'] as bool,
        paysOwnFees: j['paysOwnFees'] as bool,
        savingsBalance: (j['savingsBalance'] as num?)?.toDouble() ?? 0,
        incomes: (j['incomes'] as List)
            .map((e) => IncomeSource.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
