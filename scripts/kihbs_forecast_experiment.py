"""Forecast for app users: does a model beat the median on KIHBS-informed household data?

The app forecasts next month from a user's own months (manual records, estimates or an M-Pesa statement), in the
10 app categories. Until now it used a statistical rule (median of monthly totals, split by average shares).
This experiment tests learned models against that rule, on the same 240 train / 60 test households as every
other engine, simulating users with 1, 3, 6 and 11 months of history.

Only inputs known before the month starts are used: past months, income, household facts and the calendar month
(the app knows which month it is forecasting). Model choice is made on validation households carved out of
train; the 60 test households are scored once at the end.

Run: python scripts/kihbs_forecast_experiment.py   (part 1; part 2 is scripts/forecast_improvements.py)
"""
import sys
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
from sklearn.ensemble import HistGradientBoostingRegressor

ROOT = Path(__file__).resolve().parents[1] if len(sys.argv) < 2 else Path(sys.argv[1])
CATS = ["housing", "food_groceries", "transport", "utilities", "airtime_data",
        "mobile_money_transfers", "loan_repayment", "school_fees", "entertainment", "savings"]
HISTORY = (1, 3, 6, 11)
FEE_MONTHS = (1, 5, 9)          # Kenyan school terms start in January, May and September

d = pd.read_csv(ROOT / "data/processed/engineered_features_raw.csv")
split = pd.read_csv(ROOT / "data/processed/household_split.csv").set_index("household_id")["split"]
d["spend"] = d[CATS].sum(axis=1)
d = d.sort_values(["household_id", "month"])


def examples(households):
    """One row per (household, target month, history length): what the app would know, and what happened."""
    rows = []
    for hid, g in d[d.household_id.isin(households)].groupby("household_id"):
        g = g.set_index("month")
        for t in range(2, 13):
            for h in HISTORY:
                past = g.loc[max(1, t - h):t - 1]
                if len(past) < min(h, t - 1) or len(past) == 0:
                    continue
                tot = past["spend"]
                shares = (past[CATS].div(tot.replace(0, np.nan), axis=0)).mean().fillna(0)
                fees_past = past.loc[past.index.isin(FEE_MONTHS), "school_fees"]
                rows.append({
                    "household_id": hid, "t": t, "h": len(past),
                    "median": tot.median(), "mean": tot.mean(), "last": tot.iloc[-1],
                    "min": tot.min(), "max": tot.max(), "std": tot.std() if len(tot) > 1 else 0.0,
                    "income": past["total_income"].iloc[-1], "income_mean": past["total_income"].mean(),
                    "household_size": g["household_size"].iloc[0], "num_dependants": g["num_dependants"].iloc[0],
                    "formal": int(g["income_tier"].iloc[0] == "formal_salaried"),
                    "month": t, "fee_month": int(t in FEE_MONTHS), "december": int(t == 12),
                    "fees_seen": fees_past.max() if len(fees_past) else 0.0,
                    "fees_median": past["school_fees"].median(),
                    **{f"share_{c}": shares[c] for c in CATS},
                    **{f"med_{c}": past[c].median() for c in CATS},
                    **{f"act_{c}": g.loc[t, c] for c in CATS},
                    "actual": g.loc[t, "spend"],
                })
    return pd.DataFrame(rows)


train_ids = split[split == "train"].index.to_numpy()
rng = np.random.default_rng(42)
val_ids = rng.choice(train_ids, size=48, replace=False)
fit_ids = np.setdiff1d(train_ids, val_ids)
test_ids = split[split == "test"].index.to_numpy()
FIT, VAL, TEST = examples(fit_ids), examples(val_ids), examples(test_ids)

BASE = ["h", "median", "mean", "last", "min", "max", "std", "income", "income_mean",
        "household_size", "num_dependants", "formal"]
CAL = ["month", "fee_month", "december", "fees_seen", "fees_median"]


def tree(features, df):
    """Boosted tree predicting next month's total as a multiple of the household's median (scale-free)."""
    m = HistGradientBoostingRegressor(loss="absolute_error", max_iter=300, learning_rate=0.05,
                                      min_samples_leaf=40, random_state=0)
    m.fit(df[features], df["actual"] / df["median"].clip(lower=1))
    return m


def split_by_shares(df, total):
    return {c: total * df[f"share_{c}"] for c in CATS}


def fee_aware_split(df, total):
    """Shares for everything except school fees; fees get the amount seen in past fee months in a fee month."""
    fees = np.where(df["fee_month"] == 1, df["fees_seen"], df["fees_median"])
    rest_share = 1 - df["share_school_fees"]
    rest = (total - fees).clip(lower=0)
    out = {c: rest * df[f"share_{c}"] / rest_share.replace(0, np.nan).fillna(1) for c in CATS if c != "school_fees"}
    out["school_fees"] = pd.Series(fees, index=df.index)
    return out


def median_split(df, total):
    """Split in proportion to each category's own median (zero for categories the household usually skips)."""
    meds = sum(df[f"med_{c}"] for c in CATS).replace(0, np.nan)
    return {c: (total * df[f"med_{c}"] / meds).fillna(0) for c in CATS}


def score(df, total, cats):
    err = (total - df["actual"]).abs()
    cat_err = sum((cats[c] - df[f"act_{c}"]).abs() for c in CATS)
    return {"MAE": err.mean(), "WAPE": err.sum() / df["actual"].sum(),
            "cat_WAPE": cat_err.sum() / sum(df[f"act_{c}"] for c in CATS).sum()}


def methods(df, fitted):
    out = {
        "median (app today)": (df["median"], split_by_shares(df, df["median"])),
        "last month": (df["last"], split_by_shares(df, df["last"])),
        "mean": (df["mean"], split_by_shares(df, df["mean"])),
        "per-category median": (sum(df[f"med_{c}"] for c in CATS), {c: df[f"med_{c}"] for c in CATS}),
    }
    for name, (m, feats) in fitted.items():
        total = df["median"] * m.predict(df[feats])
        out[name] = (total, split_by_shares(df, total))
        out[name + " + fee-aware split"] = (total, fee_aware_split(df, total))
        out[name + " + per-category-median split"] = (total, median_split(df, total))
    return out


def table(df, fitted, by_h=False):
    rows = []
    for name, (total, cats) in methods(df, fitted).items():
        rows.append({"method": name, **score(df, total, cats)})
        if by_h:
            for h in HISTORY:
                sub = df["h"] == h
                if sub.any():
                    rows[-1][f"MAE h={h}"] = (total[sub] - df.loc[sub, "actual"]).abs().mean()
    return pd.DataFrame(rows).set_index("method").round(3)


fitted = {"tree, history only": (tree(BASE, FIT), BASE), "tree, history + calendar": (tree(BASE + CAL, FIT), BASE + CAL)}
pd.set_option("display.width", 250)
pd.set_option("display.max_columns", 20)
print("VALIDATION (48 households from train, used to choose)")
val = table(VAL, fitted)
print(val)
best = val.sort_values(["MAE", "cat_WAPE"]).index[0]   # same total? the better category split wins
print("\nChosen on validation:", best)

# Refit the chosen model on all train households, then score the 60 test households once.
ALL = pd.concat([FIT, VAL])
final = {k: (tree(feats, ALL), feats) for k, (_, feats) in fitted.items()}
print("\nTEST (60 held-out households, scored once)")
print(table(TEST, final, by_h=True))

print("\nThe deployed model is trained and saved by scripts/forecast_improvements.py (part 2).")
