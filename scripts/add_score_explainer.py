"""SHAP explanations for the affordability score (proposal 3.5.7; docs/experiments.md, 5 Nov).

Stores a background of 200 training household-months in backend/models/affordability_engine.joblib, so the app
can explain any score as "a typical household scores X; your income adds a, your recent months take away b...".

It also checks the explainer:
1. Exactness: with every feature on its own, backend/affordability.shapley must give the same values as the shap
   library's ExactExplainer on the same background (the reference implementation).
2. Additivity: typical score + contributions = the score, for every held-out household.
3. What drives the score across held-out households (mean absolute contribution per group).

Run: python scripts/add_score_explainer.py            (needs `pip install shap` for check 1 only)
"""
import importlib.util
import sys
import time
from pathlib import Path

import joblib
import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1] if len(sys.argv) < 2 else Path(sys.argv[1])
ENGINE = ROOT / "backend/models/affordability_engine.joblib"
spec = importlib.util.spec_from_file_location("aff", ROOT / "backend/affordability.py")
aff = importlib.util.module_from_spec(spec)
spec.loader.exec_module(aff)

d = pd.read_csv(ROOT / "data/processed/engineered_features_raw.csv")
split = pd.read_csv(ROOT / "data/processed/household_split.csv").set_index("household_id")["split"]
d["split"] = d["household_id"].map(split)
e = joblib.load(ENGINE)
cols = e["score_features"]
train, test = d[d.split == "train"], d[d.split == "test"]

background = train[cols].sample(200, random_state=0).to_numpy(dtype=float)
e["score_background"] = background
aff._ENGINE["e"] = e                                   # use the in-memory engine with the background
frame = lambda a: pd.DataFrame(a, columns=cols)
score = lambda a: aff._score_rows(frame(a))

# 1. Exactness against the shap library, every feature on its own (2^14 coalitions), small background for speed.
try:
    import shap
    small = background[:40]
    rows = test[cols].sample(5, random_state=1).to_numpy(dtype=float)
    ref = shap.ExactExplainer(score, shap.maskers.Independent(small, max_samples=len(small)))(rows)
    worst = 0.0
    for i, x in enumerate(rows):
        base, phi = aff.shapley(x, small, [[j] for j in range(len(cols))], value=score)
        worst = max(worst, float(np.max(np.abs(phi - ref.values[i]))), abs(base - float(ref.base_values[i])))
    print(f"1. per-feature values vs shap {shap.__version__} ExactExplainer, 5 households: largest difference "
          f"{worst:.2e} score points")
except ImportError:
    print("1. skipped (pip install shap to compare with the reference library)")

# 2 and 3. Grouped explanations for every held-out household's last month.
last = test.sort_values("month").groupby("household_id").tail(1)
groups = [[cols.index(c) for c in feats] for _, _, feats in aff.SCORE_GROUPS]
t0 = time.time()
contrib, gaps, scores = [], [], []
for x in last[cols].to_numpy(dtype=float):
    base, phi = aff.shapley(x, background, groups, value=score)
    s = float(score(x[None, :])[0])
    gaps.append(abs(base + phi.sum() - s))
    contrib.append(phi)
    scores.append(s)
ms = (time.time() - t0) / len(last) * 1000
contrib = np.array(contrib)
print(f"2. additivity over {len(last)} held-out households: largest gap {max(gaps):.2e} points; "
      f"{ms:.0f} ms per explanation; typical score {base:.1f}")
print("3. mean absolute contribution (score points), held-out households:")
for (key, label, _), v in sorted(zip(aff.SCORE_GROUPS, np.abs(contrib).mean(axis=0)), key=lambda t: -t[1]):
    print(f"   {label:42s} {v:5.1f}")
by_state = pd.DataFrame(contrib, columns=[k for k, _, _ in aff.SCORE_GROUPS])
by_state["state"] = last.true_state.to_numpy()
by_state["score"] = scores
print(by_state.groupby("state").mean().round(1).to_string())

joblib.dump(e, ENGINE, compress=3)
print("Saved", ENGINE)
