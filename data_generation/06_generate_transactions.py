"""
06 - Generate 12 months of monthly transactions, obligations, debt and goals for each sampled household.

DESIGN (all amounts in 2025 KES). What is REAL and what is an ASSUMPTION is marked on each parameter.

REAL / sourced
  * Household incomes, size, rent, housing-loan payment, dependants, school-age children: KIHBS 2015/16 (05/04), CPI-inflated.
  * M-Pesa send-money and agent-withdrawal fee tables: Safaricom 2025 tariff (Buy Goods / Pay Bill are free to the customer).
  * Share of households carrying credit: FinAccess 2024 - 64% of adults used credit; 16.6% of borrowers fully defaulted.
  * Food floor: KIHBS 2015/16 urban food poverty line (~KES 2,551 per adult-equivalent per month) x CPI.

ASSUMPTIONS (state them in the report; KIHBS is cross-sectional so it cannot give month-to-month dynamics)
  * Hidden-state transition matrices, state spending-squeeze ranges, income volatility, loan terms/rates, school fee levels,
    category shares of discretionary spending, household-level spending propensities.
  * School fee levels per term and digital-loan costs are approximate and should be re-checked against current sources.

Structure: spending is built BOTTOM-UP. Rent, school fees, utilities and loan repayments are fixed amounts that tie to the
obligations / debt tables. The hidden state only scales DISCRETIONARY spending, and household obligations make some
households more likely to sit in Strained/Critical (so labels agree with what is observable).
"""
import numpy as np
import pandas as pd
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SYN = ROOT / "data" / "synthetic"
rng = np.random.default_rng(42)
N_MONTHS = 12
STATES = ["Stable", "Strained", "Critical"]
CPI_FACTOR = 1.677                       # from 04_merge_incoming.py (2016 -> 2025 prices)
FOOD_LINE_AE = 2551 * CPI_FACTOR         # urban food poverty line per adult-equivalent per month

# ---- M-Pesa tariffs (Safaricom, 2025): (upper bound of band, fee) -------------------------------------------------
SEND_BANDS = [(100, 0), (500, 7), (1000, 13), (1500, 23), (2500, 33), (3500, 53), (5000, 57), (7500, 78),
              (10000, 90), (15000, 100), (20000, 105), (1e9, 108)]
WITHDRAW_BANDS = [(100, 11), (2500, 29), (3500, 52), (5000, 69), (7500, 87), (10000, 115), (15000, 167),
                  (20000, 185), (35000, 197), (50000, 278), (1e9, 309)]


def band_fee(amount, bands):
    for ub, fee in bands:
        if amount <= ub:
            return fee
    return bands[-1][1]


def split_and_fee(total, typical, bands):
    """Split a monthly total into transactions of roughly `typical` size and sum the M-Pesa fees."""
    if total <= 0:
        return 0.0
    k = max(1, int(round(total / max(typical, 50))))
    sizes = rng.dirichlet(np.ones(k)) * total
    return float(sum(band_fee(x, bands) for x in sizes))


# ---- Hidden-state dynamics (ASSUMPTIONS) -------------------------------------------------------------------------
TIER_TRANSITIONS = {
    "formal_salaried": {"prior": [0.65, 0.27, 0.08],
                        "trans": [[0.88, 0.10, 0.02], [0.25, 0.60, 0.15], [0.10, 0.35, 0.55]]},
    "informal_irregular": {"prior": [0.30, 0.45, 0.25],
                           "trans": [[0.60, 0.30, 0.10], [0.25, 0.50, 0.25], [0.10, 0.35, 0.55]]},
}
STRESSED_PRIOR = np.array([0.05, 0.35, 0.60])
STRESSED_TRANS = np.array([[0.40, 0.35, 0.25], [0.10, 0.45, 0.45], [0.05, 0.25, 0.70]])
# Target total spending as a fraction of income. Ranges deliberately OVERLAP between states (real households are not clean).
STATE_RATIO = {"Stable": (0.60, 0.92), "Strained": (0.85, 1.10), "Critical": (1.00, 1.40)}

# Discretionary spending categories: base share of the discretionary budget, and state multipliers.
DISC_SHARE = {"food_groceries": 0.50, "transport": 0.14, "airtime_data": 0.07, "mobile_money_transfers": 0.09,
              "entertainment": 0.07, "savings": 0.08, "investment_vehicle": 0.05}
STATE_MULT = {
    "Stable":   {"entertainment": 1.0, "savings": 1.0, "investment_vehicle": 1.0},
    "Strained": {"entertainment": 0.6, "savings": 0.45, "investment_vehicle": 0.4},
    "Critical": {"entertainment": 0.25, "savings": 0.10, "investment_vehicle": 0.10, "food_groceries": 1.05},
}
# Household-level random effects (fixed per household): some never save / invest, tastes differ.
PROP_SIGMA = {"food_groceries": 0.15, "transport": 0.35, "airtime_data": 0.30, "mobile_money_transfers": 0.50,
              "entertainment": 0.50, "savings": 0.70, "investment_vehicle": 0.80}
P_NEVER_SAVES, P_NEVER_INVESTS = 0.25, 0.65


def seasonal(cat, m):  # m = 1..12 (Jan..Dec)
    if cat == "entertainment" and m == 12: return 1.6
    if cat == "food_groceries" and m == 12: return 1.2
    if cat == "transport" and m in (1, 5, 9): return 1.1     # school-term travel
    return 1.0


def hh_state_sequence(tier, pressure):
    p = TIER_TRANSITIONS[tier]
    w = 0.7 * pressure
    prior = (1 - w) * np.array(p["prior"]) + w * STRESSED_PRIOR
    trans = (1 - w) * np.array(p["trans"]) + w * STRESSED_TRANS
    s = rng.choice(3, p=prior)
    seq = [s]
    for _ in range(N_MONTHS - 1):
        s = rng.choice(3, p=trans[s]); seq.append(s)
    return [STATES[i] for i in seq]


# ---- Income -------------------------------------------------------------------------------------------------------
def make_income_plan(h):
    """Household-level income traits fixed for the year."""
    base = h["monthly_income_base"]
    plan = {"base": base, "tier": h["income_tier"]}
    if h["income_tier"] == "formal_salaried":
        plan["bonus"] = rng.random() < 0.30 and rng.uniform(0.5, 1.0) or 0.0           # December bonus (x salary)
        plan["side_gig"] = rng.random() < 0.25
    else:
        plan["side_gig"] = rng.random() < 0.20
    plan["remit_in"] = bool(h["receives_support"])
    return plan


def month_income(plan, m):
    base, tier = plan["base"], plan["tier"]
    primary = secondary = cash = 0.0
    if tier == "formal_salaried":
        primary = base * rng.normal(1.0, 0.02)
        if rng.random() < 0.015: primary = 0.0                                          # delayed salary month
        if m == 12: primary += base * plan["bonus"]
        if plan["side_gig"] and rng.random() < 0.7: secondary += base * rng.uniform(0.05, 0.25)
    else:
        f = rng.lognormal(mean=-0.045, sigma=0.30)                                      # mean ~1, month-to-month volatility
        u = rng.random()
        if u < 0.04: f = 0.0                                                            # no work this month
        elif u < 0.14: f *= rng.uniform(0.1, 0.5)                                       # slack month
        if m == 12: f *= 1.10
        primary = base * f
        if plan["side_gig"] and rng.random() < 0.5: cash = base * rng.uniform(0.05, 0.30)
    if plan["remit_in"] and rng.random() < 0.6: secondary += base * rng.uniform(0.03, 0.12)
    return round(max(primary, 0), 2), round(max(secondary, 0), 2), round(max(cash, 0), 2)


# ---- Fixed obligations & debt ---------------------------------------------------------------------------------------
def annuity(principal, annual_rate, months):
    r = annual_rate / 12
    return principal / months if r == 0 else principal * r / (1 - (1 + r) ** -months)


def make_debts(h, rng):
    base = h["monthly_income_base"]
    debts = []
    if h["housing_loan_payment"] > 0:                                                    # REAL KIHBS housing loan
        pay = float(h["housing_loan_payment"]); months = int(rng.integers(60, 240))
        debts.append({"debt_type": "housing_loan", "total_outstanding": round(pay * months * 0.7, 2),
                      "monthly_repayment": round(pay, 2), "interest_rate": round(rng.uniform(0.13, 0.17), 3),
                      "remaining_months": months})
    formal = h["income_tier"] == "formal_salaried"
    if rng.random() < 0.45:                                                              # ASSUMPTION anchored on FinAccess 64% credit use
        r = rng.random()
        kinds = (["sacco_bank"] if r < 0.5 else ["mobile_digital"] if r < 0.8 else ["sacco_bank", "mobile_digital"]) if formal \
            else (["mobile_digital"] if r < 0.6 else ["sacco_bank"] if r < 0.85 else ["sacco_bank", "mobile_digital"])
        for kind in kinds:
            if kind == "mobile_digital":
                principal = float(np.clip(base * rng.uniform(0.1, 0.5), 500, 40000))
                months = int(rng.integers(1, 5)); mrate = rng.uniform(0.08, 0.15)       # ASSUMPTION: monthly cost of digital loans
                repay = principal * (1 + mrate * months) / months
                annual = mrate * 12
            else:
                principal = float(np.clip(base * rng.uniform(2, 8), 5000, 2_000_000))
                months = int(rng.integers(12, 49)); annual = rng.uniform(0.12, 0.18)
                repay = annuity(principal, annual, months)
            cap = 0.35 * base                                                            # lenders rarely give more than ~1/3 of income
            if repay > cap:
                scale = cap / repay; principal *= scale; repay = cap
            if repay < 100: continue
            debts.append({"debt_type": kind, "total_outstanding": round(principal, 2),
                          "monthly_repayment": round(repay, 2), "interest_rate": round(annual, 3), "remaining_months": months})
    return debts


def make_school_plan(h):
    """Term fee per child, downgraded until total termly fees <= 1.3x monthly income. ASSUMED fee levels (KES per term)."""
    base = h["monthly_income_base"]
    p_private = float(np.clip(0.03 + 0.55 * base / 200000, 0.02, 0.6))
    fees = 0.0; kids = []
    for _ in range(int(h["num_primary_children"])):
        kids.append("private_primary" if rng.random() < p_private else "public_primary")
    for _ in range(int(h["num_secondary_children"])):
        r = rng.random()
        kids.append("private_secondary" if r < p_private * 0.6 else "public_boarding" if r < 0.2 + p_private else "public_day_secondary")
    level = {"public_primary": 3000, "private_primary": 22000, "public_day_secondary": 7500,
             "public_boarding": 17000, "private_secondary": 32000}
    downgrade = {"private_primary": "public_primary", "private_secondary": "public_boarding", "public_boarding": "public_day_secondary"}
    def total(k): return sum(level[x] * rng.lognormal(0, 0.0) for x in k)
    for _ in range(20):
        if total(kids) <= 1.3 * base: break
        i = max(range(len(kids)), key=lambda j: level[kids[j]]) if kids else None
        if i is None or kids[i] not in downgrade: break
        kids[i] = downgrade[kids[i]]
    return float(total(kids)) * rng.lognormal(0, 0.08) if kids else 0.0


def month_transactions(h, hid, m, state, income, fixed, prop, debts, rent, school_term_fee, food_floor):
    primary, secondary, cash = income
    total_income = primary + secondary + cash
    lo, hi = STATE_RATIO[state]
    ref_income = total_income if total_income > 0 else h["monthly_income_base"] * 0.6    # households still spend in zero-income months
    target = ref_income * rng.uniform(lo, hi)

    # fixed monthly amounts (tie to obligations / debt tables)
    util = fixed["utilities"] * rng.normal(1.0, 0.10)
    sf = 0.0
    if school_term_fee > 0:
        sf = school_term_fee if m in (1, 5, 9) else school_term_fee * 0.08               # term-opening fees + small monthly extras
    mortgage = sum(d["monthly_repayment"] for d in debts if d["debt_type"] == "housing_loan")
    loan_rep = sum(d["monthly_repayment"] for d in debts if d["debt_type"] != "housing_loan" and m <= d["remaining_months"])
    housing = rent + mortgage
    fixed_total = housing + util + sf + loan_rep

    disc_target = target - fixed_total
    disc = max(disc_target, food_floor * 1.0)

    w = {}
    for c, b in DISC_SHARE.items():
        mult = STATE_MULT[state].get(c, 1.0)
        w[c] = b * prop[c] * mult * rng.lognormal(0, 0.25)
    sw = sum(w.values())
    amounts = {c: disc * w[c] / sw for c in w}
    amounts["food_groceries"] = max(amounts["food_groceries"], food_floor * 0.9)          # cannot squeeze food below subsistence
    for c in amounts:
        amounts[c] = max(0.0, amounts[c] * seasonal(c, m) * rng.normal(1.0, 0.10))

    amounts.update({"housing": housing * rng.normal(1.0, 0.0) if housing > 0 else 0.0, "utilities": max(util, 0),
                    "school_fees": sf, "loan_repayment": loan_rep})

    # M-Pesa fees: send-money fees on transfers + agent withdrawal fees on the cash share of everyday spending
    fee = split_and_fee(amounts["mobile_money_transfers"], rng.lognormal(np.log(1200), 0.4), SEND_BANDS)
    cash_spend = 0.35 * (amounts["food_groceries"] + amounts["transport"] + amounts["entertainment"])
    fee += split_and_fee(cash_spend, rng.lognormal(np.log(2000), 0.4), WITHDRAW_BANDS)
    amounts["transaction_fees"] = fee

    rows = [{"household_id": hid, "month": m, "category": c, "amount": round(float(a), 2), "true_state": state}
            for c, a in amounts.items()]
    rows.append({"household_id": hid, "month": m, "category": "income_primary", "amount": round(primary, 2), "true_state": state})
    if secondary > 0: rows.append({"household_id": hid, "month": m, "category": "income_secondary", "amount": round(secondary, 2), "true_state": state})
    if cash > 0: rows.append({"household_id": hid, "month": m, "category": "informal_cash_income", "amount": round(cash, 2), "true_state": state})
    return rows


households = pd.read_csv(SYN / "households.csv")
all_tx, all_obl, all_debt, all_goals, all_states = [], [], [], [], []

for _, h in households.iterrows():
    hid, tier = h["household_id"], h["income_tier"]
    base = h["monthly_income_base"]
    debts = make_debts(h, rng)
    rent = float(h["housing_cost_real"]) if str(h["housing_status"]).lower().startswith("rent") else 0.0
    fixed = {"utilities": float(np.clip(600 + 0.025 * base + 120 * h["household_size"], 500, 18000) * rng.lognormal(0, 0.12))}
    school_term_fee = make_school_plan(h)
    food_floor = 0.6 * FOOD_LINE_AE * h["adult_equivalent_size"]                           # below the food poverty line = deprivation

    # structural burden -> pressure (pushes the hidden state toward Strained/Critical)
    repay_avg = sum(d["monthly_repayment"] for d in debts)
    burden = (rent + repay_avg + fixed["utilities"] + school_term_fee / 4 + food_floor) / base
    pressure = float(np.clip((burden - 0.55) / 0.6, 0, 1))

    prop = {c: rng.lognormal(0, PROP_SIGMA[c]) for c in DISC_SHARE}
    if rng.random() < P_NEVER_SAVES: prop["savings"] = 0.02
    if rng.random() < P_NEVER_INVESTS: prop["investment_vehicle"] = 0.0
    if h["gives_support"]: prop["mobile_money_transfers"] *= 2.0                           # real KIHBS flag: household sends money to others

    plan = make_income_plan(h)
    seq = hh_state_sequence(tier, pressure)
    for m_idx, state in enumerate(seq):
        m = m_idx + 1
        all_tx.extend(month_transactions(h, hid, m, state, month_income(plan, m), fixed, prop, debts, rent, school_term_fee, food_floor))
        all_states.append({"household_id": hid, "month": m, "true_state": state})

    # obligations table (amounts match what the transactions use)
    due = lambda lo_, hi_: int(rng.integers(lo_, hi_))
    if rent > 0: all_obl.append({"household_id": hid, "type": "rent", "amount": round(rent, 2), "due_day": due(1, 6), "frequency": "monthly"})
    if school_term_fee > 0: all_obl.append({"household_id": hid, "type": "school_fees", "amount": round(school_term_fee, 2), "due_day": due(1, 15), "frequency": "termly"})
    all_obl.append({"household_id": hid, "type": "utility", "amount": round(fixed["utilities"], 2), "due_day": due(15, 26), "frequency": "monthly"})
    for d in debts:
        all_obl.append({"household_id": hid, "type": d["debt_type"], "amount": d["monthly_repayment"], "due_day": due(1, 28), "frequency": "monthly"})
        all_debt.append({"household_id": hid, **d})

    if h["has_active_goal"]:                                                                  # ASSUMED 40% of households
        non_mortgage = [d for d in debts if d["debt_type"] != "housing_loan"]
        if non_mortgage and rng.random() < 0.4:
            gtype, target = "debt_payoff", sum(d["total_outstanding"] for d in non_mortgage)
            months = int(rng.integers(6, 25))
        else:
            gtype = str(rng.choice(["emergency_fund", "school_fees", "business_capital", "land_or_home", "savings"]))
            target = round(base * rng.uniform(3, 12), -3); months = int(rng.integers(6, 25))
        all_goals.append({"household_id": hid, "goal_type": gtype, "target_amount": round(float(target), 2),
                          "deadline_months": months, "monthly_required_contribution": round(float(target) / months, 2)})

out = {"transactions": pd.DataFrame(all_tx), "obligations": pd.DataFrame(all_obl), "debt": pd.DataFrame(all_debt),
       "goals": pd.DataFrame(all_goals), "true_states": pd.DataFrame(all_states)}
for name, d in out.items():
    d.to_csv(SYN / f"{name}.csv", index=False)
    print(name, d.shape)
