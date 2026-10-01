import pandas as pd

df = pd.read_stata("/Users/kevinkaniaru/ISPROJTEST/data/raw/HH_Members_Information.dta")

print("Shape:", df.shape)
print()
print("Columns:")
print(df.columns.tolist())