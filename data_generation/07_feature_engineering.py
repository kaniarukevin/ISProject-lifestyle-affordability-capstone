import pandas as pd
import numpy as np
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT / "data" / "synthetic"
OUT_DIR = ROOT / "data" / "processed"

EXPENDITURE_CATS = [
    "housing", "food_groceries", "transport", "utilities", "airtime_data",
    "mobile_money_transfers", "loan_repayment", "school_fees", "entertainment", "savings",
]

tx = pd.read_csv(DATA_DIR / "transactions.csv")
hh = pd.read_csv(DATA_DIR / "households.csv")
debt = pd.read_csv(DATA_DIR / "debt.csv")

pivot = tx.pivot_table(index=["household_id", "month"], columns="category",
                        values="amount", aggfunc="sum", fill_value=0.0).reset_index()

for c in EXPENDITURE_CATS + ["income_primary", "income_secondary", "informal_cash_income"]:
    if c not in pivot.columns:
        pivot[c] = 0.0

pivot["total_expenditure"] = pivot[EXPENDITURE_CATS].sum(axis=1)
pivot["total_income"] = pivot["income_primary"] + pivot["income_secondary"] + pivot["informal_cash_income"]

# income / expenditure: bounded below by 0, so zero-income months need no sentinel value.
# (Previously this was expenditure/income with a 5.0 sentinel, which was mislabelled and
# let 60 zero-income months dominate the feature's variance.)
pivot["income_to_expenditure_ratio"] = (pivot["total_income"] / pivot["total_expenditure"].replace(0, np.nan)).fillna(0.0).clip(0.0, 3.0)
pivot["zero_income_flag"] = (pivot["total_income"] == 0).astype(float)

for c in EXPENDITURE_CATS:
    pivot[f"{c}_share"] = pivot[c] / pivot["total_expenditure"].replace(0, np.nan)
share_cols = [f"{c}_share" for c in EXPENDITURE_CATS]
pivot[share_cols] = pivot[share_cols].fillna(0.0)

pivot["savings_rate"] = (pivot["savings"] / pivot["total_income"].replace(0, np.nan)).fillna(0.0)

# Debt service uses each MONTH's actual repayments (loans end after their remaining_months, so a household-level
# constant would be wrong). Zero-income months have no defined ratio -> 0 (zero_income_flag marks them).
pivot["monthly_debt_repayment"] = pivot["loan_repayment"]
pivot["debt_service_coverage_ratio"] = (pivot["monthly_debt_repayment"] / pivot["total_income"].replace(0, np.nan)).fillna(0.0).clip(upper=3.0)

pivot = pivot.sort_values(["household_id", "month"])
# Trailing (past-only) context features: a single bad income month should not look like a change of financial state.
pivot["overspend_flag"] = (pivot["total_expenditure"] > pivot["total_income"]).astype(float)
pivot["ratio_roll3"] = pivot.groupby("household_id")["income_to_expenditure_ratio"].transform(lambda s: s.rolling(3, min_periods=1).mean())
pivot["overspend_roll3"] = pivot.groupby("household_id")["overspend_flag"].transform(lambda s: s.rolling(3, min_periods=1).mean())
pivot["exp_roll3"] = pivot.groupby("household_id")["total_expenditure"].transform(lambda s: s.rolling(3, min_periods=1).mean())
pivot["exp_roll6"] = pivot.groupby("household_id")["total_expenditure"].transform(lambda s: s.rolling(6, min_periods=1).mean())

def regularity(s):
    cummean = s.expanding().mean()
    cumstd = s.expanding().std().fillna(0)
    cv = (cumstd / cummean.replace(0, np.nan)).fillna(0)
    return 1 / (1 + cv)
pivot["spending_regularity_score"] = pivot.groupby("household_id")["total_expenditure"].transform(regularity)

pivot = pivot.merge(hh[["household_id", "household_size", "num_dependants", "income_tier"]], on="household_id", how="left")
pivot["dependant_cost_factor"] = pivot["num_dependants"] / pivot["household_size"].replace(0, np.nan)

states = pd.read_csv(DATA_DIR / "true_states.csv")
pivot = pivot.merge(states, on=["household_id", "month"], how="left")

# Household-level train/test split (80/20, seed 0), defined ONCE here and reused by every model.
hh_ids = np.array(sorted(pivot.household_id.unique()))
perm = np.random.default_rng(0).permutation(len(hh_ids))
hh_ids = hh_ids[perm]
n_train = int(len(hh_ids) * 0.8)
split = pd.DataFrame({"household_id": hh_ids, "split": ["train"] * n_train + ["test"] * (len(hh_ids) - n_train)})
split.sort_values("household_id").to_csv(OUT_DIR / "household_split.csv", index=False)
train_mask = pivot.household_id.isin(hh_ids[:n_train])

# Normalise using TRAIN households only, so no test-set statistics leak into training.
exclude = {"household_id", "month", "income_tier", "true_state"}
num_cols = [c for c in pivot.columns if c not in exclude]
norm = pivot.copy()
for c in num_cols:
    mu, sd = pivot.loc[train_mask, c].mean(), pivot.loc[train_mask, c].std()
    norm[c] = (pivot[c] - mu) / sd if sd > 1e-9 else 0.0

assert not pivot.isna().any().any() and np.isfinite(pivot[num_cols].values).all(), "NaN/inf in features"
assert len(pivot) == pivot.household_id.nunique() * 12, "expected 12 months per household"

pivot.to_csv(OUT_DIR / "engineered_features_raw.csv", index=False)
norm.to_csv(OUT_DIR / "engineered_features_normalized.csv", index=False)

print("Raw features shape:", pivot.shape)
print(pivot.columns.tolist())
print(pivot.head(3).to_string())