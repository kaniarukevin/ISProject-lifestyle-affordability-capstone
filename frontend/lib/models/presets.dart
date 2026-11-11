/// The lifestyle changes a user can test. Each maps to a server preset; the server turns it into an
/// affordability-engine scenario, so the logic lives in one tested place.
library;

import 'package:flutter/material.dart';


/// One thing the form asks for. A field is either needed, or [optional] with [whenEmpty] standing in for an
/// empty box, so nobody has to invent a number to get an answer (11 Nov). [options] makes it a picker instead
/// of a number.
class Field {
  const Field(this.key, this.label,
      {this.hint, this.initial, this.allowNegative = false, this.optional = false, this.whenEmpty, this.options});
  final String key, label;

  /// The line under the box. For an optional field it says what an empty box means.
  final String? hint;
  final num? initial;
  final bool allowNegative;
  final bool optional;

  /// What an empty box means, for an optional field.
  final num? whenEmpty;

  /// value -> label. When set, the field is a picker and its value is sent as a string.
  final Map<String, String>? options;
}

const _loanMonths = Field('months', 'Paying it back over how many months', initial: 12);
const _loanRate = Field('annual_rate', 'Interest per year (%)',
    initial: 14, hint: 'A typical figure. Change it to your lender\'s rate.');

/// Instalments on a purchase: empty means paying for it all at once, which is one month's cost.
const _payOver = Field('months', 'Paying over how many months',
    optional: true, whenEmpty: 1, hint: 'Leave empty if you are paying it all at once.');
const _payRate = Field('annual_rate', 'Interest per year (%)',
    optional: true, whenEmpty: 0, hint: 'Leave empty if there is no interest.');

/// Which budget line a new cost comes out of. Savings are left out: money set aside is a goal, not a cost.
const _costKinds = {
  'food_groceries': 'Food',
  'transport': 'Transport',
  'airtime_data': 'Airtime and data',
  'entertainment': 'Eating out and fun',
  'utilities': 'Power, water and internet',
  'housing': 'Rent or housing',
  'mobile_money_transfers': 'Family, friends and giving',
  'school_fees': 'School fees',
  'loan_repayment': 'Loan repayments',
};

/// A cost that stops: empty means it carries on every month.
const _lasts = Field('months', 'For how many months',
    optional: true, hint: 'Leave empty if it carries on every month.');

const familyPresets = [
  Preset(id: 'move', title: 'Move house', subtitle: 'A bigger or better place', icon: Icons.home_work_outlined,
      server: 'move_house', fields: [
        Field('new_rent', 'New rent per month (KES)', hint: 'The new rent in full, not the difference'),
      ]),
  Preset(id: 'car', title: 'Buy a car on a loan', subtitle: 'Car loan or asset finance', icon: Icons.directions_car_outlined,
      server: 'loan', fields: [Field('amount', 'Amount borrowed (KES)'), _loanMonths, _loanRate],
      fixed: {'label': 'Car loan'}),
  Preset(id: 'school', title: 'Change of school', subtitle: 'Private school, boarding, new level', icon: Icons.school_outlined,
      server: 'new_expense', fields: [
        Field('amount', 'Extra fees per month (KES)',
            hint: 'Only the extra, on top of what you pay now. Fees per term ÷ 4.'),
      ],
      fixed: {'category': 'school_fees', 'label': 'Higher school fees'}),
  Preset(id: 'baby', title: 'A new baby', subtitle: 'Food, diapers, utilities, house help', icon: Icons.child_friendly_outlined,
      server: 'new_baby', fields: [
        Field('food', 'Food and diapers per month (KES)', initial: 6000, hint: 'A typical figure. Change it.'),
        Field('utilities', 'Extra utilities per month (KES)', initial: 1500, hint: 'A typical figure. Change it.'),
        Field('house_help', 'House help per month (KES)',
            optional: true, whenEmpty: 0, hint: 'Leave empty if you will not hire anyone.'),
      ]),
  Preset(id: 'help', title: 'Hire a house help', subtitle: 'Monthly wages', icon: Icons.cleaning_services_outlined,
      server: 'new_expense', fields: [
        Field('amount', 'Monthly wage (KES)', initial: 8000, hint: 'A typical figure. Change it.'),
      ],
      fixed: {'category': 'mobile_money_transfers', 'label': 'House help'}),
  Preset(id: 'support', title: 'Support family', subtitle: 'Regular money sent home', icon: Icons.volunteer_activism_outlined,
      server: 'new_expense', fields: [Field('amount', 'Per month (KES)'), _lasts],
      fixed: {'category': 'mobile_money_transfers', 'label': 'Family support'}),
];

const studentPresets = [
  Preset(id: 'offcampus', title: 'Move off-campus', subtitle: 'Rent plus getting to class', icon: Icons.apartment_outlined,
      server: 'move_house', fields: [
        Field('new_rent', 'New rent per month (KES)', hint: 'The new rent in full, not the difference'),
        Field('extra_transport', 'Extra transport per month (KES)',
            optional: true, whenEmpty: 0, hint: 'Leave empty if getting to class would cost the same.'),
      ]),
  Preset(id: 'laptop', title: 'Laptop or phone', subtitle: 'Pay now, or in instalments', icon: Icons.laptop_mac_outlined,
      server: 'purchase', fields: [Field('price', 'Price (KES)'), _payOver, _payRate],
      fixed: {'label': 'Laptop or phone'}),
  Preset(id: 'gym', title: 'Gym or subscription', subtitle: 'Gym, Netflix, Showmax, Spotify', icon: Icons.fitness_center_outlined,
      server: 'new_expense', fields: [
        Field('amount', 'Per month (KES)', initial: 2500, hint: 'A typical figure. Change it.'),
        _lasts,
      ],
      fixed: {'category': 'entertainment', 'label': 'Gym or subscription'}),
  Preset(id: 'trip', title: 'Save for a trip', subtitle: 'Holiday, event, travel home', icon: Icons.flight_takeoff_outlined,
      server: 'savings_goal', fields: [
        Field('target', 'Total cost (KES)'),
        Field('months', 'Months until the trip', initial: 3),
      ],
      fixed: {'label': 'Trip'}),
  Preset(id: 'helb', title: 'HELB or upkeep delayed', subtitle: 'Less money coming in for a while', icon: Icons.hourglass_bottom_outlined,
      server: 'income_change', fields: [
        Field('amount', 'Monthly amount you would lose (KES)'),
        Field('months', 'For how many months', optional: true, hint: 'Leave empty if you do not know yet.'),
      ],
      fixed: {'negate': true}),
  Preset(id: 'hustle', title: 'Start a side hustle', subtitle: 'Extra income each month', icon: Icons.storefront_outlined,
      server: 'income_change', fields: [Field('amount', 'Expected extra income per month (KES)')]),
];

const anyonePresets = [
  Preset(id: 'buy', title: 'Buy something', subtitle: 'TV, fridge, furniture, phone', icon: Icons.shopping_bag_outlined,
      server: 'purchase', fields: [Field('price', 'Price (KES)'), _payOver, _payRate],
      fixed: {'label': 'A purchase'}),
  Preset(id: 'loan', title: 'Take a loan', subtitle: 'SACCO, bank, mobile loan', icon: Icons.account_balance_outlined,
      server: 'loan', fields: [Field('amount', 'Amount borrowed (KES)'), _loanMonths, _loanRate],
      fixed: {'label': 'Loan'}),
  Preset(id: 'save', title: 'Save for a goal', subtitle: 'Emergency fund, plot, wedding', icon: Icons.savings_outlined,
      server: 'savings_goal', fields: [
        Field('target', 'Target amount (KES)'),
        Field('months', 'Months to reach it', initial: 12),
      ],
      fixed: {'label': 'Savings goal'}),
  Preset(id: 'newcost', title: 'Any new monthly cost', subtitle: 'Something else that repeats', icon: Icons.add_card_outlined,
      server: 'new_expense', fields: [
        Field('amount', 'Per month (KES)'),
        // Which budget line it comes out of: without this every new cost landed under eating out and fun.
        Field('category', 'What kind of cost is it?', options: _costKinds),
        _lasts,
      ],
      fixed: {'label': 'New monthly cost'}),
  Preset(id: 'paycut', title: 'Pay cut or job loss', subtitle: 'Test the worst case', icon: Icons.trending_down,
      server: 'income_change', fields: [
        Field('amount', 'Monthly income you would lose (KES)'),
        Field('months', 'For how many months', optional: true, hint: 'Leave empty if it is for good.'),
      ],
      fixed: {'negate': true}),
  Preset(id: 'raise', title: 'A pay rise', subtitle: 'New job or promotion', icon: Icons.trending_up,
      server: 'income_change', fields: [Field('amount', 'Extra income per month (KES)')]),
];

class Preset {
  const Preset({required this.id, required this.title, required this.subtitle, required this.icon,
      required this.server, required this.fields, this.fixed = const {}});
  final String id, title, subtitle, server;
  final IconData icon;
  final List<Field> fields;
  final Map<String, dynamic> fixed; // sent as-is, e.g. the label of a new expense
}

/// The request body for /me/afford from a preset and what the user typed. Values are already resolved: an
/// optional box left empty arrives as its [Field.whenEmpty], or not at all.
Map<String, dynamic> buildChoice(Preset p, Map<String, dynamic> values) {
  final body = <String, dynamic>{'preset': p.server};
  p.fixed.forEach((k, v) {
    if (k != 'negate') body[k] = v;
  });
  values.forEach((k, v) {
    body[k] = (k == 'amount' && v is num && p.fixed['negate'] == true) ? -v : v;
  });
  return body;
}
