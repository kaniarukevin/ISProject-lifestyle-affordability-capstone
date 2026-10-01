"""
05 - Sample synthetic households from REAL KIHBS 2015/16 households (core-urban + peri-urban), incomes in 2025 KES.

FIXES vs the earlier version: sampling is now WITHOUT replacement (no duplicated households), covers both
income tiers from real employment data, uses real ages for dependants/school children, and keeps real
rent / housing-loan / remittance flags. Scope constants are at the top so they are easy to change.
"""
import numpy as np
import pandas as pd
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SEED = 42
N_HOUSEHOLDS = 300                         # was 150; more households help the LSTM/RF. Change freely.
AREAS = ["core_urban", "peri_urban"]            # app's target population (smartphone / M-Pesa users). Add "rural" to widen scope.

rng = np.random.default_rng(SEED)
k = pd.read_csv(ROOT / "data" / "processed" / "kihbs_households_with_income.csv")
k = k[k["area_type"].isin(AREAS)].reset_index(drop=True)
k = k[k["monthly_income_2025"] > 0]
print("KIHBS households available:", len(k), k["area_type"].value_counts().to_dict())

# Impute rent for renters who report 0 (missing) using the county x area median of renters (2025 KES).
renters = k["housing_status"].astype(str).str.lower().str.contains("rent")
med_cty = k[renters & (k["housing_cost_2025"] > 0)].groupby(["county", "area_type"])["housing_cost_2025"].median()
med_all = k[renters & (k["housing_cost_2025"] > 0)]["housing_cost_2025"].median()
def fix_rent(r):
    if not str(r.housing_status).lower().__contains__("rent") or r.housing_cost_2025 > 0:
        return r.housing_cost_2025 if str(r.housing_status).lower().__contains__("rent") else 0.0
    return med_cty.get((r.county, r.area_type), med_all)
k["rent_2025"] = k.apply(fix_rent, axis=1)

# Stratified 50/50 core-urban / peri-urban. Within each stratum,
# households are drawn WITHOUT replacement, weighted by KIHBS survey weight.
per_area = N_HOUSEHOLDS // len(AREAS)
parts = [g.sample(n=per_area if a != AREAS[-1] else N_HOUSEHOLDS - per_area * (len(AREAS) - 1),
                  replace=False, weights="survey_weight", random_state=SEED)
         for a, g in k.groupby("area_type")]
s = pd.concat(parts).sample(frac=1, random_state=SEED).reset_index(drop=True)

hh = pd.DataFrame({
    "household_id": [f"H{i+1:03d}" for i in range(N_HOUSEHOLDS)],
    "kihbs_id": s["household_id"],
    "county": s["county"],
    "urban_rural": s["area_type"],
    "monthly_income_base": s["monthly_income_2025"].astype(float),
    "household_size": s["household_size"].astype(int),
    "adult_equivalent_size": s["adult_equivalent_size"].round(2),
    "num_dependants": np.minimum(s["num_dependants"].astype(int), s["household_size"].astype(int) - 1).clip(lower=0),
    "num_primary_children": s["num_primary_children"].astype(int),
    "num_secondary_children": s["num_secondary_children"].astype(int),
    "housing_status": s["housing_status"].astype(str),
    "housing_cost_real": s["rent_2025"].round(0),
    "housing_loan_payment": s["housing_loan_payment_2025"].round(0),
    "has_business_income": s["has_business_income"].astype(bool),
    "receives_support": s["receives_support"].astype(bool),
    "gives_support": s["gives_support"].astype(bool),
    "income_tier": s["income_tier"],
})
hh["has_active_goal"] = rng.random(N_HOUSEHOLDS) < 0.4   # no KIHBS equivalent - stated assumption

print(hh.shape)
print(hh["income_tier"].value_counts().to_dict(), hh["urban_rural"].value_counts().to_dict())
print(hh.groupby("income_tier")["monthly_income_base"].describe().round(0).to_string())
print("renters:", (hh.housing_cost_real > 0).sum(), "| business members:", hh.has_business_income.sum(),
      "| housing loans:", (hh.housing_loan_payment > 0).sum(), "| counties:", hh.county.nunique())
# The link to real KIHBS household IDs is kept OUT of the shareable synthetic file (KIHBS licence / privacy).
# The link file is git-ignored by the kihbs_*.csv rule.
hh[["household_id", "kihbs_id"]].to_csv(ROOT / "data" / "processed" / "kihbs_household_link.csv", index=False)
hh.drop(columns=["kihbs_id"]).to_csv(ROOT / "data" / "synthetic" / "households.csv", index=False)
print("Saved to data/synthetic/households.csv")
