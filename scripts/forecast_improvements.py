"""Forecast for app users, part 2: what makes it more accurate? (docs/experiments.md, 4 Nov)

Builds on scripts/kihbs_forecast_experiment.py (boosted tree with the calendar month beat the median).
Tests, on the same households (choose on 48 validation households from train, score the 60 test households once):
  1. Known commitments: rent and loan repayments are entered exactly in the app, so take them as known and let the
     model forecast only the rest (school fees fee-aware, everyday spending by the tree).
  2. Tuning and extra features (recent trend, last fee-month amount).
  3. Personal bias correction: compare the model with what this household actually spent in its last months and
     adjust by half the average miss (shrunk, so one odd month does not swing it).
  4. A range: two more trees predict the 10th and 90th percentiles, so the app can say "probably 38,000 - 46,000".
Run: python scripts/forecast_improvements.py   (writes backend/models/user_forecast.joblib)
"""
import itertools
import sys
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
from sklearn.ensemble import HistGradientBoostingRegressor

ROOT = Path(__file__).resolve().parents[1] if len(sys.argv) < 2 else Path(sys.argv[1])
CATS = ["housing", "food_groceries", "transport", "utilities", "airtime_data",
        "mobile_money_transfers", "loan_repayment", "school_fees", "entertainment", "savings"]
KNOWN = ["housing"]   # rent is steady (0% month-to-month variation in the data); synthetic loans start and stop
                      # (103% variation), so treating last month's loan as known hurt on validation (11,819 vs 10,741)
FEES = "school_fees"
EVERYDAY = [c for c in CATS if c not in KNOWN + [FEES]]
HISTORY = (1, 3, 6, 11)
FEE_MONTHS = (1, 5, 9)

d = pd.read_csv(ROOT / "data/processed/engineered_features_raw.csv").sort_values(["household_id", "month"])
split = pd.read_csv(ROOT / "data/processed/household_split.csv").set_index("household_id")["split"]
d["spend"] = d[CATS].sum(axis=1)
d["everyday"] = d[EVERYDAY].sum(axis=1)


def features(past, t, g, target="spend"):
    tot = past[target]
    recent = tot.tail(3).to_numpy()
    fees_past = past.loc[past.index.isin(FEE_MONTHS), FEES]
    return {"h": len(past), "median": tot.median(), "mean": tot.mean(), "last": tot.iloc[-1],
            "min": tot.min(), "max": tot.max(), "std": tot.std() if len(tot) > 1 else 0.0,
            "trend": (recent[-1] - recent[0]) / max(len(recent) - 1, 1) if len(recent) > 1 else 0.0,
            "income": past["total_income"].iloc[-1], "income_mean": past["total_income"].mean(),
            "household_size": g["household_size"].iloc[0], "num_dependants": g["num_dependants"].iloc[0],
            "formal": int(g["income_tier"].iloc[0] == "formal_salaried"),
            "month": t, "fee_month": int(t in FEE_MONTHS), "december": int(t == 12),
            "fees_seen": fees_past.max() if len(fees_past) else 0.0, "fees_median": past[FEES].median()}


def examples(households):
    rows = []
    for hid, g in d[d.household_id.isin(households)].groupby("household_id"):
        g = g.set_index("month")
        for t in range(2, 13):
            for h in HISTORY:
                past = g.loc[max(1, t - h):t - 1]
                if len(past) < min(h, t - 1):
                    continue
                f = features(past, t, g)
                fe = features(past, t, g, "everyday")
                rows.append({"household_id": hid, "t": t, **f, **{f"e_{k}": v for k, v in fe.items()},
                             "known": past[KNOWN].iloc[-1].sum(),           # what the user entered as commitments
                             "fees_next": f["fees_seen"] if f["fee_month"] else f["fees_median"],
                             "actual": g.loc[t, "spend"], "actual_everyday": g.loc[t, "everyday"]})
    return pd.DataFrame(rows)


train_ids = split[split == "train"].index.to_numpy()
val_ids = np.random.default_rng(42).choice(train_ids, size=48, replace=False)
fit_ids = np.setdiff1d(train_ids, val_ids)
test_ids = split[split == "test"].index.to_numpy()
FIT, VAL, TEST = examples(fit_ids), examples(val_ids), examples(test_ids)
ALL = pd.concat([FIT, VAL])

BASE = ["h", "median", "mean", "last", "min", "max", "std", "income", "income_mean",
        "household_size", "num_dependants", "formal", "month", "fee_month", "december", "fees_seen", "fees_median"]
PLUS = BASE + ["trend"]
E_BASE = [f"e_{k}" for k in PLUS]


def fit(df, feats, base_col, target_col, loss="absolute_error", q=None, **kw):
    params = dict(max_iter=300, learning_rate=0.05, min_samples_leaf=40, random_state=0)
    params.update(kw)
    if loss == "quantile":
        params["quantile"] = q
    m = HistGradientBoostingRegressor(loss=loss, **params)
    m.fit(df[feats], df[target_col] / df[base_col].clip(lower=1))
    return m


def predict(m, df, feats, base_col):
    return df[base_col].clip(lower=1) * m.predict(df[feats])


def mae(df, pred):
    return float((pred - df["actual"]).abs().mean())


def by_h(df, pred):
    return " / ".join(f"{(pred[df.h == h] - df.actual[df.h == h]).abs().mean():,.0f}" for h in HISTORY)


pd.set_option("display.width", 250)
print("1. KNOWN COMMITMENTS  (validation MAE, KES)")
whole = fit(FIT, BASE, "median", "actual")
v_whole = predict(whole, VAL, BASE, "median")
every = fit(FIT, [f"e_{k}" for k in BASE], "e_median", "actual_everyday")
v_split = VAL["known"] + VAL["fees_next"] + predict(every, VAL, [f"e_{k}" for k in BASE], "e_median")
print(f"  median {mae(VAL, VAL['median']):,.0f} | tree on the whole total {mae(VAL, v_whole):,.0f} | "
      f"known commitments + fees + tree on everyday {mae(VAL, v_split):,.0f}")

print("\n2. TUNING the everyday tree (validation MAE, KES; best 5 of the grid)")
grid = []
for feats, lr, leaf, it in itertools.product((("base", [f"e_{k}" for k in BASE]), ("plus trend", E_BASE)),
                                             (0.03, 0.05, 0.1), (20, 40, 80), (200, 400)):
    m = fit(FIT, feats[1], "e_median", "actual_everyday", learning_rate=lr, min_samples_leaf=leaf, max_iter=it)
    pred = VAL["known"] + VAL["fees_next"] + predict(m, VAL, feats[1], "e_median")
    grid.append({"features": feats[0], "learning_rate": lr, "min_leaf": leaf, "iterations": it, "MAE": mae(VAL, pred)})
grid = pd.DataFrame(grid).sort_values("MAE")
print(grid.head(5).round(0).to_string(index=False))
best = grid.iloc[0]
E_FEATS = E_BASE if best["features"] == "plus trend" else [f"e_{k}" for k in BASE]
PARAMS = dict(learning_rate=float(best["learning_rate"]), min_samples_leaf=int(best["min_leaf"]),
              max_iter=int(best["iterations"]))


def bias_factor(df, model, feats, past_pairs, k=3, shrink=0.5):
    """For each row, how far the model missed on this household's own last k months (actual / predicted),
    pulled halfway to 1. past_pairs maps (household, month) -> (prediction, actual) for 1-step forecasts."""
    out = []
    for hid, t in zip(df["household_id"], df["t"]):
        ratios = [past_pairs[(hid, s)][1] / past_pairs[(hid, s)][0] for s in range(max(2, t - k), t)
                  if (hid, s) in past_pairs and past_pairs[(hid, s)][0] > 0]
        out.append(1 + shrink * (np.mean(ratios) - 1) if ratios else 1.0)
    return np.array(out)


def one_step_pairs(df, model, feats):
    """Model predictions for each household-month using all history before it (what the app would have shown)."""
    longest = df.sort_values("h").groupby(["household_id", "t"]).tail(1)
    pred = predict(model, longest, feats, "e_median")
    return {(h, t): (p, a) for h, t, p, a in zip(longest.household_id, longest.t, pred, longest.actual_everyday)}


print("\n3. PERSONAL BIAS CORRECTION (validation MAE, KES)")
every = fit(FIT, E_FEATS, "e_median", "actual_everyday", **PARAMS)
v_every = predict(every, VAL, E_FEATS, "e_median")
pairs = one_step_pairs(VAL, every, E_FEATS)
results = {}
for shrink in (0.0, 0.25, 0.5, 0.75):
    fac = bias_factor(VAL, every, E_FEATS, pairs, shrink=shrink)
    results[shrink] = mae(VAL, VAL["known"] + VAL["fees_next"] + v_every * fac)
print("  " + " | ".join(f"shrink {s}: {v:,.0f}" for s, v in results.items()))
SHRINK = min(results, key=results.get)
print(f"  chosen: {SHRINK} (0 = no correction)")

print("\n4. RANGE (10th to 90th percentile) on validation: share of months inside the range, average width")
lo = fit(FIT, E_FEATS, "e_median", "actual_everyday", loss="quantile", q=0.1, **PARAMS)
hi = fit(FIT, E_FEATS, "e_median", "actual_everyday", loss="quantile", q=0.9, **PARAMS)
fixed = VAL["known"] + VAL["fees_next"]
v_lo, v_hi = fixed + predict(lo, VAL, E_FEATS, "e_median"), fixed + predict(hi, VAL, E_FEATS, "e_median")
inside = ((VAL["actual"] >= v_lo) & (VAL["actual"] <= v_hi)).mean()
print(f"  raw trees: inside {inside:.0%} (target 80%), average width KES {(v_hi - v_lo).mean():,.0f}")
# Calibrate on validation: widen both ends around the forecast by the same factor until 80% of months fall inside.
v_mid = fixed + predict(every_fit := fit(FIT, E_FEATS, "e_median", "actual_everyday", **PARAMS), VAL, E_FEATS, "e_median")
WIDEN = 1.0
for w in np.arange(1.0, 3.01, 0.05):
    a, b = v_mid - w * (v_mid - v_lo), v_mid + w * (v_hi - v_mid)
    if ((VAL["actual"] >= a) & (VAL["actual"] <= b)).mean() >= 0.80:
        WIDEN = round(float(w), 2)
        break
a, b = v_mid - WIDEN * (v_mid - v_lo), v_mid + WIDEN * (v_hi - v_mid)
print(f"  calibrated (x{WIDEN}): inside {((VAL.actual >= a) & (VAL.actual <= b)).mean():.0%}, average width KES {(b - a).mean():,.0f}")

print("\n5. THE WINNER SO FAR (tree on the whole total) - tuned the same way, with its own range")
grid_w = []
for feats, lr, leaf, it in itertools.product((("base", BASE), ("plus trend", PLUS)), (0.03, 0.05, 0.1), (20, 40, 80), (200, 400)):
    m = fit(FIT, feats[1], "median", "actual", learning_rate=lr, min_samples_leaf=leaf, max_iter=it)
    grid_w.append({"features": feats[0], "learning_rate": lr, "min_leaf": leaf, "iterations": it,
                   "MAE": mae(VAL, predict(m, VAL, feats[1], "median"))})
grid_w = pd.DataFrame(grid_w).sort_values("MAE")
print(grid_w.head(3).round(0).to_string(index=False))
default = grid_w[(grid_w.features == "base") & (grid_w.learning_rate == 0.05) & (grid_w.min_leaf == 40) & (grid_w.iterations == 300)]
bw = grid_w.iloc[0]
# keep the simpler default unless tuning gains more than 2% on validation
DEFAULT_MAE = mae(VAL, predict(fit(FIT, BASE, "median", "actual"), VAL, BASE, "median"))
if bw["MAE"] < 0.98 * DEFAULT_MAE:
    W_FEATS = PLUS if bw["features"] == "plus trend" else BASE
    W_PARAMS = dict(learning_rate=float(bw["learning_rate"]), min_samples_leaf=int(bw["min_leaf"]), max_iter=int(bw["iterations"]))
else:
    W_FEATS, W_PARAMS = BASE, {}
print(f"  default settings {DEFAULT_MAE:,.0f}; best tuned {bw['MAE']:,.0f} -> using {'tuned' if W_PARAMS else 'default'} settings")

print("\n6. JANUARY: the data has 12 months per household, so month 1 is never a month to forecast in training.")
NOMONTH = [f for f in W_FEATS if f != "month"]
nm = mae(VAL, predict(fit(FIT, NOMONTH, "median", "actual", **W_PARAMS), VAL, NOMONTH, "median"))
print(f"  with the month number {DEFAULT_MAE:,.0f} | fee-month and December flags only {nm:,.0f}")
print("  -> flags only: a 1.6%-ish cost, but January (a fee month) is forecast from the fee-month flag instead of")
print("     an untrained month number (found by walking through the app: a family's January came out low)")
W_FEATS = NOMONTH
OWN_Z = 1.2816   # 80% half-width for a normal spread


def personal(df, mid, lo, hi, w):
    """Blend the model's half-widths with the household's own spread when it has 3+ months."""
    dl, dh, own = (mid - lo).clip(lower=0), (hi - mid).clip(lower=0), OWN_Z * df["std"]
    use = df["h"] >= 3
    dl, dh = np.where(use, 0.5 * dl + 0.5 * own, dl), np.where(use, 0.5 * dh + 0.5 * own, dh)
    return mid - w * dl, mid + w * dh


w_mid = predict(fit(FIT, W_FEATS, "median", "actual", **W_PARAMS), VAL, W_FEATS, "median")
w_lo = predict(fit(FIT, W_FEATS, "median", "actual", loss="quantile", q=0.1, **W_PARAMS), VAL, W_FEATS, "median")
w_hi = predict(fit(FIT, W_FEATS, "median", "actual", loss="quantile", q=0.9, **W_PARAMS), VAL, W_FEATS, "median")
W_WIDEN = 1.0
for w in np.arange(1.0, 3.01, 0.05):
    lo_, hi_ = personal(VAL, w_mid, w_lo, w_hi, w)
    if ((VAL.actual >= lo_) & (VAL.actual <= hi_)).mean() >= 0.80:
        W_WIDEN = round(float(w), 2)
        break
print(f"  personal range (model + own spread) widened x{W_WIDEN} on validation to hold 80% of months")

# ---------- final: refit on all train households, score the 60 test households once ----------
whole_f = fit(ALL, W_FEATS, "median", "actual", **W_PARAMS)
lo_w = fit(ALL, W_FEATS, "median", "actual", loss="quantile", q=0.1, **W_PARAMS)
hi_w = fit(ALL, W_FEATS, "median", "actual", loss="quantile", q=0.9, **W_PARAMS)
every_f = fit(ALL, E_FEATS, "e_median", "actual_everyday", **PARAMS)
t_fixed = TEST["known"] + TEST["fees_next"]
t_every = predict(every_f, TEST, E_FEATS, "e_median")
t_fac = bias_factor(TEST, every_f, E_FEATS, one_step_pairs(TEST, every_f, E_FEATS), shrink=0.5)
t_whole = predict(whole_f, TEST, W_FEATS, "median")
rows = {
    "median (app until 4 Nov)": TEST["median"],
    "tree on the whole total (flags, deployed)": t_whole,
    "rent known + fees + everyday tree": t_fixed + t_every,
    "... + bias correction (shrink 0.5)": t_fixed + t_every * t_fac,
}
print("\nTEST (60 held-out households)")
print(f"  {'method':40s} {'MAE':>8s}  {'WAPE':>6s}   MAE by history 1 / 3 / 6 / 11 months")
for name, pred in rows.items():
    wape = (pred - TEST["actual"]).abs().sum() / TEST["actual"].sum()
    print(f"  {name:40s} {mae(TEST, pred):8,.0f}  {wape:6.3f}   {by_h(TEST, pred)}")
t_lo, t_hi = personal(TEST, t_whole, predict(lo_w, TEST, W_FEATS, "median"), predict(hi_w, TEST, W_FEATS, "median"), W_WIDEN)
inside = (TEST.actual >= t_lo) & (TEST.actual <= t_hi)
cv = TEST["std"] / TEST["median"]
sub = TEST["h"] >= 3
steady, rough = sub & (cv <= cv[sub].quantile(0.25)), sub & (cv >= cv[sub].quantile(0.75))
print(f"  personal range: {inside.mean():.0%} of months inside (target 80%), average width KES {(t_hi - t_lo).mean():,.0f} "
      f"around an average forecast of KES {t_whole.mean():,.0f}")
print(f"    steadiest quarter: {inside[steady].mean():.0%} inside, width {(t_hi - t_lo)[steady].mean():,.0f} | "
      f"most variable quarter: {inside[rough].mean():.0%} inside, width {(t_hi - t_lo)[rough].mean():,.0f}")

out = ROOT / "backend/models/user_forecast.joblib"
joblib.dump({"version": 3, "model": whole_f, "low": lo_w, "high": hi_w, "widen": W_WIDEN, "features": W_FEATS,
             "fee_months": FEE_MONTHS, "own_z": OWN_Z, "personal_range_min_months": 3,
             "chosen": "tree on the whole total, fee-month and December flags; personal 80% range"}, out)
print("\nSaved", out)
