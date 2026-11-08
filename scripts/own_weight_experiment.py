"""How much should a household's own spending pattern count, by months of history? (8 Nov)

The budget splits everyday money between food, transport, utilities, airtime, money sent and fun. Today the split is
half "households like you" (Random Forest + average Stable split, the 28 Oct result) and half the household's own
past shares, whatever the history. This checks whether the own share should grow with history.

Method: held-out (test) households from the KIHBS-informed synthetic set, Stable months only (what a healthy month
looks like). For month t, the household's own shares come from its previous months (at most 6); the prediction is
the month's actual everyday total times the blended shares; error = KES off per category (as on 28 Oct).
Test households are split in two by ID: weights are CHOSEN on the first half and CONFIRMED once on the second.
Rule fixed before running: keep 0.5 for a history bucket unless another weight is more than 2% better on the
choosing half.

Run from the repo root:  python scripts/own_weight_experiment.py
"""
from pathlib import Path

import joblib
import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
PROC, SYN = ROOT / "data" / "processed", ROOT / "data" / "synthetic"
WEIGHTS = [0.0, 0.33, 0.5, 0.67, 0.8]
BUCKETS = {1: "1-2 months", 3: "3-5 months", 6: "6+ months"}

m = joblib.load(ROOT / "backend" / "models" / "budget_split.joblib")
VARIABLE, X_COLS = m["variable"], m["x_cols"]
FIXED = ["housing", "loan_repayment", "school_fees"]

raw = (pd.read_csv(PROC / "engineered_features_raw.csv")
       .merge(pd.read_csv(PROC / "household_split.csv"), on="household_id"))
hh = pd.read_csv(SYN / "households.csv")[["household_id", "urban_rural", "income_tier"]]
raw = raw.drop(columns=[c for c in ("urban_rural", "income_tier") if c in raw.columns]).merge(hh, on="household_id")
if "true_state" not in raw.columns:
    raw = raw.merge(pd.read_csv(SYN / "true_states.csv"), on=["household_id", "month"])
raw["variable_total"] = raw[VARIABLE].sum(axis=1)
raw["available"] = (raw["total_income"] - raw[FIXED].sum(axis=1) - raw["savings"]).clip(lower=0)
raw["is_formal"] = (raw["income_tier"] == "formal_salaried").astype(int)
raw["urban"] = (raw["urban_rural"] == "urban").astype(int)
raw["peri_urban"] = (raw["urban_rural"] == "peri_urban").astype(int)

test_ids = sorted(raw.loc[raw.split == "test", "household_id"].unique())
halves = {"choose": set(test_ids[: len(test_ids) // 2]), "confirm": set(test_ids[len(test_ids) // 2:])}


def bucket(n):
    return 6 if n >= 6 else (3 if n >= 3 else 1)


rows = []
for hid, g in raw[raw.household_id.isin(test_ids)].groupby("household_id"):
    g = g.sort_values("month").reset_index(drop=True)
    base_all = 0.5 * m["split_model"].predict(g[X_COLS]) + 0.5 * m["one_size"]
    for t in range(1, len(g)):
        r = g.iloc[t]
        if r.true_state != "Stable" or r.variable_total <= 0:
            continue
        hist = g.iloc[max(0, t - 6):t]
        own_tot = hist[VARIABLE].sum()
        if own_tot.sum() <= 0:
            continue
        own = (own_tot / own_tot.sum()).values
        base = base_all[t] / base_all[t].sum()
        actual = r[VARIABLE].values.astype(float)
        for w in WEIGHTS:
            share = (1 - w) * base + w * own
            pred = r.variable_total * share / share.sum()
            rows.append({"household": hid, "bucket": bucket(t), "w": w, **dict(zip(VARIABLE, np.abs(pred - actual)))})

err = pd.DataFrame(rows)
err["half"] = np.where(err.household.isin(halves["choose"]), "choose", "confirm")


def table(half):
    e = err[err.half == half]
    return e.groupby(["bucket", "w"])[VARIABLE].mean().sum(axis=1).unstack("w").round(0)


choose, confirm = table("choose"), table("confirm")
print("Average KES off per household-month, summed over the six everyday categories (lower is better)\n")
print("Choosing half:\n", choose.rename(index=BUCKETS), "\n")
print("Confirming half:\n", confirm.rename(index=BUCKETS), "\n")
picked = {}
for b in choose.index:
    best = choose.loc[b].idxmin()
    picked[b] = best if choose.loc[b, best] < 0.98 * choose.loc[b, 0.5] else 0.5
    print(f"{BUCKETS[b]}: chosen weight {picked[b]} | confirm: {confirm.loc[b, picked[b]]:.0f} "
          f"vs 0.5: {confirm.loc[b, 0.5]:.0f} (n={int((err[(err.bucket == b) & (err.w == 0.5)]).shape[0])})")
print("\nPut this in backend/budget.py OWN_WEIGHT:", {int(k): float(v) for k, v in picked.items()})
