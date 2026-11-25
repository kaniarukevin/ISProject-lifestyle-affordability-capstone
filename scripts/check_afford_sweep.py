"""Sweep Can I afford it? across 18 households x 14 options (plus the savings choice) and list every result that
breaks a rule: essentials below 85%, family support below 75%, a line cut to 0, Affordable while short, savings
not offered or not used when chosen, and wording ("1 months", "0 months"). Needs data/processed. 25 Nov: 0 of 271.
Run: python scripts/check_afford_sweep.py"""
import json, re, sys
from pathlib import Path
import pandas as pd
R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R / 'backend'))
import app as svc, store
from datetime import date
store._today = lambda: date(2026, 11, 15)
CATS = ["housing","food_groceries","transport","utilities","airtime_data","mobile_money_transfers","loan_repayment",
        "school_fees","entertainment","savings"]
d = pd.read_csv(R / 'data/processed/engineered_features_raw.csv')
split = pd.read_csv(R / 'data/processed/household_split.csv').set_index('household_id')['split']
test_ids = [h for h in split[split == 'test'].index][:14]
# map synthetic month 1..12 -> Nov 2025..Oct 2026
def ym(m):
    k = 2025 * 12 + 10 + (m - 1)   # m=1 -> Nov 2025
    return k // 12, k % 12 + 1
store.init("sqlite://")
c = svc.app.test_client()
n = [0]
def make(hid=None, savings=0, scale=1.0, obligations=None, debts=None, goals=None, typed_income=None, rows=None):
    n[0] += 1
    store._ATTEMPTS.clear()
    r = c.post("/auth/register", json={"email": f"u{n[0]}@example.com", "password": "mango-river-42", "consent": True})
    h = {"Authorization": f"Bearer {r.get_json()['token']}"}
    g = rows if rows is not None else d[d.household_id == hid].sort_values('month')
    inc = typed_income or float(g.total_income.median()) * scale
    c.put("/me/profile", headers=h, json={"householdSize": int(g.household_size.iloc[0]) if 'household_size' in g else 2,
          "dependants": int(g.num_dependants.iloc[0]) if 'num_dependants' in g else 0,
          "incomes": [{"name": "Pay", "amount": round(inc)}], "savingsBalance": savings})
    tx = []
    for _, mo in g.iterrows():
        y, m = ym(int(mo.month))
        for cat in CATS:
            a = float(mo[cat]) * scale
            if a > 0: tx.append({"date": f"{y}-{m:02d}-05", "amount": round(a), "category": cat})
    for i in range(0, len(tx), 200):
        c.post("/me/transactions", headers=h, json=tx[i:i+200])
    if obligations or debts or goals:
        c.put("/me/commitments", headers=h, json={"obligations": obligations or [], "debts": debts or [], "goals": goals or []})
    return h, inc
OPTIONS = lambda inc: [
  ("phone cash 10k", {"preset": "purchase", "price": 10000, "months": 1}),
  ("phone 6m 60k", {"preset": "purchase", "price": 60000, "months": 6, "annual_rate": 20}),
  ("laptop cash 120k", {"preset": "purchase", "price": 120000, "months": 1}),
  ("loan 200k 12m", {"preset": "loan", "amount": 200000, "months": 12, "annual_rate": 14}),
  ("move rent +50%", {"preset": "move_house", "new_rent": 15000}),
  ("new baby", {"preset": "new_baby"}),
  ("gym 3k/m", {"preset": "new_expense", "category": "entertainment", "amount": 3000, "label": "Gym"}),
  ("course 3 months", {"preset": "new_expense", "category": "school_fees", "amount": 8000, "months": 3}),
  ("trip 90k in 3m", {"preset": "savings_goal", "target": 90000, "months": 3, "label": "Trip"}),
  ("goal 20k in 6m", {"preset": "savings_goal", "target": 20000, "months": 6}),
  ("income -30%", {"preset": "income_change", "amount": -0.3 * inc}),
  ("HELB late 2m", {"preset": "income_change", "amount": -0.5 * inc, "months": 2}),
  ("plan: car", {"preset": "plan", "label": "Car", "upfront": {"amount": 300000, "pay": "instalments", "months": 24, "annual_rate": 15},
                 "costs": [{"category": "transport", "amount": 6000, "per": "month"}]}),
  ("plan: fees per term", {"preset": "plan", "costs": [{"category": "school_fees", "amount": 25000, "per": "term", "label": "Fees"}]}),
]
ESS = {"food_groceries": .85, "transport": .85, "utilities": .85, "airtime_data": .85}
problems = []
def walk_text(o):
    if isinstance(o, str): yield o
    elif isinstance(o, dict):
        for v in o.values(): yield from walk_text(v)
    elif isinstance(o, list):
        for v in o: yield from walk_text(v)
def check(who, opt, res, savings):
    v = res.get("verdict"); left = (res.get("after") or {}).get("left_over_KES")
    for t in walk_text(res):
        if re.search(r"\b1 months\b|\babout 0 months\b|\b0 months\b|month\(s\)", t): problems.append((who, opt, "wording", t[:110]))
    b = res.get("budgets") or {}
    for ln in b.get("lines") or []:
        now, after = ln["now"], ln["after"]
        if after is None or not now: continue
        if ln["category"] in ESS and after < ESS[ln["category"]] * now - 2:
            problems.append((who, opt, f"essential cut ({v})", f"{ln['category']} {now}->{after}"))
        if ln["category"] == "mobile_money_transfers" and after < .75 * now - 2:
            problems.append((who, opt, f"family support cut ({v})", f"{now}->{after}"))
        if after == 0 and now > 0 and ln["category"] not in ("entertainment", "shopping", "personal_care", "savings"):
            problems.append((who, opt, f"line to 0 ({v})", ln["category"]))
    if v == "Affordable" and left is not None and left < 0:
        problems.append((who, opt, "Affordable but short", left))
    if res.get("type") == "purchase" or "phone cash" in opt or "laptop cash" in opt:
        pass
    price = {"phone cash 10k": 10000, "laptop cash 120k": 120000}.get(opt)
    if price and savings >= price * 3 + 200000 and v != "Affordable" and not res.get("savings_offer"):
        problems.append((who, opt, "savings could cover, no offer", f"{v}, savings {savings}"))
    tgt = {"trip 90k in 3m": 90000, "goal 20k in 6m": 20000}.get(opt)
    if tgt and savings >= tgt * 3 + 200000 and v != "Affordable" and not res.get("savings_offer"):
        problems.append((who, opt, "savings could cover, no offer", f"{v}, savings {savings}"))
cases = []
for i, hid in enumerate(test_ids):
    sav = [0, 20000, 250000][i % 3]
    cases.append((f"{hid}/sav{sav}", dict(hid=hid, savings=sav)))
cases.append(("H-rich", dict(hid=test_ids[0], savings=500000, scale=3)))
cases.append(("H-poor", dict(hid=test_ids[1], savings=0, scale=0.4)))
cases.append(("H-debts", dict(hid=test_ids[2], savings=5000,
              debts=[{"name": "Fuliza", "balance": 8000, "annual_rate": 90, "monthly_payment": 3000},
                     {"name": "SACCO", "balance": 60000, "annual_rate": 12, "monthly_payment": 6000}])))
cases.append(("H-goals", dict(hid=test_ids[3], savings=80000, goals=[{"name": "Laptop", "target": 60000, "saved": 20000, "months_left": 4}],
              obligations=[{"name": "Fees", "amount": 18000, "category": "school_fees", "frequency": "termly"}])))
total = 0; errors = []; offers = []
for who, kw in cases:
    h, inc = make(**kw)
    for opt, body in OPTIONS(inc):
        r = c.post("/me/afford", headers=h, json=body); total += 1
        if r.status_code != 200: errors.append((who, opt, r.status_code, (r.get_json() or {}).get("error"))); continue
        res = r.get_json()
        check(who, opt, res, kw.get("savings", 0))
        if res.get("savings_offer"):
            r2 = c.post("/me/afford", headers=h, json={**body, "use_savings": True}); total += 1
            if r2.status_code != 200: errors.append((who, opt + " +savings", r2.status_code, (r2.get_json() or {}).get("error"))); continue
            res2 = r2.get_json()
            check(who, opt + " +savings", res2, kw.get("savings", 0))
            if not res2.get("using_savings"): problems.append((who, opt, "savings chosen but not used", res2.get("verdict")))
            offers.append((who, opt, res["verdict"], res2["verdict"], res["savings_offer"]["free_KES"], res2.get("using_savings")))
print("checks run:", total, " errors:", len(errors))
for e in errors[:10]: print("  ERR", e)
from collections import Counter
cnt = Counter(p[2].split(" (")[0] if "(info)" not in p[2] else p[2] for p in problems)
print("problem counts:", dict(cnt))
seen = set()
for p in problems:
    k = (p[1], p[2])
    if k in seen: continue
    seen.add(k); print("  ", p)
pairs = {}
for p in problems:
    pairs.setdefault(p[2].split(" (")[0] if "(info)" not in p[2] else p[2], set()).add((p[0], p[1]))
print("checks affected per rule:", {k: len(v) for k, v in pairs.items()})
allbad = set((p[0], p[1]) for p in problems if "(info)" not in p[2])
print("checks with at least one real problem:", len(allbad), "of", total)

print("savings offers:", len(offers))
for o in offers[:8]: print("  ", o)
