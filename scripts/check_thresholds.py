"""Defence check (25 Nov): score cut-offs from training households only (out-of-fold), not the test households.
Run: python scripts/check_thresholds.py"""
import numpy as np, pandas as pd, joblib
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.model_selection import GroupKFold
from pathlib import Path; R=str(Path(__file__).resolve().parents[1])+'/'
raw=pd.read_csv(R+'data/processed/engineered_features_raw.csv').merge(pd.read_csv(R+'data/processed/household_split.csv'),on='household_id')
eng=joblib.load(R+'backend/models/affordability_engine.joblib')
MF=eng['score_features']
MONO={"total_income":1,"total_expenditure":-1,"income_to_expenditure_ratio":1,"ratio_roll3":1,"overspend_flag":-1,"overspend_roll3":-1,"exp_roll3":-1,"exp_roll6":-1,"savings_rate":1,"debt_service_coverage_ratio":-1,"zero_income_flag":-1,"household_size":0,"num_dependants":0,"dependant_cost_factor":0}
cst=[MONO[f] for f in MF]
def fit(tr):
    a=HistGradientBoostingClassifier(monotonic_cst=cst,max_iter=300,learning_rate=0.05,random_state=0).fit(tr[MF],tr.true_state=="Stable")
    b=HistGradientBoostingClassifier(monotonic_cst=cst,max_iter=300,learning_rate=0.05,random_state=0).fit(tr[MF],tr.true_state!="Critical")
    return a,b
def score(models,X):
    a,b=models; ps=a.predict_proba(X[MF])[:,1]; pok=np.maximum(b.predict_proba(X[MF])[:,1],ps); return 100*(ps+pok)/2
train,test=raw[raw.split=='train'],raw[raw.split=='test']
# deployed models, test month-12 means (how the report did it)
dep=(eng['p_stable_model'],eng['p_ok_model'])
t12=test[test.month==12].copy(); t12['s']=score(dep,t12)
print("TEST month-12 means (original method):",t12.groupby('true_state').s.mean().round(1).to_dict())
# out-of-fold on train households only
oof=train.copy(); oof['s']=np.nan
for tr,va in GroupKFold(5).split(train,groups=train.household_id):
    m=fit(train.iloc[tr]); oof.iloc[va,oof.columns.get_loc('s')]=score(m,train.iloc[va])
for label,d in [("OOF train, month 12",oof[oof.month==12]),("OOF train, all months",oof)]:
    mu=d.groupby('true_state').s.mean(); print(label,mu.round(1).to_dict(),
      "-> cutoffs affordable",round((mu.Stable+mu.Strained)/2,1),"stretch",round((mu.Strained+mu.Critical)/2,1))
mu=oof[oof.month==12].groupby('true_state').s.mean()
A,S=round((mu.Stable+mu.Strained)/2),round((mu.Strained+mu.Critical)/2)
def v(s,a,st): return np.where(s>=a,"Affordable",np.where(s>=st,"Stretch","Not affordable"))
old=v(t12.s,56,33); new=v(t12.s,A,S)
print(f"new cutoffs {A}/{S}; test month-12 verdicts changed: {(old!=new).sum()} of {len(t12)}")
truth=t12.true_state.map({"Stable":"Affordable","Strained":"Stretch","Critical":"Not affordable"})
print("verdict matches state: old",round((old==truth).mean(),3),"new",round((new==truth).mean(),3))
