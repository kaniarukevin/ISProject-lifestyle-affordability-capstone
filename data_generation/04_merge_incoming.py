"""
04 - Build household income + demographics from KIHBS 2015/16 (member-level file + household file).

FIXES vs the earlier version:
  * The old script joined on IDs like "916.0_7" (float clid) against "140_1" - ZERO rows matched, so wage
    income was silently filled with 0 for every household. 'total_income' was only pension/rental/investment
    income, which exists for ~5% of households. IDs are now built identically in both files.
  * has_business_income was always False (compared Stata categories to 1). Now uses the numeric code (1 = yes).
  * Adds casual labour (d24 days x d25 daily wage), house allowance (d27), second job (d43).
  * Uses member ages (b05_yy) for dependants and school-age children instead of a random 30-50% of household size.
  * Splits households into formal_salaried / informal_irregular from employer type, NSSF/NHIF, contract type.
  * Inflates 2015/16 KES to 2025 KES with KNBS CPI.

KNOWN LIMITATION (state in the report): KIHBS has no profit measure for the self-employed / farmers, so
households whose only earners are self-employed have unobserved income and are EXCLUDED from sampling.
"""
import numpy as np
import pandas as pd
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw"
PROC = ROOT / "data" / "processed"

# KNBS annual-average CPI inflation. 2021-2025 verified (FocusEconomics/KNBS, Oct 2026);
# 2017-2020 are from memory (8.0, 4.7, 5.2, 5.3) and should be re-checked before submission.
INFLATION = {2017: 8.0, 2018: 4.7, 2019: 5.2, 2020: 5.3, 2021: 6.1, 2022: 7.7, 2023: 7.7, 2024: 4.5, 2025: 4.1}
CPI_FACTOR = float(np.prod([1 + v / 100 for v in INFLATION.values()]))  # 2016 -> 2025 prices

PUBLIC_NGO_EMPLOYERS = {1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 20}   # govt, TSC, county, state corp, NGO, FBO, school boards
MISSING_CODES = 999_000                                           # d26/d43 contain 999999 / 900000 style codes

m = pd.read_stata(RAW / "HH_Members_Information.dta", convert_categoricals=False)
m["household_id"] = m["clid"].astype(int).astype(str) + "_" + m["hhid"].astype(int).astype(str)

for c in ["d26", "d27", "d43", "d24", "d25"]:
    m[c] = pd.to_numeric(m[c], errors="coerce")
for c in ["d26", "d27", "d43", "d25"]:
    m.loc[m[c] >= MISSING_CODES, c] = np.nan
m.loc[(m["d24"] < 0) | (m["d24"] > 31), "d24"] = np.nan

m["salary"] = m["d26"].fillna(0) + m["d27"].fillna(0)
m["casual"] = (m["d24"].fillna(0) * m["d25"].fillna(0)).where(m["d24"].fillna(0) > 0, 0.0)
m["second"] = m["d43"].fillna(0)

formal_flag = (
    (m["salary"] > 0)
    & (m["d17"].isin(PUBLIC_NGO_EMPLOYERS) | (m["d29_a"] == 1) | (m["d29_b"] == 1)
       | ((m["d30"] == 1) & m["d23"].isin([1, 2])))
)
m["formal_salary"] = np.where(formal_flag, m["salary"], 0.0)

age = pd.to_numeric(m["b05_yy"], errors="coerce")
m["is_dependant"] = ((age < 15) | (age >= 65)).astype(int)
attending = pd.to_numeric(m["c03"], errors="coerce") == 1
m["school_primary"] = (attending & (age >= 4) & (age <= 13)).astype(int)
m["school_secondary"] = (attending & (age >= 14) & (age <= 21)).astype(int)
m["is_business_member"] = (pd.to_numeric(m["d02_4"], errors="coerce") == 1).astype(int)

agg = m.groupby("household_id").agg(
    salary_income=("salary", "sum"), formal_salary_income=("formal_salary", "sum"),
    casual_income=("casual", "sum"), second_job_income=("second", "sum"),
    num_dependants=("is_dependant", "sum"), num_primary_children=("school_primary", "sum"),
    num_secondary_children=("school_secondary", "sum"),
    has_business_income=("is_business_member", lambda s: bool((s > 0).any())),
).reset_index()

hh = pd.read_csv(PROC / "kihbs_households_clean.csv")
df = hh.merge(agg, on="household_id", how="left")
matched = df["salary_income"].notna().mean()
assert matched > 0.99, f"ID join still broken: only {matched:.1%} of households matched member data"
for c in ["salary_income", "formal_salary_income", "casual_income", "second_job_income",
          "num_dependants", "num_primary_children", "num_secondary_children"]:
    df[c] = df[c].fillna(0)

# Monthly passive income. pension (p06) and rental (p08) are 'last 1 month'. Savings/interest (p03) is
# assumed to be a 12-month amount (label truncated in the .dta) and is converted to monthly.
df["passive_income"] = df["pension_income"].fillna(0) + df["rental_income"].fillna(0) + df["investment_income"].fillna(0) / 12
df["labour_income"] = df["salary_income"] + df["casual_income"] + df["second_job_income"]
df["total_income_2016"] = df["labour_income"] + df["passive_income"]

# Keep households with observed labour income (needed to assign a tier). Self-employed-only households drop out.
df = df[df["labour_income"] > 0].copy()

formal_share = df["formal_salary_income"] / df["labour_income"]
df["income_tier"] = np.where((df["formal_salary_income"] > 0) & (formal_share >= 0.5), "formal_salaried", "informal_irregular")

# Winsorise (guards against mis-keyed amounts), then convert to 2025 KES.
def wq(x, w, q):
    o = np.argsort(x.values); cw = np.cumsum(w.values[o]); return x.values[o][np.searchsorted(cw, q * cw[-1])]
# Cap within each tier at its weighted 99th percentile (informal households earning 480k/month are mis-keyed amounts)
for t in df["income_tier"].unique():
    mask = df["income_tier"] == t
    cap = wq(df.loc[mask, "total_income_2016"], df.loc[mask, "survey_weight"], 0.99)
    df.loc[mask, "total_income_2016"] = df.loc[mask, "total_income_2016"].clip(upper=cap)
df["monthly_income_2025"] = (df["total_income_2016"] * CPI_FACTOR).round(0)
df["housing_cost_2025"] = (df["housing_cost"].fillna(0) * CPI_FACTOR).round(0)
df["housing_loan_payment_2025"] = (df["housing_loan_payment"].fillna(0) * CPI_FACTOR).round(0)
df["area_type"] = df["area_type"].astype(str)

df.to_csv(PROC / "kihbs_households_with_income.csv", index=False)
print(f"CPI factor 2016->2025: {CPI_FACTOR:.3f}")
print("Households with observed labour income:", len(df), "of", len(hh))
print(df.groupby("area_type").size().to_dict(), df.income_tier.value_counts().to_dict())
for t, g in df.groupby("income_tier"):
    w = g["survey_weight"]
    print(t, "weighted median monthly income 2025 KES:", int(wq(g["monthly_income_2025"], w, 0.5)),
          "| p10:", int(wq(g["monthly_income_2025"], w, 0.1)), "p90:", int(wq(g["monthly_income_2025"], w, 0.9)))
