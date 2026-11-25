"""Defence check (25 Nov): LSTM, exponential smoothing, naive and seasonal naive against the deployed forecast tree,
on the same 60 test households, with household bootstrap 95% intervals. Needs torch. Run: python scripts/check_forecast.py"""
import numpy as np, pandas as pd, joblib, torch, torch.nn as nn
from pathlib import Path; R=str(Path(__file__).resolve().parents[1])+'/'
eng=joblib.load(R+'backend/models/user_forecast.joblib')
CATS=["housing","food_groceries","transport","utilities","airtime_data","mobile_money_transfers","loan_repayment","school_fees","entertainment","savings"]
FEE=tuple(eng["fee_months"])
d=pd.read_csv(R+'data/processed/engineered_features_raw.csv')
split=pd.read_csv(R+'data/processed/household_split.csv').set_index("household_id")["split"]
d["spend"]=d[CATS].sum(axis=1); d=d.sort_values(["household_id","month"])
def rows_for(ids):
    rows=[]
    for hid,g in d[d.household_id.isin(ids)].groupby("household_id"):
        g=g.set_index("month")
        for t in range(2,13):
            for h in (1,3,6,11):
                past=g.loc[max(1,t-h):t-1]
                if len(past)<min(h,t-1) or len(past)==0: continue
                tot=past["spend"]; fp=past.loc[past.index.isin(FEE),"school_fees"]
                rows.append(dict(hid=hid,t=t,h=len(past),median=tot.median(),mean=tot.mean(),last=tot.iloc[-1],
                  min=tot.min(),max=tot.max(),std=tot.std() if len(tot)>1 else 0.0,income=past["total_income"].iloc[-1],
                  income_mean=past["total_income"].mean(),household_size=g["household_size"].iloc[0],num_dependants=g["num_dependants"].iloc[0],
                  formal=int(g["income_tier"].iloc[0]=="formal_salaried"),month=t,fee_month=int(t in FEE),december=int(t==12),
                  fees_seen=fp.max() if len(fp) else 0.0,fees_median=past["school_fees"].median(),
                  nonfee_total=float((tot-past["school_fees"]).median()),actual=g.loc[t,"spend"],hst=list(tot)))
    return pd.DataFrame(rows)
test_ids=split[split=="test"].index; train_ids=split[split=="train"].index
te=rows_for(test_ids); tr=rows_for(train_ids)
def tree(x):
    mid=x["median"]*np.clip(eng["model"].predict(x[eng["features"]]),0,None)
    floor=(x["fee_month"]==1)&(x["fees_seen"]>0)
    return np.where(floor,np.maximum(mid,x["nonfee_total"]+x["fees_seen"]),mid)
def ses(hist,a):
    l=hist[0]
    for v in hist[1:]: l=a*v+(1-a)*l
    return l
alphas=np.linspace(0.05,0.95,19)
best=min(alphas,key=lambda a: np.abs(np.array([ses(h,a) for h in tr.hst])-tr.actual).mean())
# seasonal naive: only possible as "same month last year" -> not available within 12 months; use 4-month school-term season
def snaive(hist): return hist[-4] if len(hist)>=4 else hist[-1]
# LSTM on train households: input = scaled monthly totals (+month-of-year sin/cos, fee flag), predict next total
torch.manual_seed(0); np.random.seed(0)
class M(nn.Module):
    def __init__(s): super().__init__(); s.l=nn.LSTM(4,32,batch_first=True); s.o=nn.Linear(32,1)
    def forward(s,x): o,_=s.l(x); return s.o(o[:,-1])
def seq(r):
    h=np.array(r.hst); sc=np.median(h) or 1.0
    months=np.arange(r.t-len(h),r.t)
    x=np.stack([h/sc,np.sin(2*np.pi*months/12),np.cos(2*np.pi*months/12),np.isin((months%12)+0,FEE).astype(float)],1)
    nxt=np.array([np.sin(2*np.pi*r.t/12),np.cos(2*np.pi*r.t/12),float(r.t in FEE)])
    x=np.vstack([x,np.r_[0.0,nxt]])  # last step carries the target month's calendar
    return torch.tensor(x,dtype=torch.float32),sc
def batches(df):
    out={}
    for r in df.itertuples():
        x,sc=seq(r); out.setdefault(len(x),[]).append((x,sc,r.actual))
    return out
def predict_lstm(models,df):
    preds=np.zeros(len(df))
    for i,r in enumerate(df.itertuples()):
        x,sc=seq(r)
        with torch.no_grad(): preds[i]=np.mean([m(x[None]).item() for m in models])*sc
    return preds
def train_lstm(seed):
    torch.manual_seed(seed); m=M(); opt=torch.optim.Adam(m.parameters(),1e-2)
    B=batches(tr)
    for ep in range(60):
        for L,items in B.items():
            X=torch.stack([a for a,_,_ in items]); y=torch.tensor([c/b for _,b,c in items],dtype=torch.float32)[:,None]
            opt.zero_grad(); loss=nn.functional.l1_loss(m(X),y); loss.backward(); opt.step()
    return m
lstms=[train_lstm(s) for s in range(3)]
P={"Deployed tree (Tosha)":tree(te),"LSTM (3 seeds, averaged)":predict_lstm(lstms,te),
   f"Exponential smoothing (alpha {best:.2f})":np.array([ses(h,best) for h in te.hst]),
   "Median of past months":te["median"].to_numpy(),"Naive (last month)":te["last"].to_numpy(),
   "Seasonal naive (same point last term)":np.array([snaive(h) for h in te.hst])}
per_seed=[np.abs(predict_lstm([m],te)-te.actual).mean() for m in lstms]
rng=np.random.default_rng(0); hids=te.hid.unique(); idx={h:np.where(te.hid==h)[0] for h in hids}
base=np.abs(P["Deployed tree (Tosha)"]-te.actual.to_numpy())
print(f"test rows {len(te)}, households {len(hids)}")
for k,p in P.items():
    e=np.abs(p-te.actual.to_numpy()); mae=e.mean()
    bs=[];diff=[]
    for _ in range(2000):
        s=np.concatenate([idx[h] for h in rng.choice(hids,len(hids))]); bs.append(e[s].mean()); diff.append(e[s].mean()-base[s].mean())
    lo,hi=np.percentile(bs,[2.5,97.5]); dlo,dhi=np.percentile(diff,[2.5,97.5])
    print(f"{k:42s} MAE {mae:8,.0f}  95% CI {lo:8,.0f}-{hi:8,.0f}   vs tree {np.mean(diff):+7,.0f} [{dlo:+,.0f}, {dhi:+,.0f}]")
print("LSTM per seed:",[round(x) for x in per_seed])
