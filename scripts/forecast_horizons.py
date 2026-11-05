"""Forecast for app users, part 5: one to three months ahead (proposal 3.2.3; docs/experiments.md, 5 Nov).

The deployed model (scripts/forecast_improvements.py) forecasts the next month from the household's past months.
For month 2 and 3 ahead the past ends 2 or 3 months before the target month. Two options, chosen on the same
48 validation households and scored once on the 60 test households:
  A. reuse the one-month model (its inputs are summaries of the past plus the target month's fee/December flags);
  B. train one model per horizon on examples with that gap.
Each is compared with the household's median, and the 80% range is re-widened per horizon on validation so it
still holds about 80% of months further ahead.
Run: python scripts/forecast_horizons.py   (adds per-horizon settings to backend/models/user_forecast.joblib)
"""
import sys
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
from sklearn.ensemble import HistGradientBoostingRegressor

ROOT = Path(__file__).resolve().parents[1] if len(sys.argv) < 2 else Path(sys.argv[1])
OUT = ROOT / "backend/models/user_forecast.joblib"
CATS = ["housing", "food_groceries", "transport", "utilities", "airtime_data",
        "mobile_money_transfers", "loan_repayment", "school_fees", "entertainment", "savings"]
FEE_MONTHS, HISTORY, HORIZONS, OWN_Z = (1, 5, 9), (1, 3, 6, 11), (1, 2, 3), 1.2816

d = pd.read_csv(ROOT / "data/processed/engineered_features_raw.csv").sort_values(["household_id", "month"])
split = pd.read_csv(ROOT / "data/processed/household_split.csv").set_index("household_id")["split"]
d["spend"] = d[CATS].sum(axis=1)
eng = joblib.load(OUT)
FEATS = eng["features"]


def features(past, t, g):
    tot = past["spend"]
    fees_past = past.loc[past.index.isin(FEE_MONTHS), "school_fees"]
    return {"h": len(past), "median": tot.median(), "mean": tot.mean(), "last": tot.iloc[-1], "min": tot.min(),
            "max": tot.max(), "std": tot.std() if len(tot) > 1 else 0.0,
            "income": past["total_income"].iloc[-1], "income_mean": past["total_income"].mean(),
            "household_size": g["household_size"].iloc[0], "num_dependants": g["num_dependants"].iloc[0],
            "formal": int(g["income_tier"].iloc[0] == "formal_salaried"), "fee_month": int(t in FEE_MONTHS),
            "december": int(t == 12), "fees_seen": fees_past.max() if len(fees_past) else 0.0,
            "fees_median": past["school_fees"].median()}


def examples(households, k):
    """Every target month t with history ending k months before it (k = 1 is next month)."""
    rows = []
    for hid, g in d[d.household_id.isin(households)].groupby("household_id"):
        g = g.set_index("month")
        for t in range(k + 1, 13):
            end = t - k
            for h in HISTORY:
                past = g.loc[max(1, end - h + 1):end]
                if len(past) < min(h, end):
                    continue
                rows.append({"household_id": hid, "t": t, **features(past, t, g), "actual": g.loc[t, "spend"]})
    return pd.DataFrame(rows)


def fit(df, loss="absolute_error", q=None):
    kw = dict(max_iter=300, learning_rate=0.05, min_samples_leaf=40, random_state=0)
    if q is not None:
        kw["quantile"] = q
    return HistGradientBoostingRegressor(loss=loss, **kw).fit(df[FEATS], df["actual"] / df["median"].clip(lower=1))


def predict(m, df):
    return df["median"].clip(lower=1) * m.predict(df[FEATS])


def personal(df, mid, lo, hi, w):
    dl, dh, own = (mid - lo).clip(lower=0), (hi - mid).clip(lower=0), OWN_Z * df["std"]
    use = df["h"] >= 3
    dl, dh = np.where(use, 0.5 * dl + 0.5 * own, dl), np.where(use, 0.5 * dh + 0.5 * own, dh)
    return mid - w * dl, mid + w * dh


def mae(df, pred):
    return float((pred - df["actual"]).abs().mean())


train_ids = split[split == "train"].index.to_numpy()
val_ids = np.random.default_rng(42).choice(train_ids, size=48, replace=False)      # same split as part 2
fit_ids, test_ids = np.setdiff1d(train_ids, val_ids), split[split == "test"].index.to_numpy()

one = {"mid": fit(examples(fit_ids, 1)), "lo": fit(examples(fit_ids, 1), "quantile", 0.1),
       "hi": fit(examples(fit_ids, 1), "quantile", 0.9)}
print("VALIDATION (48 households), MAE in KES")
print(f"  {'months ahead':14s} {'median':>8s} {'A: reuse':>9s} {'B: own model':>13s}")
choice, widen = {}, {}
for k in HORIZONS:
    fk, vk = examples(fit_ids, k), examples(val_ids, k)
    own = {"mid": fit(fk), "lo": fit(fk, "quantile", 0.1), "hi": fit(fk, "quantile", 0.9)}
    a, b = mae(vk, predict(one["mid"], vk)), mae(vk, predict(own["mid"], vk))
    choice[k] = "reuse" if k == 1 or b > 0.98 * a else "own"       # keep one model unless B gains over 2%
    use = one if choice[k] == "reuse" else own
    mid, lo, hi = predict(use["mid"], vk), predict(use["lo"], vk), predict(use["hi"], vk)
    for w in np.arange(1.0, 3.01, 0.05):
        l_, h_ = personal(vk, mid, lo, hi, w)
        if ((vk.actual >= l_) & (vk.actual <= h_)).mean() >= 0.80:
            widen[k] = round(float(w), 2)
            break
    print(f"  {k:<14d} {mae(vk, vk['median']):8,.0f} {a:9,.0f} {b:13,.0f}   -> {choice[k]}, range x{widen[k]}")

# Final: refit on all train households (as the deployed one-month model was), score the test households once.
all_ids = train_ids
final = {}
print("\nTEST (60 held-out households)")
print(f"  {'months ahead':14s} {'median':>8s} {'model':>8s} {'gain':>6s} {'in range':>9s} {'avg width':>10s}")
for k in HORIZONS:
    if choice[k] == "reuse":
        use = {"mid": eng["model"], "lo": eng["low"], "hi": eng["high"]}       # exactly what the app runs
    else:
        ak = examples(all_ids, k)
        use = {"mid": fit(ak), "lo": fit(ak, "quantile", 0.1), "hi": fit(ak, "quantile", 0.9)}
    final[k] = use
    tk = examples(test_ids, k)
    mid = predict(use["mid"], tk)
    lo_, hi_ = personal(tk, mid, predict(use["lo"], tk), predict(use["hi"], tk), widen[k])
    inside = ((tk.actual >= lo_) & (tk.actual <= hi_)).mean()
    m0, m1 = mae(tk, tk["median"]), mae(tk, mid)
    print(f"  {k:<14d} {m0:8,.0f} {m1:8,.0f} {1 - m1 / m0:6.1%} {inside:9.0%} {(hi_ - lo_).mean():10,.0f}")

# Only a horizon that earned its own model stores one; the others reuse the one-month model with a wider range.
eng["horizons"] = {k: {"model": final[k]["mid"], "low": final[k]["lo"], "high": final[k]["hi"]}
                   for k in HORIZONS if choice[k] == "own"}
eng["horizon_widen"] = widen
joblib.dump(eng, OUT)
print("\nSaved", OUT, "with settings for 2 and 3 months ahead")
