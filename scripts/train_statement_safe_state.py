"""Statement-safe financial-state model (docs/experiments.md, 4 Nov).

M-PESA statements give exact totals, income, savings and loan repayments, but not a reliable split of everyday
spending (a payment to "Jane Mwangi" could be groceries or family). The deployed state detector uses category
shares (entertainment share, transport share...), so a large unsorted amount could move it. This trains a second
Random Forest on features a statement gives exactly, with the same settings and the same 240/60 household split,
and stores it next to the first one in backend/models/affordability_engine.joblib. The app uses it when more than
10% of a household's spending is unsorted.

Run: python scripts/train_statement_safe_state.py
"""
import sys
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier

ROOT = Path(__file__).resolve().parents[1] if len(sys.argv) < 2 else Path(sys.argv[1])
ENGINE = ROOT / "backend/models/affordability_engine.joblib"
EXACT = ["total_expenditure", "total_income", "income_to_expenditure_ratio", "zero_income_flag", "savings",
         "savings_rate", "savings_share", "monthly_debt_repayment", "debt_service_coverage_ratio", "overspend_flag",
         "ratio_roll3", "overspend_roll3", "exp_roll3", "exp_roll6", "spending_regularity_score", "household_size",
         "num_dependants", "dependant_cost_factor", "income_primary", "income_secondary", "informal_cash_income",
         "loan_repayment"]

d = pd.read_csv(ROOT / "data/processed/engineered_features_raw.csv")
split = pd.read_csv(ROOT / "data/processed/household_split.csv").set_index("household_id")["split"]
d["split"] = d["household_id"].map(split)
train, test = d[d.split == "train"], d[d.split == "test"]
engine = joblib.load(ENGINE)
ORDER = {"Stable": 0, "Strained": 1, "Critical": 2}


def report(name, model, feats):
    p = model.predict(test[feats])
    acc = float((p == test.true_state).mean())
    far = float(np.mean([abs(ORDER[a] - ORDER[b]) == 2 for a, b in zip(p, test.true_state)]))
    print(f"{name:44s} held-out accuracy {acc:.3f}   Stable<->Critical mix-ups {far:.3f}")
    return acc


report("deployed (uses category shares)", engine["state_model"], engine["state_features"])
safe = RandomForestClassifier(n_estimators=300, min_samples_leaf=5, random_state=0, n_jobs=-1)
safe.fit(train[EXACT], train.true_state)
acc = report("statement-safe (exact figures only)", safe, EXACT)

# How much does unsorted money move each model? Move 30% of everyday spending into one category, as a wrong
# guess would, and count how often the state changes.
EVERYDAY = ["food_groceries", "transport", "utilities", "airtime_data", "mobile_money_transfers", "entertainment"]
import importlib.util
spec = importlib.util.spec_from_file_location("aff", ROOT / "backend/affordability.py")
aff = importlib.util.module_from_spec(spec)
spec.loader.exec_module(aff)
changed = {"deployed": 0, "statement-safe": 0}
n = 0
for hid, g in test.groupby("household_id"):
    m = aff.months_frame(g.sort_values("month")[aff.CATS + aff.INCOME].to_dict("records"),
                         g.household_size.iloc[0], g.num_dependants.iloc[0])
    f = aff.build_features(m).iloc[[-1]]
    moved = m.copy()
    pot = moved[EVERYDAY].sum(axis=1) * 0.3
    for c in EVERYDAY:
        moved[c] = moved[c] * 0.7
    moved["entertainment"] += pot                      # a wrong guess: all unsorted money called "fun"
    f2 = aff.build_features(moved).iloc[[-1]]
    changed["deployed"] += engine["state_model"].predict(f[engine["state_features"]])[0] != \
        engine["state_model"].predict(f2[engine["state_features"]])[0]
    changed["statement-safe"] += safe.predict(f[EXACT])[0] != safe.predict(f2[EXACT])[0]
    n += 1
print(f"state changed when 30% of everyday money is mis-sorted as fun: deployed {changed['deployed']}/{n}, "
      f"statement-safe {changed['statement-safe']}/{n}")

engine["state_model_exact"], engine["state_features_exact"] = safe, EXACT
engine["state_exact_accuracy"] = round(acc, 3)
joblib.dump(engine, ENGINE, compress=3)   # keeps the file small enough for git
print("Saved", ENGINE)
