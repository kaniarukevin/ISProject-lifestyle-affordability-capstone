"""Does the app forecast push up January, May and September for someone who pays no school fees?

The forecast model is told the calendar fee months (January, May, September) for every user. This checks, on the
60 held-out test households, the model as deployed against the same model with the fee-month flag switched off for
households with no school fees in their records. Same examples and floor as the app (docs/experiments.md, 6 Nov).

Run: python scripts/fee_month_check.py
"""
import sys, joblib, numpy as np, pandas as pd
from pathlib import Path
root = Path(__file__).resolve().parents[1] if len(sys.argv) < 2 else Path(sys.argv[1])
eng = joblib.load(root / "backend/models/user_forecast.joblib")
CATS = ["housing","food_groceries","transport","utilities","airtime_data","mobile_money_transfers","loan_repayment","school_fees","entertainment","savings"]
FEE = tuple(eng["fee_months"])
d = pd.read_csv(f"{root}/data/processed/engineered_features_raw.csv")
split = pd.read_csv(f"{root}/data/processed/household_split.csv").set_index("household_id")["split"]
d["spend"] = d[CATS].sum(axis=1); d = d.sort_values(["household_id","month"])
payers = set(d.loc[d.school_fees > 0, "household_id"])
rows = []
for hid, g in d[d.household_id.isin(split[split=="test"].index)].groupby("household_id"):
    g = g.set_index("month")
    for t in range(2, 13):
        for h in (1,3,6,11):
            past = g.loc[max(1,t-h):t-1]
            if len(past) < min(h,t-1) or len(past)==0: continue
            tot = past["spend"]; fp = past.loc[past.index.isin(FEE), "school_fees"]
            rows.append(dict(hid=hid, t=t, h=len(past), median=tot.median(), mean=tot.mean(), last=tot.iloc[-1],
                min=tot.min(), max=tot.max(), std=tot.std() if len(tot)>1 else 0.0,
                income=past["total_income"].iloc[-1], income_mean=past["total_income"].mean(),
                household_size=g["household_size"].iloc[0], num_dependants=g["num_dependants"].iloc[0],
                formal=int(g["income_tier"].iloc[0]=="formal_salaried"), month=t, fee_month=int(t in FEE),
                december=int(t==12), fees_seen=fp.max() if len(fp) else 0.0, fees_median=past["school_fees"].median(),
                any_fees=float(past["school_fees"].sum()>0),
                nonfee_total=float((tot - past["school_fees"]).median()), actual=g.loc[t,"spend"], payer=hid in payers))
df = pd.DataFrame(rows)
def predict(df, gate):
    """gate=True: the fee-month flag only for households with school fees in their records (the app also counts a
    school-fees bill or \"I pay my own fees\")."""
    x = df.copy()
    if gate: x["fee_month"] = np.where(x["any_fees"] > 0, x["fee_month"], 0)
    mid = x["median"] * np.clip(eng["model"].predict(x[eng["features"]]), 0, None)
    floor = (x["fee_month"]==1) & (x["fees_seen"]>0)
    return np.where(floor, np.maximum(mid, x["nonfee_total"] + x["fees_seen"]), mid)
print(f"test rows {len(df)}, households {df.hid.nunique()}, never pay fees: {(~df.groupby('hid').payer.first()).sum()}")
for gate in (False, True):
    p = predict(df, gate); e = p - df.actual
    def s(m): return f"MAE {np.abs(e[m]).mean():7,.0f}  bias {e[m].mean():+7,.0f}  (n={m.sum()})"
    print(f"\n{'gated' if gate else 'as deployed'}")
    print("  all                      ", s(np.ones(len(df), bool)))
    print("  non-payers, fee months   ", s((~df.payer) & (df.fee_month==1)))
    print("  non-payers, other months ", s((~df.payer) & (df.fee_month==0)))
    print("  payers, fee months       ", s(df.payer & (df.fee_month==1)))
