import pandas as pd

df = pd.read_stata("/Users/kevinkaniaru/ISPROJTEST/data/raw/HH_Members_Information.dta")
df["household_id"] = df["clid"].astype(int).astype(str) + "_" + df["hhid"].astype(int).astype(str)  # FIXED: ids now match the households file

# d26 = monthly wage/salary per member -> sum across household
wages = df.groupby("household_id")["d26"].sum(min_count=1).rename("total_wage_income")

# d43 = second job/activity income per member -> sum across household
secondary = df.groupby("household_id")["d43"].sum(min_count=1).rename("total_secondary_income")

# d02_4 = business enterprise involvement flag
business = df.groupby("household_id")["d02_4"].apply(lambda x: (x == 1).any()).rename("has_business_income")

household_income = pd.concat([wages, secondary, business], axis=1).reset_index()
household_income["total_wage_income"] = household_income["total_wage_income"].fillna(0)
household_income["total_secondary_income"] = household_income["total_secondary_income"].fillna(0)

print("Shape:", household_income.shape)
print(household_income.describe())
household_income.head(10)