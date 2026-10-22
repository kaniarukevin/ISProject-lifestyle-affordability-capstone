"""Train the boosted tree that splits the forecast total across categories (forecast ensemble).

Reads data/staging/budget_categories.csv, trains on every month that has 3 earlier months,
and saves backend/models/forecast_tree.joblib. Features match notebooks/04_model_comparison.ipynb:
this month's budget, the last three months' spending, trailing median and mean, last month's budget, category.
Run: python scripts/train_forecast_tree.py
"""
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
from sklearn.ensemble import HistGradientBoostingRegressor

ROOT = Path(__file__).resolve().parents[1]
bc = pd.read_csv(ROOT / "data" / "staging" / "budget_categories.csv")
bc["t"] = bc["year"] * 12 + bc["month"]
periods = sorted(bc["t"].unique())
hh = sorted(bc["user_profile_id"].unique())
cats = sorted(bc["category"].unique())
idx = pd.MultiIndex.from_product([hh, periods], names=["user_profile_id", "t"])


def cube(col):
    w = bc.pivot_table(index=["user_profile_id", "t"], columns="category", values=col, aggfunc="sum")
    return w.reindex(index=idx, columns=cats).fillna(0).to_numpy().reshape(len(hh), len(periods), len(cats))


A, B = cube("actual_kes"), cube("allocated_kes")
H, T, C = A.shape
cat_id = np.broadcast_to(np.arange(C), (H, C))


def features(t):
    hist = A[:, max(0, t - 12):t, :]
    cols = [B[:, t, :], A[:, t - 1, :], A[:, t - 2, :], A[:, t - 3, :],
            np.median(hist, axis=1), hist.mean(axis=1), B[:, t - 1, :], cat_id]
    return np.stack([c.reshape(-1) for c in cols], axis=1)


X = np.vstack([features(s) for s in range(3, T)])
y = np.concatenate([A[:, s, :].reshape(-1) for s in range(3, T)])
model = HistGradientBoostingRegressor(loss="absolute_error", max_iter=300, learning_rate=0.05,
                                      categorical_features=[7], random_state=0).fit(X, y)

out = ROOT / "backend" / "models" / "forecast_tree.joblib"
joblib.dump({"model": model, "categories": cats,
             "features": ["budget_this_month", "spend_t-1", "spend_t-2", "spend_t-3",
                          "median_12m", "mean_12m", "budget_last_month", "category_index"],
             "trained_rows": int(len(y))}, out, compress=3)
print(f"trained on {len(y):,} household-category-months; saved {out.relative_to(ROOT)} "
      f"({out.stat().st_size // 1024} KB)")
