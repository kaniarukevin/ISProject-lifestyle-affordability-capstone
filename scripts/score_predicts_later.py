"""Does today's score say anything about the months AHEAD? (10 Nov)

Tosha is defended as forward-looking, but the score model was trained to recognise a month's CURRENT state. This
checks, on the 60 held-out (test) households of the KIHBS-informed synthetic set, whether the score at month t
predicts the household's true state 1, 2 and 3 months later, using only months up to t (the same one-pass timeline
the app uses, so no month after t is ever seen).

Measures, for each horizon h = 1, 2, 3:
  - AUC for "Critical at t+h" from the score at t (0.5 = no better than chance, 1.0 = perfect ranking).
  - AUC for "Stable at t+h" from the score at t.
  - Accuracy of the score's band at t (Affordable -> Stable, Stretch -> Strained, Not affordable -> Critical) as a
    guess of the state at t+h, against two baselines:
      * "same as the model says now": the deployed state model's answer for month t, carried forward;
      * "most common state": always guess the most common state in the training months.
Rule fixed before running: the forward-looking claim holds for horizon h if the score's AUC for Critical at t+h is
at least 0.70 AND its band accuracy is at least that of the most-common-state guess. Report it either way.

Limitation: states come from the synthetic generator's rules, so this shows the score anticipates the generator's
later states, not real households'. Real months are checked in the app (forecast checks) and by volunteers.

Run from the repo root:  python scripts/score_predicts_later.py
"""
import importlib.util
import sys
from pathlib import Path

import pandas as pd
from sklearn.metrics import roc_auc_score

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
spec = importlib.util.spec_from_file_location("aff", ROOT / "backend/affordability.py")
aff = importlib.util.module_from_spec(spec)
spec.loader.exec_module(aff)

d = pd.read_csv(ROOT / "data/processed/engineered_features_raw.csv")
split = pd.read_csv(ROOT / "data/processed/household_split.csv").set_index("household_id")["split"]
d["split"] = d["household_id"].map(split)
train, test = d[d.split == "train"], d[d.split == "test"]
cut = aff.engine()["cutoffs"]
majority = train.true_state.value_counts().idxmax()


def band(score):
    return "Stable" if score >= cut["affordable"] else ("Strained" if score >= cut["stretch"] else "Critical")


rows = []
for hid, g in test.groupby("household_id"):
    g = g.sort_values("month")
    months = g[aff.CATS + aff.INCOME].to_dict("records")
    tl = aff.timeline(months, int(g.household_size.iloc[0]), int(g.num_dependants.iloc[0]))
    states = list(g.true_state)
    for t in range(len(g)):
        for h in (1, 2, 3):
            if t + h < len(g):
                rows.append({"household": hid, "t": t + 1, "h": h, "score": tl[t]["score"],
                             "model_now": tl[t]["state"], "later": states[t + h]})
r = pd.DataFrame(rows)

print(f"Held-out households: {r.household.nunique()}   most common state in training months: {majority}")
print(f"Score bands: Affordable >= {cut['affordable']}, Stretch >= {cut['stretch']}\n")
print(f"{'months ahead':>12} {'pairs':>6} {'AUC Critical':>13} {'AUC Stable':>11} {'band acc':>9} "
      f"{'same-as-now':>12} {'most-common':>12}  claim holds?")
for h, x in r.groupby("h"):
    auc_crit = roc_auc_score(x.later == "Critical", -x.score)
    auc_stab = roc_auc_score(x.later == "Stable", x.score)
    acc_band = float((x.score.map(band) == x.later).mean())
    acc_now = float((x.model_now == x.later).mean())
    acc_major = float((x.later == majority).mean())
    holds = auc_crit >= 0.70 and acc_band >= acc_major
    print(f"{h:>12} {len(x):>6} {auc_crit:>13.3f} {auc_stab:>11.3f} {acc_band:>9.3f} {acc_now:>12.3f} "
          f"{acc_major:>12.3f}  {'yes' if holds else 'no'}")

# Mean score at t by the state the household was in 3 months later: a simple picture for Chapter 5.
three = r[r.h == 3]
print("\nAverage score at month t, by the true state 3 months later:")
for s in ("Stable", "Strained", "Critical"):
    sel = three[three.later == s]
    if len(sel):
        print(f"  {s:9s} {sel.score.mean():5.1f}  (n = {len(sel)})")
