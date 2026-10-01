from pathlib import Path

import numpy as np
import pandas as pd


# ============================================================
# 01_clean_kihbs.py
# ============================================================
# Purpose:
#   Clean and transform the KIHBS 2015/16 HH_Information.dta
#   household-level dataset into a smaller modelling dataset.
#
# Important:
#   KIHBS is NOT a transaction dataset.
#   This cleaned dataset will be used to understand Kenyan
#   household characteristics and expenditure-related patterns,
#   which will later inform synthetic financial data generation.
#
# Source:
#   Kenya Integrated Household Budget Survey (KIHBS) 2015/16
#   File: HH_Information.dta
# ============================================================


# ============================================================
# 1. PROJECT PATHS
# ============================================================

BASE_DIR = Path(__file__).resolve().parents[1]

RAW_FILE = BASE_DIR / "data" / "raw" / "HH_Information.dta"
OUTPUT_DIR = BASE_DIR / "data" / "processed"

OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

OUTPUT_FILE = OUTPUT_DIR / "kihbs_households_clean.csv"


# ============================================================
# 2. LOAD DATA
# ============================================================

print("=" * 70)
print("KIHBS HOUSEHOLD DATA CLEANING")
print("=" * 70)

print("\nLoading dataset...")

if not RAW_FILE.exists():
    raise FileNotFoundError(
        f"\nCould not find:\n{RAW_FILE}\n\n"
        "Make sure HH_Information.dta is inside:\n"
        "data/raw/"
    )

df = pd.read_stata(
    RAW_FILE,
    convert_categoricals=False
)

print(f"Dataset loaded successfully.")
print(f"Rows:    {len(df):,}")
print(f"Columns: {len(df.columns):,}")


# ============================================================
# 3. BASIC DATASET INFORMATION
# ============================================================

print("\n" + "=" * 70)
print("BASIC DATASET INFORMATION")
print("=" * 70)

print("\nOriginal shape:")
print(df.shape)

print("\nDuplicate household IDs (clid + hhid):")
print(
    (df["clid"].astype(str) + "_" + df["hhid"].astype(str))
    .duplicated()
    .sum()
)

print("\nMissing values in selected variables:")

check_columns = [
    "county",
    "resid",
    "eatype",
    "hhid",
    "hhsize",
    "ctry_adq",
    "i02",
    "i04",
    "i05",
    "i08",
    "i10",
    "j20",
    "o01",
    "o14",
    "p01",
    "p02",
    "p03",
    "p04",
    "p06",
    "p07",
    "p09",
    "p10_1",
    "p10_2",
    "p11",
    "p13",
    "qa1",
    "qa2",
    "qa3",
    "qa4",
    "qa5",
    "qa6",
    "qa7",
    "qa8",
    "qa9",
    "s04",
    "s08",
    "s09",
    "weight",
]

missing = df[check_columns].isna().sum()

print(
    missing[
        missing > 0
    ].sort_values(ascending=False).to_string()
)


# ============================================================
# 4. HELPER FUNCTIONS
# ============================================================

def clean_money(series):
    """
    Convert a variable to numeric monetary values.

    Negative values are replaced with zero because the variables
    being processed represent income, rent, payments or costs.
    """
    result = pd.to_numeric(series, errors="coerce")

    result = result.replace(
        [np.inf, -np.inf],
        np.nan
    )

    result = result.clip(lower=0)

    return result


def yes_no(series):
    """
    Convert KIHBS binary coding into:

        1 = Yes
        0 = No

    KIHBS variables in this file generally use:

        1 = Yes
        2 = No

    Missing responses become 0 for modelling purposes.

    IMPORTANT:
    This transformation is only appropriate for variables where
    the source coding is actually Yes/No.
    """

    result = series.map({
        1: 1,
        2: 0
    })

    return result.fillna(0).astype(int)


# ============================================================
# 5. CREATE CLEAN HOUSEHOLD DATAFRAME
# ============================================================

clean = pd.DataFrame()


# ============================================================
# 6. HOUSEHOLD IDENTIFICATION
# ============================================================
#
# IMPORTANT:
#
# "hhid" alone is NOT a unique household identifier in this file.
# It is a small sequential counter (1-10) that resets within each
# enumeration area / cluster ("clid").
#
# The true unique household key is the combination of "clid" and
# "hhid" together. This was verified: clid + hhid produces exactly
# as many unique combinations as there are rows in the dataset.
# ============================================================

clean["household_id"] = (
    df["clid"].astype(str)
    + "_"
    + df["hhid"].astype(str)
)


# ============================================================
# 7. GEOGRAPHIC VARIABLES
# ============================================================

clean["county"] = pd.to_numeric(
    df["county"],
    errors="coerce"
).astype("Int64")


# resid:
#   1 = Rural
#   2 = Urban

clean["residence_type"] = (
    df["resid"]
    .map({
        1: "rural",
        2: "urban"
    })
    .fillna("unknown")
)


# eatype:
#   1 = Rural
#   2 = Core urban      (CORRECTED 2026-10-01: code 2 holds ALL Nairobi/Mombasa households and ~85% renters)
#   3 = Peri-urban      (previously mislabelled the other way round)

clean["area_type"] = (
    df["eatype"]
    .map({
        1: "rural",
        2: "core_urban",
        3: "peri_urban"
    })
    .fillna("unknown")
)


# ============================================================
# 8. HOUSEHOLD SIZE
# ============================================================

clean["household_size"] = pd.to_numeric(
    df["hhsize"],
    errors="coerce"
)

clean["household_size"] = (
    clean["household_size"]
    .clip(lower=1)
)


# Adult-equivalent household size

clean["adult_equivalent_size"] = pd.to_numeric(
    df["ctry_adq"],
    errors="coerce"
)

clean["adult_equivalent_size"] = (
    clean["adult_equivalent_size"]
    .clip(lower=0.5)
)


# Fill missing values using the median

clean["household_size"] = (
    clean["household_size"]
    .fillna(clean["household_size"].median())
    .round()
    .astype(int)
)

clean["adult_equivalent_size"] = (
    clean["adult_equivalent_size"]
    .fillna(clean["adult_equivalent_size"].median())
)


# ============================================================
# 9. HOUSING
# ============================================================

# i02:
#   1 = Own
#   2 = Rent / Lease
#   3 = Other
#   4 = Other

clean["housing_status"] = (
    df["i02"]
    .map({
        1: "own",
        2: "rent",
        3: "other",
        4: "other"
    })
    .fillna("unknown")
)


# i04:
# Housing loan currently being serviced

clean["housing_loan"] = yes_no(
    df["i04"]
)


# i05:
# Monthly housing loan servicing/payment

clean["housing_loan_payment"] = (
    clean_money(df["i05"])
    .fillna(0)
)


# i08:
# Estimated monthly rent

clean["estimated_rent"] = (
    clean_money(df["i08"])
    .fillna(0)
)


# i10:
# Actual monthly rent

clean["monthly_rent"] = (
    clean_money(df["i10"])
    .fillna(0)
)


# ============================================================
# 10. DETERMINE HOUSING COST
# ============================================================
#
# For households that rent:
#
#   Use reported monthly rent where available.
#
#   If reported rent is unavailable, use estimated rent.
#
# For households that own their homes:
#
#   Housing cost is initially set to zero here.
#
# This does NOT mean homeowners have zero housing-related costs.
# It simply means rent is not being treated as a monthly housing
# payment in this particular feature.
# ============================================================

clean["housing_cost"] = np.where(
    (
        (clean["housing_status"] == "rent")
        & (clean["monthly_rent"] > 0)
    ),
    clean["monthly_rent"],
    np.where(
        (
            (clean["housing_status"] == "rent")
            & (clean["estimated_rent"] > 0)
        ),
        clean["estimated_rent"],
        0
    )
)

clean["housing_cost"] = (
    pd.to_numeric(
        clean["housing_cost"],
        errors="coerce"
    )
    .fillna(0)
)


# ============================================================
# 11. ELECTRICITY
# ============================================================

# j20:
# Electricity availability

clean["has_electricity"] = yes_no(
    df["j20"]
)


# ============================================================
# 12. INTERNET
# ============================================================

# s09:
# Internet connection

clean["internet"] = yes_no(
    df["s09"]
)


# ============================================================
# 13. PAY TV
# ============================================================

# s04:
# Pay TV subscription

clean["pay_tv"] = yes_no(
    df["s04"]
)


# s08:
# Monthly Pay TV expenditure

clean["pay_tv_cost"] = (
    clean_money(df["s08"])
    .fillna(0)
)


# ============================================================
# 14. TRANSFERS / SUPPORT
# ============================================================

# o01:
# Household receives support/gifts

clean["receives_support"] = yes_no(
    df["o01"]
)


# o14:
# Household gives support/gifts

clean["gives_support"] = yes_no(
    df["o14"]
)


# ============================================================
# 15. OTHER INCOME SOURCES
# ============================================================

# IMPORTANT:
#
# These variables are conditional.
#
# Example:
#
# p02 = Does household receive savings/investment income?
# p03 = Amount received
#
# Therefore a missing p03 does NOT automatically mean bad data.
# It can mean that the household did not have this income source.
#
# We convert the monetary fields to zero when unavailable.
# ============================================================


# ------------------------------------------------------------
# Investment / savings income
# ------------------------------------------------------------

clean["investment_income"] = (
    clean_money(df["p03"])
    .fillna(0)
)


# ------------------------------------------------------------
# Pension income
# ------------------------------------------------------------

clean["pension_income"] = (
    clean_money(df["p06"])
    .fillna(0)
)


# ------------------------------------------------------------
# Rental income
# ------------------------------------------------------------
#
# KIHBS contains rental income by different property types.
#
# We aggregate the available monetary fields:
#
# p08_re
# p08_co
# p08_la
# p08_ma
# p08_su
# p08_ot
# ------------------------------------------------------------

rental_income_columns = [
    "p08_re",
    "p08_co",
    "p08_la",
    "p08_ma",
    "p08_su",
    "p08_ot"
]

clean["rental_income"] = 0.0

for column in rental_income_columns:

    clean[column] = clean_money(
        df[column]
    ).fillna(0)

    clean["rental_income"] += clean[column]


# ------------------------------------------------------------
# Other regular income
# ------------------------------------------------------------

clean["other_regular_income"] = (
    clean_money(df["p10_1"]).fillna(0)
    + clean_money(df["p10_2"]).fillna(0)
)


# ------------------------------------------------------------
# Non-regular income
# ------------------------------------------------------------

clean["non_regular_income"] = (
    clean_money(df["p13"])
    .fillna(0)
)


# ============================================================
# 16. TOTAL ADDITIONAL INCOME
# ============================================================

clean["additional_income"] = (
    clean["investment_income"]
    + clean["pension_income"]
    + clean["rental_income"]
    + clean["other_regular_income"]
)


# ============================================================
# 17. FOOD INSECURITY
# ============================================================
#
# qa1 - qa9 are food-security questions.
#
# For this modelling dataset we convert:
#
#   1 = Yes / affirmative
#   2 = No
#
# into:
#
#   1 = affirmative
#   0 = negative
#
# Then calculate a simple count of affirmative responses.
#
# Higher score = more affirmative food-insecurity responses.
#
# This is a derived modelling feature, not an official KIHBS
# "financial stress score".
# ============================================================

food_security_columns = [
    "qa1",
    "qa2",
    "qa3",
    "qa4",
    "qa5",
    "qa6",
    "qa7",
    "qa8",
    "qa9"
]

food_security_binary = pd.DataFrame(index=df.index)

for column in food_security_columns:

    food_security_binary[column] = yes_no(
        df[column]
    )

clean["food_insecurity_score"] = (
    food_security_binary
    .sum(axis=1)
    .astype(int)
)


# ============================================================
# 18. SURVEY WEIGHT
# ============================================================
#
# Retain the KIHBS survey weight.
#
# This is useful when calculating population-representative
# descriptive statistics.
#
# We will NOT use the weight as an ordinary ML feature.
# ============================================================

clean["survey_weight"] = pd.to_numeric(
    df["weight"],
    errors="coerce"
)


# ============================================================
# 19. BASIC DATA QUALITY CLEANING
# ============================================================

# Remove duplicate household IDs if they exist.
before = len(clean)

clean = clean.drop_duplicates(
    subset="household_id",
    keep="first"
)

after = len(clean)

if before != after:
    print(
        f"\nRemoved {before - after:,} duplicate household records."
    )


# Ensure monetary variables are non-negative.

money_columns = [
    "housing_loan_payment",
    "estimated_rent",
    "monthly_rent",
    "housing_cost",
    "pay_tv_cost",
    "investment_income",
    "pension_income",
    "rental_income",
    "other_regular_income",
    "non_regular_income",
    "additional_income"
]

for column in money_columns:

    clean[column] = (
        pd.to_numeric(
            clean[column],
            errors="coerce"
        )
        .fillna(0)
        .clip(lower=0)
    )


# ============================================================
# 20. DERIVED HOUSEHOLD FEATURES
# ============================================================

# Household size category

def household_size_group(size):

    if size <= 2:
        return "small"

    if size <= 5:
        return "medium"

    if size <= 8:
        return "large"

    return "very_large"


clean["household_size_group"] = (
    clean["household_size"]
    .apply(household_size_group)
)


# Housing burden cannot be calculated from KIHBS income here
# because this file is not our complete income/expenditure
# dataset. Therefore we deliberately DO NOT manufacture it here.
#
# That feature will be calculated later after synthetic monthly
# income has been generated.


# ============================================================
# 21. SELECT FINAL VARIABLES
# ============================================================

final_columns = [

    # Identification
    "household_id",

    # Geography
    "county",
    "residence_type",
    "area_type",

    # Household
    "household_size",
    "adult_equivalent_size",
    "household_size_group",

    # Housing
    "housing_status",
    "housing_loan",
    "housing_loan_payment",
    "estimated_rent",
    "monthly_rent",
    "housing_cost",

    # Utilities / lifestyle
    "has_electricity",
    "internet",
    "pay_tv",
    "pay_tv_cost",

    # Transfers
    "receives_support",
    "gives_support",

    # Additional income
    "investment_income",
    "pension_income",
    "rental_income",
    "other_regular_income",
    "non_regular_income",
    "additional_income",

    # Food insecurity
    "food_insecurity_score",

    # Survey
    "survey_weight",
]

clean = clean[final_columns]


# ============================================================
# 22. FINAL VALIDATION
# ============================================================

print("\n" + "=" * 70)
print("FINAL DATASET")
print("=" * 70)

print("\nShape:")
print(clean.shape)

print("\nData types:")
print(clean.dtypes)

print("\nMissing values:")
print(
    clean.isna()
    .sum()
    .sort_values(ascending=False)
    .head(20)
)


# ============================================================
# 23. DESCRIPTIVE STATISTICS
# ============================================================

print("\n" + "=" * 70)
print("DESCRIPTIVE STATISTICS")
print("=" * 70)

numeric_summary_columns = [
    "household_size",
    "adult_equivalent_size",
    "housing_cost",
    "housing_loan_payment",
    "pay_tv_cost",
    "investment_income",
    "pension_income",
    "rental_income",
    "other_regular_income",
    "non_regular_income",
    "additional_income",
    "food_insecurity_score",
]

print(
    clean[numeric_summary_columns]
    .describe()
    .round(2)
)


# ============================================================
# 24. KEY DISTRIBUTIONS
# ============================================================

print("\n" + "=" * 70)
print("KEY DISTRIBUTIONS")
print("=" * 70)


print("\nResidence type:")
print(
    clean["residence_type"]
    .value_counts(normalize=True)
    .mul(100)
    .round(2)
)


print("\nArea type:")
print(
    clean["area_type"]
    .value_counts(normalize=True)
    .mul(100)
    .round(2)
)


print("\nHousing status:")
print(
    clean["housing_status"]
    .value_counts(normalize=True)
    .mul(100)
    .round(2)
)


print("\nInternet:")
print(
    clean["internet"]
    .value_counts(normalize=True)
    .mul(100)
    .round(2)
)


print("\nPay TV:")
print(
    clean["pay_tv"]
    .value_counts(normalize=True)
    .mul(100)
    .round(2)
)


print("\nReceives support:")
print(
    clean["receives_support"]
    .value_counts(normalize=True)
    .mul(100)
    .round(2)
)


print("\nGives support:")
print(
    clean["gives_support"]
    .value_counts(normalize=True)
    .mul(100)
    .round(2)
)


print("\nFood insecurity score:")
print(
    clean["food_insecurity_score"]
    .value_counts()
    .sort_index()
)


# ============================================================
# 25. SAVE CLEAN DATASET
# ============================================================

clean.to_csv(
    OUTPUT_FILE,
    index=False
)


# ============================================================
# 26. SAVE A SMALL DATA DICTIONARY
# ============================================================

data_dictionary = {

    "household_id": "Unique KIHBS household identifier",
    "county": "KIHBS county code",
    "residence_type": "Rural or urban residence classification",
    "area_type": "Rural, peri-urban or urban classification",
    "household_size": "Number of household members",
    "adult_equivalent_size": "Adult-equivalent household size",
    "household_size_group": "Derived household-size category",
    "housing_status": "House ownership/rental status",
    "housing_loan": "Whether a housing loan is being serviced",
    "housing_loan_payment": "Monthly housing-loan payment",
    "estimated_rent": "Estimated monthly rent",
    "monthly_rent": "Reported monthly rent",
    "housing_cost": "Modelling housing cost derived from rent variables",
    "has_electricity": "Electricity availability indicator",
    "internet": "Internet connection indicator",
    "pay_tv": "Pay TV subscription indicator",
    "pay_tv_cost": "Monthly Pay TV cost",
    "receives_support": "Whether household receives support/gifts",
    "gives_support": "Whether household gives support/gifts",
    "investment_income": "Savings/investment income amount",
    "pension_income": "Pension income amount",
    "rental_income": "Aggregated rental-property income",
    "other_regular_income": "Other regular income amount",
    "non_regular_income": "Non-regular income amount",
    "additional_income": "Sum of selected additional income sources",
    "food_insecurity_score": "Count of affirmative responses across qa1-qa9",
    "survey_weight": "KIHBS survey weight",
}

dictionary_df = pd.DataFrame(
    list(data_dictionary.items()),
    columns=["variable", "description"]
)

dictionary_df.to_csv(
    OUTPUT_DIR / "kihbs_data_dictionary.csv",
    index=False
)


# ============================================================
# 27. FINISHED
# ============================================================

print("\n" + "=" * 70)
print("CLEANING COMPLETE")
print("=" * 70)

print(
    f"\nClean dataset saved to:\n"
    f"{OUTPUT_FILE}"
)

print(
    f"\nData dictionary saved to:\n"
    f"{OUTPUT_DIR / 'kihbs_data_dictionary.csv'}"
)

print("\nNext step:")
print(
    "Run 02_generate_households.py to create the synthetic "
    "household population."
)