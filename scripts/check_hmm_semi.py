"""Defence check (25 Nov): semi-supervised HMM (initialised from the training labels, decoded causally) against the
Random Forest; RF across seeds, permutation importance and a bootstrap interval. Run: python scripts/check_hmm_semi.py"""
import numpy as np, pandas as pd
from hmmlearn import hmm
from sklearn.ensemble import RandomForestClassifier
from sklearn.inspection import permutation_importance
from pathlib import Path; R=str(Path(__file__).resolve().parents[1])+'/'
raw=pd.read_csv(R+'data/processed/engineered_features_raw.csv').merge(pd.read_csv(R+'data/processed/household_split.csv'),on='household_id').sort_values(['household_id','month'])
F=["income_to_expenditure_ratio","savings_share","entertainment_share","ratio_roll3","overspend_roll3"]
S=["Stable","Strained","Critical"]
tr,te=raw[raw.split=='train'],raw[raw.split=='test']
mu,sd=tr[F].mean(),tr[F].std()
z=lambda d:((d[F]-mu)/sd).values
# Semi-supervised HMM: parameters set from the training labels (counts), then decoded causally (forward filter) on test
y=tr.true_state.map({s:i for i,s in enumerate(S)}).values; Z=z(tr)
m=hmm.GaussianHMM(3,covariance_type='diag',init_params='',params='')
m.startprob_=np.bincount(tr[tr.month==1].true_state.map({s:i for i,s in enumerate(S)}),minlength=3)/ (tr.month==1).sum()
T=np.ones((3,3))
for _,g in tr.groupby('household_id'):
    s=g.true_state.map({s:i for i,s in enumerate(S)}).values
    for a,b in zip(s[:-1],s[1:]): T[a,b]+=1
m.transmat_=T/T.sum(1,keepdims=True)
m.means_=np.array([Z[y==k].mean(0) for k in range(3)]); m.covars_=np.array([Z[y==k].var(0)+1e-3 for k in range(3)])
def causal(g):
    X=z(g); out=[]
    for t in range(1,len(X)+1):
        out.append(m.predict_proba(X[:t])[-1].argmax())   # only months up to t
    return out
pred=np.concatenate([causal(g) for _,g in te.groupby('household_id')])
truth=te.true_state.map({s:i for i,s in enumerate(S)}).values
print("semi-supervised HMM (label-initialised, causal):",
      "exact",round((pred==truth).mean(),3),"within one",round((abs(pred-truth)<=1).mean(),3),
      "Stable/Critical mix-ups",round((abs(pred-truth)==2).mean(),3))
print("learned transitions from labels (rows Stable,Strained,Critical):\n",m.transmat_.round(2))
# Random Forest on same 5 features (fair feature set) + permutation importance of the deployed-style RF
FEAT=[c for c in raw.select_dtypes('number').columns if c!='month']
rf5=RandomForestClassifier(300,min_samples_leaf=5,random_state=0).fit(tr[F],tr.true_state)
print("RF on the same 5 HMM features: exact",round((rf5.predict(te[F])==te.true_state).mean(),3))
rf=RandomForestClassifier(300,min_samples_leaf=5,random_state=0).fit(tr[FEAT],tr.true_state)
acc=[(RandomForestClassifier(300,min_samples_leaf=5,random_state=s).fit(tr[FEAT],tr.true_state).predict(te[FEAT])==te.true_state).mean() for s in range(5)]
print("full RF exact across 5 seeds:",[round(a,3) for a in acc])
pi=permutation_importance(rf,te[FEAT],te.true_state,n_repeats=10,random_state=0)
top=pd.Series(pi.importances_mean,FEAT).sort_values(ascending=False).head(6)
print("permutation importance (test):",top.round(3).to_dict())
# bootstrap CI for full RF accuracy by household
p=rf.predict(te[FEAT])==te.true_state.values; ids=te.household_id.values; u=np.unique(ids); rng=np.random.default_rng(0)
ix={h:np.where(ids==h)[0] for h in u}
bs=[p[np.concatenate([ix[h] for h in rng.choice(u,len(u))])].mean() for _ in range(2000)]
print("RF exact 95% CI:",np.percentile(bs,[2.5,97.5]).round(3))
