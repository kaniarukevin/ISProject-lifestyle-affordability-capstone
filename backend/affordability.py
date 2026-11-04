"""Lifestyle affordability engine (capstone). Mirrors notebooks/06_affordability.ipynb.

The app sends the household's own monthly figures (it does not look up a staging userId),
so this works for any household, including students. All amounts are KES per month.
"""
import math
from pathlib import Path

import joblib
import numpy as np
import pandas as pd

CATS = ["housing", "food_groceries", "transport", "utilities", "airtime_data",
        "mobile_money_transfers", "loan_repayment", "school_fees", "entertainment", "savings"]
INCOME = ["income_primary", "income_secondary", "informal_cash_income"]
FLEXIBLE = ["entertainment", "transport", "airtime_data"]
ENGINE_PATH = Path(__file__).resolve().parent / "models" / "affordability_engine.joblib"
_ENGINE = {}


class AffordabilityInputError(ValueError):
    """Raised for requests the engine cannot score; the API turns it into a 400."""


def engine():
    """Load the trained models once per process, on first use."""
    if "e" not in _ENGINE:
        _ENGINE["e"] = joblib.load(ENGINE_PATH)
    return _ENGINE["e"]


# ---------- features (identical to data_generation/07_feature_engineering.py) ----------

def build_features(m):
    m = m.sort_values("month").copy()
    m["total_expenditure"] = m[CATS].sum(axis=1)
    m["total_income"] = m[INCOME].sum(axis=1)
    exp = m["total_expenditure"].replace(0, np.nan)
    inc = m["total_income"].replace(0, np.nan)
    m["income_to_expenditure_ratio"] = (m["total_income"] / exp).fillna(0.0).clip(0.0, 3.0)
    m["zero_income_flag"] = (m["total_income"] == 0).astype(float)
    for c in CATS:
        m[f"{c}_share"] = (m[c] / exp).fillna(0.0)
    m["savings_rate"] = (m["savings"] / inc).fillna(0.0)
    m["monthly_debt_repayment"] = m["loan_repayment"]
    m["debt_service_coverage_ratio"] = (m["loan_repayment"] / inc).fillna(0.0).clip(upper=3.0)
    m["overspend_flag"] = (m["total_expenditure"] > m["total_income"]).astype(float)
    m["ratio_roll3"] = m["income_to_expenditure_ratio"].rolling(3, min_periods=1).mean()
    m["overspend_roll3"] = m["overspend_flag"].rolling(3, min_periods=1).mean()
    m["exp_roll3"] = m["total_expenditure"].rolling(3, min_periods=1).mean()
    m["exp_roll6"] = m["total_expenditure"].rolling(6, min_periods=1).mean()
    cm = m["total_expenditure"].expanding().mean()
    cs = m["total_expenditure"].expanding().std().fillna(0)
    m["spending_regularity_score"] = 1 / (1 + (cs / cm.replace(0, np.nan)).fillna(0))
    m["dependant_cost_factor"] = (m["num_dependants"] / m["household_size"].replace(0, np.nan)).fillna(0.0)
    return m


def months_frame(months, household_size, num_dependants):
    """Turn the request's list of months (oldest first) into a DataFrame, validating amounts."""
    if not isinstance(months, list) or not 1 <= len(months) <= 24:
        raise AffordabilityInputError("months must be a list of 1 to 24 monthly records, oldest first")
    rows = []
    for i, mth in enumerate(months):
        if not isinstance(mth, dict):
            raise AffordabilityInputError("each month must be an object of category amounts")
        row = {"month": i + 1}
        for c in CATS + INCOME:
            try:
                v = float(mth.get(c, 0) or 0)
            except (TypeError, ValueError):
                raise AffordabilityInputError(f"{c} must be a number")
            if v < 0:
                raise AffordabilityInputError(f"{c} cannot be negative")
            row[c] = v
        rows.append(row)
    m = pd.DataFrame(rows)
    m["household_size"] = float(household_size)
    m["num_dependants"] = float(num_dependants)
    return m


# ---------- scoring ----------

def _score(f):
    e = engine()
    X = f[e["score_features"]]
    ps = e["p_stable_model"].predict_proba(X)[:, 1]
    pok = np.maximum(e["p_ok_model"].predict_proba(X)[:, 1], ps)
    return float(100 * (ps[0] + pok[0]) / 2)


def _state(f):
    e = engine()
    return str(e["state_model"].predict(f[e["state_features"]])[0])


def _verdict(score):
    cut = engine()["cutoffs"]
    return "Affordable" if score >= cut["affordable"] else ("Stretch" if score >= cut["stretch"] else "Not affordable")


def _apply(m, changes=None, income_change=0.0, months=3):
    """Apply a change to the last `months` months, as if it had been in place that long."""
    after = m.copy()
    recent = after["month"] > after["month"].max() - months
    for cat, kes in (changes or {}).items():
        if cat not in CATS:
            raise AffordabilityInputError(f"unknown category: {cat}")
        after.loc[recent, cat] = (after.loc[recent, cat] + float(kes)).clip(lower=0)
    after.loc[recent, "income_primary"] = (after.loc[recent, "income_primary"] + float(income_change)).clip(lower=0)
    return after


def _facts(f):
    r = f.iloc[0]
    return {"income_KES": round(r.total_income), "spending_KES": round(r.total_expenditure),
            "left_over_KES": round(r.total_income - r.total_expenditure),
            "income_to_spending": round(float(r.income_to_expenditure_ratio), 2),
            "debt_share_of_income": round(float(r.debt_service_coverage_ratio), 2),
            "savings_KES": round(r.savings)}


def assess(m, changes=None, income_change=0.0, duration=None, savings_balance=0.0, debt_label="Loan repayments"):
    """Score now and after a monthly change, with the savings safety rule and plain-language reasons.

    duration: how many months the change lasts (None = for good). A 1-month cost is applied to 1 month only,
    not treated as permanent. savings_balance: money already saved; a temporary shortfall it can cover is a
    Stretch, not Not affordable (found in testing, 1 Nov: a 1-month instalment was judged as a permanent cost)."""
    span = min(int(duration), 3) if duration else 3
    bf = build_features(m).iloc[[-1]]
    af = build_features(_apply(m, changes, income_change, months=span)).iloc[[-1]]
    sb, sa = _score(bf), _score(af)
    b, a = _facts(bf), _facts(af)
    verdict = _verdict(sa)
    shortfall = max(0, -a["left_over_KES"])
    gap = max(0, shortfall - b["savings_KES"])          # still missing after pausing the usual monthly saving
    balance = max(0, round(float(savings_balance or 0)))
    reasons = []
    if gap > 0 and duration and gap * int(duration) <= balance:
        verdict = "Stretch"
        reasons.append(f"For {int(duration)} month(s) you would be short KES {gap:,} a month even after pausing "
                       f"savings. Your savings of KES {balance:,} cover that, leaving KES {balance - gap * int(duration):,}.")
    elif gap > 0:
        verdict = "Not affordable"
        reasons.append(f"You would be short KES {shortfall:,} a month, more than the KES {b['savings_KES']:,} you save.")
        if balance > 0:
            reasons.append(f"Your savings of KES {balance:,} would cover the gap for about {balance // gap} month(s).")
    elif shortfall > 0:
        reasons.append(f"You would be short KES {shortfall:,} a month; you could cover it only by pausing savings.")
    else:
        reasons.append(f"You would still have KES {a['left_over_KES']:,} left each month.")
    if debt_label and a["debt_share_of_income"] >= 0.3:
        reasons.append(f"{debt_label} would take {a['debt_share_of_income']:.0%} of your income.")
    if a["spending_KES"] - a["savings_KES"] > a["income_KES"]:
        reasons.append("Your spending, before savings, would be more than you earn"
                       + (" while you pay." if duration else "."))
    return {"score_before": round(sb), "score_after": round(sa), "verdict": verdict,
            "state_now": _state(bf), "before": b, "after": a, "reasons": reasons,
            "savings_balance_KES": balance, "lasts_months": int(duration) if duration else None,
            # A short cost scores the months you pay, not your finances for good (found walking through the app:
            # a one-month repair showed "score 54 -> 2" with no explanation).
            "score_note": (f"The score after is for the {int(duration)} month(s) you pay; it recovers once paid."
                           if duration else None)}


def what_to_cut(m, changes=None, income_change=0.0, **kw):
    """Smallest equal % cut to flexible spending to (1) stop being short, (2) reach Affordable."""
    typical = m.sort_values("month").tail(3)[FLEXIBLE].mean()
    break_even = comfortable = None
    for pct in range(5, 55, 5):
        combined = dict(changes or {})
        cuts = {c: round(float(typical[c]) * pct / 100) for c in FLEXIBLE}
        for c, v in cuts.items():
            combined[c] = combined.get(c, 0) - v
        r = assess(m, combined, income_change, **kw)
        plan = {"cut_each_by_percent": pct, "monthly_cuts_KES": cuts, "total_cut_KES": sum(cuts.values()),
                "left_over_after_KES": r["after"]["left_over_KES"], "score": r["score_after"], "verdict": r["verdict"]}
        if break_even is None and r["after"]["left_over_KES"] >= 0:
            break_even = plan
        if comfortable is None and r["verdict"] == "Affordable":
            comfortable = plan
        if break_even and comfortable:
            break
    none = "Not reachable by cutting entertainment, transport and airtime/data by up to half."
    return {"to_break_even": break_even or none, "to_be_comfortable": comfortable or none}


def _advice(before, per_month, months=None, balance=0):
    """When a change does not work, say what would: the most the household can take on per month."""
    room = before["left_over_KES"] + before["savings_KES"]   # left over, plus savings if paused
    if months and balance > 0:
        room += round(balance / months)                       # plus the savings balance, spread over the months
    if before["left_over_KES"] < 0 and room <= 0:
        return [f"You are already short KES {-before['left_over_KES']:,} a month before this change. "
                "Bring your current spending within your income first."]
    how = "by pausing savings and using what you have saved" if months and balance > 0 else "and only by pausing savings"
    tips = [f"The most you could take on is about KES {max(0, room):,} a month, {how}."]
    if months:
        tips.append(f"Over {months} months that is a price of up to about KES {max(0, room) * months:,}.")
        if room > 0:
            tips.append(f"To pay KES {round(per_month * months):,} this way, spread it over about "
                        f"{math.ceil(per_month * months / room)} months instead.")
    return tips


def _cash_flow(before, per_month, months, balance):
    """Month by month while paying: what is left, whether the usual saving pauses, and the savings balance."""
    left, usual_saving, bal, rows = before["left_over_KES"], before["savings_KES"], float(balance), []
    for i in range(1, min(int(months), 36) + 1):
        short = max(0.0, per_month - left)
        paused = min(usual_saving, short)
        drawn = short - paused
        bal += usual_saving - paused - drawn
        rows.append({"month": i, "pay_KES": round(per_month), "left_after_KES": round(max(0.0, left - per_month)),
                     "saving_paused_KES": round(paused), "from_savings_KES": round(drawn),
                     "savings_balance_KES": round(bal)})
    return rows


def purchase(m, price, months=6, monthly_interest=0.0, savings_balance=0.0):
    """A purchase paid over `months` months (1 = pay it all now). The cost lasts only those months, the savings
    balance can cover a temporary gap, and the answer says what happens month by month."""
    price, months, r = float(price), int(months), float(monthly_interest)
    if price <= 0 or months < 1 or r < 0:
        raise AffordabilityInputError("price must be positive, months at least 1, interest not negative")
    balance = max(0.0, float(savings_balance or 0))
    per_month = price * r / (1 - (1 + r) ** -months) if r > 0 else price / months
    kw = {"duration": months, "savings_balance": balance,
          # a single payment is not a loan; instalments are reported together with existing loans
          "debt_label": None if months == 1 else "These instalments and your loans"}
    result = assess(m, {"loan_repayment": per_month}, **kw)
    left, saving = result["before"]["left_over_KES"], result["before"]["savings_KES"]
    rate = left + saving                                   # what can be put aside each month
    still_needed = max(0.0, price - balance)
    result.update({"instalment_per_month_KES": round(per_month), "total_paid_KES": round(per_month * months),
                   "cash_flow": _cash_flow(result["before"], per_month, months, balance),
                   "months_to_save_up_first": 0 if still_needed == 0 else (math.ceil(still_needed / rate) if rate > 0 else None)})
    if balance > 0:
        result["pay_from_savings"] = {"possible": balance >= price, "savings_left_KES": round(balance - price)}
        if balance >= price:
            result["reasons"].append(f"You could also pay it all now from your savings and keep KES {round(balance - price):,}.")
    if result["verdict"] != "Affordable":
        result["what_to_cut"] = what_to_cut(m, {"loan_repayment": per_month}, **kw)
    if result["verdict"] == "Not affordable":
        result["advice"] = _advice(result["before"], per_month, months, balance)
    if result["months_to_save_up_first"] is None:
        result["months_to_save_up_first"] = "Not possible yet: nothing is left over each month."
    return result


def savings_goal(m, extra_per_month):
    """Saving more moves left-over money into savings; it is not a new cost, so it is not scored."""
    extra = float(extra_per_month)
    if extra <= 0:
        raise AffordabilityInputError("extra_per_month must be positive")
    f = build_features(m).iloc[[-1]]
    left = _facts(f)["left_over_KES"]
    if extra <= left:
        return {"verdict": "Affordable", "left_over_KES": left,
                "reasons": [f"You have KES {left:,} left each month, so saving KES {round(extra):,} more fits."]}
    short = extra - left
    typical = m.sort_values("month").tail(3)[FLEXIBLE].mean()
    out = {"verdict": "Not affordable yet", "left_over_KES": left,
           "reasons": [f"You have KES {left:,} left each month, so you are KES {round(short):,} short."]}
    if typical.sum() > 0 and short <= typical.sum() * 0.5:
        share = typical / typical.sum()
        out["what_to_cut"] = {"monthly_cuts_KES": {c: round(short * share[c]) for c in FLEXIBLE},
                              "total_cut_KES": round(short)}
    else:
        out["reasons"].append("That would need cutting more than half your flexible spending; try a smaller goal.")
    return out


def evaluate(payload):
    """Entry point for POST /affordability."""
    if not isinstance(payload, dict):
        raise AffordabilityInputError("request body must be a JSON object")
    hh = payload.get("household") or {}
    try:
        size, deps = float(hh.get("household_size", 1)), float(hh.get("num_dependants", 0))
    except (TypeError, ValueError):
        raise AffordabilityInputError("household_size and num_dependants must be numbers")
    if size < 1 or deps < 0:
        raise AffordabilityInputError("household_size must be at least 1 and num_dependants not negative")
    m = months_frame(payload.get("months"), size, deps)
    try:
        balance = float(payload.get("savings_balance", 0) or 0)
    except (TypeError, ValueError):
        raise AffordabilityInputError("savings_balance must be a number")
    if balance < 0:
        raise AffordabilityInputError("savings_balance cannot be negative")
    sc = payload.get("scenario") or {"type": "none"}
    kind = sc.get("type", "none")
    if kind == "none":
        return assess(m)
    if kind == "monthly_change":
        changes, inc = sc.get("changes") or {}, float(sc.get("income_change", 0) or 0)
        lasts = sc.get("months")                         # None = for good; a number = a temporary change
        if lasts is not None and (not isinstance(lasts, (int, float)) or lasts < 1):
            raise AffordabilityInputError("scenario.months must be at least 1 (leave it out for a lasting change)")
        kw = {"duration": int(lasts) if lasts else None, "savings_balance": balance}
        result = assess(m, changes, inc, **kw)
        if result["verdict"] != "Affordable":
            result["what_to_cut"] = what_to_cut(m, changes, inc, **kw)
        if result["verdict"] == "Not affordable":
            extra = sum(float(v) for v in changes.values()) - inc
            result["advice"] = _advice(result["before"], extra, kw["duration"], balance)
        return result
    if kind == "purchase":
        return purchase(m, sc.get("price", 0), sc.get("months", 6), sc.get("monthly_interest", 0), balance)
    if kind == "savings_goal":
        return savings_goal(m, sc.get("extra_per_month", 0))
    raise AffordabilityInputError("scenario.type must be none, monthly_change, purchase or savings_goal")
