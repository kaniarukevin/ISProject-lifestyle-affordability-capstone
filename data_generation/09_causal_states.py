"""
09 - Causal HMM states for forecasting.

08 labels each month with a state decoded from the WHOLE 12-month sequence, so the state for month 5 depends on months 6-12.
A forecaster must not see the future, so here the state for month t is decoded from months 1..t only (prefix decoding).
Writes data/processed/features_with_causal_states.csv (git-ignored, regenerable) and reports how much the two differ.
"""
import numpy as np
import pandas as pd
import joblib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROC = ROOT / "data" / "processed"
STATES = ["Stable", "Strained", "Critical"]

art = joblib.load(ROOT / "models" / "hmm_model.joblib")
model, FEATURES, mapping = art["model"], art["features"], art["state_mapping"]

df = pd.read_csv(PROC / "engineered_features_normalized.csv").sort_values(["household_id", "month"]).reset_index(drop=True)
raw = pd.read_csv(PROC / "engineered_features_raw.csv").sort_values(["household_id", "month"]).reset_index(drop=True)
df["true_state"] = raw["true_state"]
split = pd.read_csv(PROC / "household_split.csv")
df = df.merge(split, on="household_id", how="left")

full_idx, causal_idx = [], []
for hid, g in df.groupby("household_id", sort=False):
    X = g[FEATURES].values
    full_idx.extend(mapping[int(s)] for s in model.predict(X))                           # uses all 12 months
    causal_idx.extend(mapping[int(model.predict(X[:t])[-1])] for t in range(1, len(g) + 1))  # months 1..t only

df["hmm_state_full"] = [STATES[i] for i in full_idx]
df["hmm_state_causal"] = [STATES[i] for i in causal_idx]
df.to_csv(PROC / "features_with_causal_states.csv", index=False)

test = df[df.split == "test"]
print("Rows:", len(df), "| households:", df.household_id.nunique())
print(f"Agreement causal vs full-sequence (all months): {(df.hmm_state_full == df.hmm_state_causal).mean():.3f}")
print("Agreement by month:", df.groupby("month").apply(lambda g: round((g.hmm_state_full == g.hmm_state_causal).mean(), 2)).to_dict())
print(f"Held-out accuracy vs generator labels - full-sequence: {(test.hmm_state_full == test.true_state).mean():.3f}"
      f" | causal: {(test.hmm_state_causal == test.true_state).mean():.3f}")
print("Causal state mix:", df.hmm_state_causal.value_counts(normalize=True).round(2).to_dict())
