"""Sensitivity check (25 Nov): do the state-detection conclusions still hold when the generator's ASSUMPTIONS change?

For each scenario this copies data_generation/05-07 into a temporary folder, changes ONE assumption in the copy
(or several, in the last scenario), regenerates the 300-household panel, rebuilds the features and the 240/60
household split, and scores every state detector on the 60 test households:
  majority class, the threshold rule on the 3-month income/spending ratio (fitted on train), the unsupervised HMM
  of the proposal (decoded causally), the HMM initialised from the training labels, the Random Forest on the same
  5 HMM features, and the full Random Forest (300 trees, min leaf 5).
It also retrains the app's forecast tree (same settings as backend/models/user_forecast.joblib) and compares its
error with the median of past months and with last month, on the same test households.
The repo's own data, features and models are never touched.

Run: python scripts/check_sensitivity.py            (all scenarios, a few minutes)
     python scripts/check_sensitivity.py baseline   (one scenario by name)
"""
import logging, shutil, subprocess, sys, tempfile
from pathlib import Path
import numpy as np, pandas as pd
from hmmlearn import hmm
from sklearn.cluster import KMeans
from sklearn.ensemble import RandomForestClassifier

logging.getLogger("hmmlearn").setLevel(logging.ERROR)
ROOT = Path(__file__).resolve().parents[1]
S = ["Stable", "Strained", "Critical"]
IDX = {s: i for i, s in enumerate(S)}
HMM_F = ["income_to_expenditure_ratio", "savings_share", "entertainment_share", "ratio_roll3", "overspend_roll3"]

# ---- The assumptions changed, as exact text edits to the copied generator (each edit must match once) ------------
G6 = "06_generate_transactions.py"
STICKIER_LESS = (G6, '    trans = (1 - w) * np.array(p["trans"]) + w * STRESSED_TRANS\n',
                 '    trans = (1 - w) * np.array(p["trans"]) + w * STRESSED_TRANS\n'
                 '    trans = 0.6 * trans + 0.4 / 3                      # SENSITIVITY: states change more often\n')
OVERLAP = (G6, 'STATE_RATIO = {"Stable": (0.60, 0.92), "Strained": (0.85, 1.10), "Critical": (1.00, 1.40)}',
           'STATE_RATIO = {"Stable": (0.55, 1.00), "Strained": (0.80, 1.20), "Critical": (0.90, 1.50)}')
WEAKER = (G6, '    "Strained": {"entertainment": 0.6, "savings": 0.45},\n'
              '    "Critical": {"entertainment": 0.25, "savings": 0.10, "food_groceries": 1.05},',
              '    "Strained": {"entertainment": 0.8, "savings": 0.70},\n'
              '    "Critical": {"entertainment": 0.5, "savings": 0.35, "food_groceries": 1.03},')
def fees(f):
    return (G6, '    downgrade = {"private_primary"',
            f'    level = {{k_: v * {f} for k_, v in level.items()}}   # SENSITIVITY: fee levels\n'
            '    downgrade = {"private_primary"')
SCENARIOS = {
    "baseline": [],
    "same assumptions, new random draw": [(G6, "rng = np.random.default_rng(42)", "rng = np.random.default_rng(7)")],
    "different KIHBS households": [("05_generate_households.py", "SEED = 42", "SEED = 7")],
    "states change more often": [STICKIER_LESS],
    "state spending ranges overlap more": [OVERLAP],
    "weaker state signal in spending mix": [WEAKER],
    "school fees +30%": [fees(1.3)],
    "school fees -30%": [fees(0.7)],
    "income more irregular": [(G6, "rng.lognormal(mean=-0.045, sigma=0.30)", "rng.lognormal(mean=-0.125, sigma=0.50)"),
                              (G6, "primary = base * rng.normal(1.0, 0.02)", "primary = base * rng.normal(1.0, 0.08)")],
    "all three harder at once": [STICKIER_LESS, OVERLAP, WEAKER],
}


def build(edits, work):
    """Copy the generator into `work`, apply the edits, run 05 (only if edited) then 06 and 07."""
    (work / "data_generation").mkdir(parents=True)
    for d in ("data/processed", "data/synthetic"):
        (work / d).mkdir(parents=True)
    shutil.copy(ROOT / "data/processed/kihbs_households_with_income.csv", work / "data/processed")
    shutil.copy(ROOT / "data/synthetic/households.csv", work / "data/synthetic")
    for f in ("05_generate_households.py", "06_generate_transactions.py", "07_feature_engineering.py"):
        shutil.copy(ROOT / "data_generation" / f, work / "data_generation" / f)
    for f, old, new in edits:
        p = work / "data_generation" / f
        t = p.read_text()
        assert t.count(old) == 1, f"edit not found once in {f}: {old[:60]}"
        p.write_text(t.replace(old, new))
    steps = (["05_generate_households.py"] if any(f.startswith("05") for f, _, _ in edits) else []) + \
            ["06_generate_transactions.py", "07_feature_engineering.py"]
    for f in steps:
        subprocess.run([sys.executable, str(work / "data_generation" / f)], check=True, capture_output=True, cwd=work)
    raw = pd.read_csv(work / "data/processed/engineered_features_raw.csv")
    norm = pd.read_csv(work / "data/processed/engineered_features_normalized.csv")
    split = pd.read_csv(work / "data/processed/household_split.csv")
    return raw, norm, split


def rule(tr, te):
    """Two cut-offs on the 3-month income/spending ratio, chosen for the best TRAIN accuracy."""
    r, y = tr.ratio_roll3.values, tr.true_state.values
    qs = np.unique(np.quantile(r, np.linspace(0.02, 0.98, 49)))
    best = (-1, 0, 0)
    for lo in qs:
        for hi in qs[qs > lo]:
            p = np.where(r >= hi, "Stable", np.where(r < lo, "Critical", "Strained"))
            best = max(best, ((p == y).mean(), lo, hi))
    _, lo, hi = best
    r = te.ratio_roll3.values
    return np.where(r >= hi, "Stable", np.where(r < lo, "Critical", "Strained"))


def causal_decode(model, X, mapping):
    return [mapping[int(model.predict(X[:t])[-1])] for t in range(1, len(X) + 1)]


def hmm_unsupervised(ntr, nte):
    """As data_generation/08 + 09: KMeans start, EM, best of 10 seeds; states named by mean income/spending ratio."""
    X = np.vstack([g[HMM_F].values for _, g in ntr.groupby("household_id")])
    L = [len(g) for _, g in ntr.groupby("household_id")]
    best, score = None, -np.inf
    for seed in range(10):
        try:
            km = KMeans(3, n_init=10, random_state=seed).fit(X)
            m = hmm.GaussianHMM(3, covariance_type="diag", n_iter=300, tol=1e-4, init_params="st", params="stmc",
                                min_covar=1e-3, random_state=seed)
            m.means_ = km.cluster_centers_
            m.covars_ = np.array([X[km.labels_ == k].var(0) + 1e-3 for k in range(3)])
            m.fit(X, L)
            s = m.score(X, L)
            if s > score:
                best, score = m, s
        except Exception:
            pass
    mapping = {int(st): rank for rank, st in enumerate(np.argsort(-best.means_[:, 0]))}
    return np.concatenate([causal_decode(best, g[HMM_F].values, mapping) for _, g in nte.groupby("household_id")])


def hmm_semi(tr, te):
    """As scripts/check_hmm_semi.py: parameters set from the training labels, decoded causally."""
    mu, sd = tr[HMM_F].mean(), tr[HMM_F].std()
    z = lambda d: ((d[HMM_F] - mu) / sd).values
    y, Z = tr.true_state.map(IDX).values, z(tr)
    m = hmm.GaussianHMM(3, covariance_type="diag", init_params="", params="")
    m.startprob_ = np.bincount(tr[tr.month == 1].true_state.map(IDX), minlength=3) / (tr.month == 1).sum()
    T = np.ones((3, 3))
    for _, g in tr.groupby("household_id"):
        s = g.true_state.map(IDX).values
        for a, b in zip(s[:-1], s[1:]):
            T[a, b] += 1
    m.transmat_ = T / T.sum(1, keepdims=True)
    m.means_ = np.array([Z[y == k].mean(0) for k in range(3)])
    m.covars_ = np.array([Z[y == k].var(0) + 1e-3 for k in range(3)])
    ident = {0: 0, 1: 1, 2: 2}
    return np.concatenate([causal_decode(m, z(g), ident) for _, g in te.groupby("household_id")])


CATS = ["housing", "food_groceries", "transport", "utilities", "airtime_data", "mobile_money_transfers",
        "loan_repayment", "school_fees", "entertainment", "savings"]
FEE = (1, 5, 9)
F_FEAT = ["h", "median", "mean", "last", "min", "max", "std", "income", "income_mean", "household_size",
          "num_dependants", "formal", "fee_month", "december", "fees_seen", "fees_median"]


def forecast_rows(d, ids):
    """As scripts/check_forecast.py: forecast month t's total from 1, 3, 6 or 11 earlier months."""
    rows = []
    for hid, g in d[d.household_id.isin(ids)].groupby("household_id"):
        g = g.set_index("month")
        for t in range(2, 13):
            for h in (1, 3, 6, 11):
                past = g.loc[max(1, t - h):t - 1]
                if len(past) < min(h, t - 1) or len(past) == 0:
                    continue
                tot = past["spend"]; fp = past.loc[past.index.isin(FEE), "school_fees"]
                rows.append(dict(hid=hid, h=len(past), median=tot.median(), mean=tot.mean(), last=tot.iloc[-1],
                                 min=tot.min(), max=tot.max(), std=tot.std() if len(tot) > 1 else 0.0,
                                 income=past["total_income"].iloc[-1], income_mean=past["total_income"].mean(),
                                 household_size=g["household_size"].iloc[0], num_dependants=g["num_dependants"].iloc[0],
                                 formal=int(g["income_tier"].iloc[0] == "formal_salaried"), fee_month=int(t in FEE),
                                 december=int(t == 12), fees_seen=fp.max() if len(fp) else 0.0,
                                 fees_median=past["school_fees"].median(),
                                 nonfee_total=float((tot - past["school_fees"]).median()), actual=g.loc[t, "spend"]))
    return pd.DataFrame(rows)


def forecast(raw, split):
    """Retrain the app's forecast tree (settings of backend/models/user_forecast.joblib) on the train households and
    compare its MAE with the median of past months and last month on the test households."""
    from sklearn.ensemble import HistGradientBoostingRegressor
    d = raw.copy(); d["spend"] = d[CATS].sum(axis=1); d = d.sort_values(["household_id", "month"])
    s = split.set_index("household_id")["split"]
    tr, te = forecast_rows(d, s[s == "train"].index), forecast_rows(d, s[s == "test"].index)
    m = HistGradientBoostingRegressor(loss="absolute_error", max_iter=300, learning_rate=0.05, min_samples_leaf=40,
                                      random_state=0).fit(tr[F_FEAT], tr.actual / tr["median"].clip(lower=1))
    mid = te["median"].clip(lower=1) * np.clip(m.predict(te[F_FEAT]), 0, None)
    floor = (te.fee_month == 1) & (te.fees_seen > 0)
    pred = np.where(floor, np.maximum(mid, te.nonfee_total + te.fees_seen), mid)
    mae = lambda p: round(float(np.abs(np.asarray(p) - te.actual.values).mean()))
    return {"tree MAE": mae(pred), "median MAE": mae(te["median"]), "last-month MAE": mae(te["last"])}


def evaluate(raw, norm, split):
    raw = raw.merge(split, on="household_id").sort_values(["household_id", "month"]).reset_index(drop=True)
    norm = norm.merge(split, on="household_id").sort_values(["household_id", "month"]).reset_index(drop=True)
    tr, te = raw[raw.split == "train"], raw[raw.split == "test"]
    truth = te.true_state.values
    tidx = te.true_state.map(IDX).values
    feat = [c for c in raw.select_dtypes("number").columns if c != "month"]
    acc = lambda p: round(float((np.asarray(p) == truth).mean()), 3)
    rf = lambda cols: RandomForestClassifier(300, min_samples_leaf=5, random_state=0, n_jobs=-1) \
        .fit(tr[cols], tr.true_state).predict(te[cols])
    seq = raw.groupby("household_id").true_state.apply(lambda s: (s.values[1:] == s.values[:-1]).mean())
    return {
        "Stable/Strained/Critical %": "/".join(str(round(100 * (raw.true_state == s).mean())) for s in S),
        "state kept next month": round(float(seq.mean()), 2),
        "majority": round(float(pd.Series(truth).value_counts(normalize=True).max()), 3),
        "rule": acc(rule(tr, te)),
        "HMM (proposal)": round(float((hmm_unsupervised(norm[norm.split == "train"], norm[norm.split == "test"]) == tidx).mean()), 3),
        "HMM from labels": round(float((hmm_semi(tr, te) == tidx).mean()), 3),
        "RF, 5 features": acc(rf(HMM_F)),
        "RF (deployed)": acc(rf(feat)),
        **forecast(raw, split),
    }


if __name__ == "__main__":
    names = sys.argv[1:] or list(SCENARIOS)
    rows = []
    for name in names:
        with tempfile.TemporaryDirectory() as d:
            res = {"scenario": name, **evaluate(*build(SCENARIOS[name], Path(d)))}
        rows.append(res)
        print(res, flush=True)
    out = pd.DataFrame(rows).set_index("scenario")
    print("\nHeld-out results, 60 test households (state: exact accuracy over 720 months; forecast: MAE in KES):\n")
    print(out.to_string())
    other = out[["rule", "HMM (proposal)", "HMM from labels"]].max(axis=1)
    best_rf = out[["RF, 5 features", "RF (deployed)"]].max(axis=1)
    print("\nA Random Forest beats the rule and both HMMs in", int((best_rf > other).sum()), "of", len(out),
          f"scenarios (smallest margin {(best_rf - other).min():.3f}, largest {(best_rf - other).max():.3f}).")
    print("RF (deployed) beats the rule and both HMMs in", int((out["RF (deployed)"] > other).sum()), "of", len(out),
          "scenarios.")
    print("Forecast tree beats the median of past months in", int((out["tree MAE"] < out["median MAE"]).sum()),
          "of", len(out), "scenarios.")
