/// The lifestyle changes a user can test. Each maps to a server preset; the server turns it into an
/// affordability-engine scenario, so the logic lives in one tested place.
library;

import 'package:flutter/material.dart';

class Field {
  const Field(this.key, this.label, {this.hint, this.initial, this.allowNegative = false});
  final String key, label;
  final String? hint;
  final num? initial;
  final bool allowNegative;
}

class Preset {
  const Preset({required this.id, required this.title, required this.subtitle, required this.icon,
      required this.server, required this.fields, this.fixed = const {}});
  final String id, title, subtitle, server;
  final IconData icon;
  final List<Field> fields;
  final Map<String, dynamic> fixed; // sent as-is, e.g. the category of a new expense
}

const _months = Field('months', 'Over how many months', initial: 12);
const _rate = Field('annual_rate', 'Interest per year (%)', hint: 'Leave 0 if there is none', initial: 0);

const familyPresets = [
  Preset(id: 'move', title: 'Move house', subtitle: 'A bigger or better place', icon: Icons.home_work_outlined,
      server: 'move_house', fields: [Field('new_rent', 'New rent per month (KES)')]),
  Preset(id: 'car', title: 'Buy a car on a loan', subtitle: 'Car loan or asset finance', icon: Icons.directions_car_outlined,
      server: 'loan', fields: [Field('amount', 'Amount borrowed (KES)'), _months, Field('annual_rate', 'Interest per year (%)', initial: 14)],
      fixed: {'label': 'Car loan'}),
  Preset(id: 'school', title: 'Change of school', subtitle: 'Private school, boarding, new level', icon: Icons.school_outlined,
      server: 'new_expense', fields: [Field('amount', 'Extra fees per month (KES)', hint: 'Fees per term ÷ 4')],
      fixed: {'category': 'school_fees', 'label': 'Higher school fees'}),
  Preset(id: 'baby', title: 'A new baby', subtitle: 'Food, diapers, utilities, house help', icon: Icons.child_friendly_outlined,
      server: 'new_baby', fields: [Field('food', 'Food and diapers per month (KES)', initial: 6000),
        Field('utilities', 'Extra utilities per month (KES)', initial: 1500),
        Field('house_help', 'House help per month (KES)', hint: '0 if none', initial: 0)]),
  Preset(id: 'help', title: 'Hire a house help', subtitle: 'Monthly wages', icon: Icons.cleaning_services_outlined,
      server: 'new_expense', fields: [Field('amount', 'Monthly wage (KES)', initial: 8000)],
      fixed: {'category': 'mobile_money_transfers', 'label': 'House help'}),
  Preset(id: 'support', title: 'Support family', subtitle: 'Regular money sent home', icon: Icons.volunteer_activism_outlined,
      server: 'new_expense', fields: [Field('amount', 'Per month (KES)')],
      fixed: {'category': 'mobile_money_transfers', 'label': 'Family support'}),
];

const studentPresets = [
  Preset(id: 'offcampus', title: 'Move off-campus', subtitle: 'Rent plus getting to class', icon: Icons.apartment_outlined,
      server: 'move_house', fields: [Field('new_rent', 'New rent per month (KES)'),
        Field('extra_transport', 'Extra transport per month (KES)', initial: 1500)]),
  Preset(id: 'laptop', title: 'Laptop or phone', subtitle: 'Cash later or on instalments', icon: Icons.laptop_mac_outlined,
      server: 'purchase', fields: [Field('price', 'Price (KES)'), Field('months', 'Instalments over how many months', initial: 6), _rate],
      fixed: {'label': 'Laptop or phone'}),
  Preset(id: 'gym', title: 'Gym or subscription', subtitle: 'Gym, Netflix, Showmax, Spotify', icon: Icons.fitness_center_outlined,
      server: 'new_expense', fields: [Field('amount', 'Per month (KES)', initial: 2500)],
      fixed: {'category': 'entertainment', 'label': 'Gym or subscription'}),
  Preset(id: 'trip', title: 'Save for a trip', subtitle: 'Holiday, event, travel home', icon: Icons.flight_takeoff_outlined,
      server: 'savings_goal', fields: [Field('target', 'Total cost (KES)'), Field('months', 'Months until the trip', initial: 3)],
      fixed: {'label': 'Trip'}),
  Preset(id: 'helb', title: 'HELB or upkeep delayed', subtitle: 'Less money coming in for a while', icon: Icons.hourglass_bottom_outlined,
      server: 'income_change', fields: [Field('amount', 'Monthly amount you would lose (KES)')], fixed: {'negate': true}),
  Preset(id: 'hustle', title: 'Start a side hustle', subtitle: 'Extra income each month', icon: Icons.storefront_outlined,
      server: 'income_change', fields: [Field('amount', 'Expected extra income per month (KES)')]),
];

const anyonePresets = [
  Preset(id: 'buy', title: 'Buy something', subtitle: 'TV, fridge, furniture, phone', icon: Icons.shopping_bag_outlined,
      server: 'purchase', fields: [Field('price', 'Price (KES)'), Field('months', 'Instalments over how many months', initial: 6), _rate],
      fixed: {'label': 'A purchase'}),
  Preset(id: 'loan', title: 'Take a loan', subtitle: 'SACCO, bank, mobile loan', icon: Icons.account_balance_outlined,
      server: 'loan', fields: [Field('amount', 'Amount borrowed (KES)'), _months, Field('annual_rate', 'Interest per year (%)', initial: 14)],
      fixed: {'label': 'Loan'}),
  Preset(id: 'save', title: 'Save for a goal', subtitle: 'Emergency fund, plot, wedding', icon: Icons.savings_outlined,
      server: 'savings_goal', fields: [Field('target', 'Target amount (KES)'), Field('months', 'Months to reach it', initial: 12)],
      fixed: {'label': 'Savings goal'}),
  Preset(id: 'newcost', title: 'Any new monthly cost', subtitle: 'Something else that repeats', icon: Icons.add_card_outlined,
      server: 'new_expense', fields: [Field('amount', 'Per month (KES)')], fixed: {'category': 'entertainment', 'label': 'New monthly cost'}),
  Preset(id: 'paycut', title: 'Pay cut or job loss', subtitle: 'Test the worst case', icon: Icons.trending_down,
      server: 'income_change', fields: [Field('amount', 'Monthly income you would lose (KES)')], fixed: {'negate': true}),
  Preset(id: 'raise', title: 'A pay rise', subtitle: 'New job or promotion', icon: Icons.trending_up,
      server: 'income_change', fields: [Field('amount', 'Extra income per month (KES)')]),
];

/// The request body for /me/afford from a preset and what the user typed.
Map<String, dynamic> buildChoice(Preset p, Map<String, num> values) {
  final body = <String, dynamic>{'preset': p.server};
  p.fixed.forEach((k, v) {
    if (k != 'negate') body[k] = v;
  });
  values.forEach((k, v) => body[k] = (k == 'amount' && p.fixed['negate'] == true) ? -v : v);
  return body;
}
