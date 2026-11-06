"""Lifestyle affordability engine (capstone). Mirrors notebooks/06_affordability.ipynb.

The app sends the household's own monthly figures (it does not look up a staging userId),
so this works for any household, including students. All amounts are KES per month.
"""
import math
from pathlib import Path

import joblib
import numpy as np
import pandas as pd

import limits

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


def _real(v, name):
    """A number from a request: refuses text, NaN, Infinity and absurd sizes (audit A-01)."""
    try:
        x = float(v)
    except (TypeError, ValueError, OverflowError):
        raise AffordabilityInputError(f"{name} must be a number")
    if not limits.is_real(x):
        raise AffordabilityInputError(f"{name} must be a normal amount (at most {limits.MAX_AMOUNT:,})")
    return x


def _changes(changes):
    if not isinstance(changes, dict):
        raise AffordabilityInputError("changes must be an object of categories and monthly amounts")
    return {c: _real(v, f"changes.{c}") for c, v in changes.items()}


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
            v = _real(mth.get(c, 0) or 0, c)
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


def _score_rows(X):
    """The score for many rows at once (same formula as _score)."""
    e = engine()
    ps = e["p_stable_model"].predict_proba(X)[:, 1]
    pok = np.maximum(e["p_ok_model"].predict_proba(X)[:, 1], ps)
    return 100 * (ps + pok) / 2


# ---------- why this score (SHAP, proposal 3.5.7) ----------
# The 14 score features in six groups a user can understand. Shapley values are computed exactly over the groups
# (2^6 = 64 coalitions), so no sampling and no extra library: the contributions add up to the score exactly.
SCORE_GROUPS = [
    ("income", "Your income", ["total_income", "zero_income_flag"]),
    ("latest_month", "Spending against income, latest month",
     ["total_expenditure", "income_to_expenditure_ratio", "overspend_flag"]),
    ("recent_months", "The last 3 to 6 months", ["ratio_roll3", "overspend_roll3", "exp_roll3", "exp_roll6"]),
    ("saving", "How much of your income you save", ["savings_rate"]),
    ("debt", "Loan repayments", ["debt_service_coverage_ratio"]),
    ("household", "Household size and dependants", ["household_size", "num_dependants", "dependant_cost_factor"]),
]


def shapley(x, background, groups, value=None):
    """Exact interventional Shapley values of value(rows) for one row x, with features grouped.

    x: 1-D array of features; background: 2-D array (reference rows); groups: list of lists of column positions.
    A coalition S keeps x's values for the groups in S and takes the background's values for the rest; v(S) is
    the mean output over the background. Returns (v(empty), contributions), and v(empty) + sum = value(x)."""
    value = value or _score_rows
    k, n = len(groups), len(background)
    masks = np.array([[(s >> g) & 1 for g in range(k)] for s in range(2 ** k)], dtype=bool)
    rows = np.repeat(background[None, :, :], 2 ** k, axis=0)
    for s, mask in enumerate(masks):
        for g in np.flatnonzero(mask):
            rows[s][:, groups[g]] = x[groups[g]]
    v = value(rows.reshape(-1, background.shape[1])).reshape(2 ** k, n).mean(axis=1)
    sizes = masks.sum(axis=1)
    phi = np.zeros(k)
    for g in range(k):
        without = ~masks[:, g]
        s = np.flatnonzero(without)
        weight = np.array([math.factorial(sizes[i]) * math.factorial(k - sizes[i] - 1) for i in s]) / math.factorial(k)
        phi[g] = np.sum(weight * (v[s + (1 << g)] - v[s]))
    return float(v[0]), phi


def explain(f):
    """Why the score is what it is: each group's contribution in score points, against a typical household.

    f: the one-row feature frame used for the score. Returns None if the engine has no background stored."""
    e = engine()
    if "score_background" not in e:
        return None
    cols = e["score_features"]
    bg = e["score_background"]
    X = f[cols].to_numpy(dtype=float)[0]
    groups = [[cols.index(c) for c in feats] for _, _, feats in SCORE_GROUPS]
    frame = lambda a: pd.DataFrame(a, columns=cols)
    base, phi = shapley(X, bg, groups, value=lambda a: _score_rows(frame(a)))
    parts = [{"key": key, "label": label, "points": round(float(p), 1)} for (key, label, _), p in zip(SCORE_GROUPS, phi)]
    parts.sort(key=lambda p: -abs(p["points"]))
    return {"typical_score": round(base), "score": round(base + float(phi.sum())), "parts": parts}


def _state(f, exact=False):
    """Financial state. exact=True uses the statement-safe model, trained only on figures an M-PESA statement gives
    exactly (totals, income, savings, loans): used when much spending is unsorted, because a wrong category split
    changed the main model's answer for 27 of 60 held-out households and the safe model's for 0
    (scripts/train_statement_safe_state.py)."""
    e = engine()
    if exact and "state_model_exact" in e:
        return str(e["state_model_exact"].predict(f[e["state_features_exact"]])[0])
    return str(e["state_model"].predict(f[e["state_features"]])[0])


def timeline(months, household_size, num_dependants, exact=False):
    """State and score for every month, each using only the months up to it, in ONE pass. The features look only
    backwards (rolling windows, running mean and spread), so row i of build_features(all months) equals the last
    row of build_features(months[:i+1]); scoring all rows at once replaces 12 separate evaluations (the
    dashboard's slowest part: about 0.5 s of 0.53 s, measured 5 Nov). tests/test_affordability.py checks it
    matches the month-by-month answer exactly."""
    e = engine()
    f = build_features(months_frame(months, household_size, num_dependants))
    scores = _score_rows(f[e["score_features"]])
    model, feats = ((e["state_model_exact"], e["state_features_exact"]) if exact and "state_model_exact" in e
                    else (e["state_model"], e["state_features"]))
    states = model.predict(f[feats])
    return [{"state": str(st), "score": int(round(float(sc)))} for st, sc in zip(states, scores)]


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


FRAGILE_MONTHS = 3      # months in the last 12 with spending above income that make a year "fragile"
YEAR_MARGIN = 0.10      # the safe margin: the budget's 10% saving rate


def track_record(m):
    """How the last 12 months went, straight from the figures: months where spending (before savings) was more
    than the money that came in. The score only sees the last 3 to 6 months, and the training labels do too
    (adding 12-month history changed held-out accuracy from 0.728 to 0.735; docs/experiments.md, 5 Nov), so a
    year of overspending followed by three calm months scored 100. This makes that history visible."""
    last = m.sort_values("month").tail(12)
    spent = last[[c for c in CATS if c != "savings"]].sum(axis=1)
    income = last[INCOME].sum(axis=1)
    over = int((spent > income).sum())
    return {"months": int(len(last)), "overspent_months": over, "fragile": over >= FRAGILE_MONTHS,
            # The average month over the whole year (calm and bad months together): income and what was left.
            "year_income_KES": round(float(income.mean())), "year_left_KES": round(float((income - spent).mean()))}


def assess(m, changes=None, income_change=0.0, duration=None, savings_balance=0.0, debt_label="Loan repayments",
           state_exact=False, track=True):
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
    record = track_record(m)
    record["lowered_verdict"] = False
    if track and record["fragile"] and verdict == "Affordable":
        # The score judges recent months; a fragile year asks whether the cost still fits the AVERAGE month of the
        # year (calm and bad months together) with the budget's 10% margin left. A first version lowered every
        # Affordable answer in a fragile year, whatever the amount (found on the developer's data, 5 Nov: KES 2,500
        # of family support, with KES 16,000 left a month, came back Stretch), so the amount now matters.
        cost = sum(float(v) for v in (changes or {}).values()) - float(income_change or 0)
        left_after = record["year_left_KES"] - cost
        record["year_left_after_KES"] = round(left_after)
        bad = f"you spent more than came in during {record['overspent_months']} of the last {record['months']} months"
        if left_after < YEAR_MARGIN * record["year_income_KES"]:
            verdict = "Stretch"
            record["lowered_verdict"] = True
            reasons.append(f"Your recent months make this look affordable, but {bad}. Across the whole year your "
                           f"average month would leave only KES {max(0, round(left_after)):,} after this, less than "
                           f"the 10% of income the budget keeps as a margin, so treat it as a stretch.")
        else:
            reasons.append(f"A caution: {bad}. Even so, across the whole year your average month would still leave "
                           f"about KES {round(left_after):,} after this.")
    return {"score_before": round(sb), "score_after": round(sa), "verdict": verdict, "track_record": record,
            "state_now": _state(bf, state_exact), "before": b, "after": a, "reasons": reasons,
            "savings_balance_KES": balance, "lasts_months": int(duration) if duration else None,
            # A short cost scores the months you pay, not your finances for good (found walking through the app:
            # a one-month repair showed "score 54 -> 2" with no explanation).
            "score_note": (f"The score after is for the {int(duration)} month(s) you pay; it recovers once paid."
                           if duration else None)}


def what_to_cut(m, changes=None, income_change=0.0, **kw):
    """Smallest equal % cut to flexible spending to (1) stop being short, (2) reach Affordable."""
    kw.pop("state_exact", None)
    typical = m.sort_values("month").tail(3)[FLEXIBLE].mean()
    break_even = comfortable = None
    for pct in range(5, 55, 5):
        combined = dict(changes or {})
        cuts = {c: round(float(typical[c]) * pct / 100) for c in FLEXIBLE}
        for c, v in cuts.items():
            combined[c] = combined.get(c, 0) - v
        r = assess(m, combined, income_change, track=False, **kw)
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


def purchase(m, price, months=6, monthly_interest=0.0, savings_balance=0.0, state_exact=False):
    """A purchase paid over `months` months (1 = pay it all now). The cost lasts only those months, the savings
    balance can cover a temporary gap, and the answer says what happens month by month."""
    price, months, r = _real(price, "price"), int(_real(months, "months")), _real(monthly_interest, "monthly_interest")
    if price <= 0 or months < 1 or r < 0:
        raise AffordabilityInputError("price must be positive, months at least 1, interest not negative")
    balance = max(0.0, float(savings_balance or 0))
    per_month = price * r / (1 - (1 + r) ** -months) if r > 0 else price / months
    kw = {"duration": months, "savings_balance": balance,
          # a single payment is not a loan; instalments are reported together with existing loans
          "debt_label": None if months == 1 else "These instalments and your loans"}
    result = assess(m, {"loan_repayment": per_month}, state_exact=state_exact, **kw)
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
    if result["verdict"] != "Affordable" and not result["track_record"]["lowered_verdict"]:
        result["what_to_cut"] = what_to_cut(m, {"loan_repayment": per_month}, **kw)
    if result["verdict"] == "Not affordable":
        result["advice"] = _advice(result["before"], per_month, months, balance)
    if result["months_to_save_up_first"] is None:
        result["months_to_save_up_first"] = "Not possible yet: nothing is left over each month."
    return result


RANK = {"Affordable": 2, "Stretch": 1, "Not affordable": 0}


def plan(m, sc, savings_balance=0.0, state_exact=False):
    """One check for a whole decision (6 Nov): most real choices are an upfront cost AND a monthly change, e.g.
    moving (deposit, then rent), a car (loan, then fuel and insurance), a boda boda (loan, then fuel, and money it
    brings in). sc: {"changes": {category: KES a month}, "income_change": KES a month (money it brings in, or
    less pay), "months": how long the monthly part lasts (None = for good), "upfront": {"price", "pay": "savings" |
    "instalments", "months", "monthly_interest"}}.
    With instalments there are two periods: while paying (monthly part + instalment) and after (monthly part only).
    Each is checked with the same engine and the answer is the harder of the two; both are reported. Paid from
    savings, the upfront cost comes out of the savings balance first, so the safety rule uses what is left."""
    changes = _changes(sc.get("changes") or {})
    inc = _real(sc.get("income_change", 0) or 0, "income_change")
    lasts = sc.get("months")
    if lasts is not None:
        lasts = int(_real(lasts, "months"))
        if lasts < 1:
            raise AffordabilityInputError("months must be at least 1 (leave it out for a lasting change)")
    up = sc.get("upfront") or None
    balance = max(0.0, _real(savings_balance or 0, "savings_balance"))
    per_month, n, price, notes = 0.0, None, 0.0, []
    if up:
        price = _real(up.get("price", 0), "upfront price")
        if price <= 0:
            raise AffordabilityInputError("the upfront cost must be more than 0")
        if up.get("pay") == "instalments":
            n = int(_real(up.get("months", 6), "upfront months"))
            r = _real(up.get("monthly_interest", 0), "monthly_interest")
            if n < 1 or r < 0:
                raise AffordabilityInputError("instalments need at least 1 month and interest that is not negative")
            per_month = price * r / (1 - (1 + r) ** -n) if r > 0 else price / n
        else:
            if price > balance:
                short = round(price - balance)
                out = {"verdict": "Not affordable", "score_before": None, "score_after": None, "phases": [],
                       "reasons": [f"The upfront KES {round(price):,} is more than your savings of KES "
                                   f"{round(balance):,}: you would need KES {short:,} more, or pay it in instalments."],
                       "upfront_KES": round(price), "savings_balance_KES": round(balance), "upfront_short_KES": short}
                return out
            balance -= price
            notes.append(f"Paying KES {round(price):,} upfront from savings leaves KES {round(balance):,} saved.")
    has_monthly = bool(changes) or inc != 0
    phases = []
    if per_month:
        paying = dict(changes)
        paying["loan_repayment"] = paying.get("loan_repayment", 0.0) + per_month
        # While paying: the instalments last n months (or less, if the whole change is shorter).
        dur = min(n, lasts) if lasts else n
        phases.append(("While you pay the instalments", f"{n} month(s)",
                       assess(m, paying, inc, duration=dur, savings_balance=balance, state_exact=state_exact,
                              debt_label="These instalments and your loans")))
        if has_monthly and (lasts is None or lasts > n):
            phases.append(("After the instalments", "for good" if lasts is None else f"{lasts - n} month(s)",
                           assess(m, changes, inc, duration=(lasts - n) if lasts else None, savings_balance=balance,
                                  state_exact=state_exact)))
    elif has_monthly:
        phases.append(("Each month", "for good" if lasts is None else f"{lasts} month(s)",
                       assess(m, changes, inc, duration=lasts, savings_balance=balance, state_exact=state_exact)))
    else:                                            # only an upfront cost, paid from savings
        phases.append(("After paying upfront", "now", assess(m, {}, 0.0, savings_balance=balance,
                                                             state_exact=state_exact)))
    worst = min(phases, key=lambda ph: (RANK[ph[2]["verdict"]], ph[2]["score_after"]))[2]
    result = dict(worst)
    result["reasons"] = notes + list(worst["reasons"])
    result["phases"] = [{"label": label, "lasts": span, "verdict": r["verdict"], "score_after": r["score_after"],
                         "left_over_KES": r["after"]["left_over_KES"]} for label, span, r in phases]
    if per_month:
        result.update({"instalment_per_month_KES": round(per_month), "total_paid_KES": round(per_month * n),
                       "instalment_months": n})
    if up:
        result["upfront_KES"] = round(price)
    if len(phases) > 1:
        a, b = result["phases"]
        result["reasons"].insert(0, f"{a['label']} ({a['lasts']}): {a['verdict']}, score {a['score_after']}. "
                                    f"{b['label']} ({b['lasts']}): {b['verdict']}, score {b['score_after']}.")
    worst_changes = dict(changes)
    if per_month and worst is phases[0][2]:
        worst_changes["loan_repayment"] = worst_changes.get("loan_repayment", 0.0) + per_month
    kw = {"duration": worst.get("lasts_months"), "savings_balance": balance}
    if result["verdict"] != "Affordable" and not result["track_record"]["lowered_verdict"]:
        result["what_to_cut"] = what_to_cut(m, worst_changes, inc, **kw)
    if result["verdict"] == "Not affordable":
        extra = sum(worst_changes.values()) - inc
        result["advice"] = _advice(result["before"], extra, kw["duration"], balance)
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


def explain_request(payload):
    """'Why this score?' for an /affordability request: the current score explained, and for a scenario the score
    after it, plus how much each part moved (after minus before). Same inputs as evaluate()."""
    hh = (payload or {}).get("household") or {}
    m = months_frame(payload.get("months"), _real(hh.get("household_size", 1), "household_size"),
                     _real(hh.get("num_dependants", 0), "num_dependants"))
    sc = payload.get("scenario") or {"type": "none"}
    kind = sc.get("type", "none")
    changes, inc, span = None, 0.0, 3
    if kind == "monthly_change":
        changes, inc = _changes(sc.get("changes") or {}), _real(sc.get("income_change", 0) or 0, "income_change")
        span = min(int(_real(sc["months"], "months")), 3) if sc.get("months") else 3
    elif kind == "purchase":
        price, n = _real(sc.get("price", 0), "price"), int(_real(sc.get("months", 6), "months"))
        r = _real(sc.get("monthly_interest", 0), "monthly_interest")
        if price <= 0 or n < 1 or r < 0:
            raise AffordabilityInputError("price must be positive, months at least 1, interest not negative")
        changes, span = {"loan_repayment": price * r / (1 - (1 + r) ** -n) if r > 0 else price / n}, min(n, 3)
    elif kind == "plan":
        changes = _changes(sc.get("changes") or {})
        inc = _real(sc.get("income_change", 0) or 0, "income_change")
        up = sc.get("upfront") or {}
        if up.get("pay") == "instalments":
            price, n = _real(up.get("price", 0), "upfront price"), int(_real(up.get("months", 6), "upfront months"))
            r = _real(up.get("monthly_interest", 0), "monthly_interest")
            if price > 0 and n >= 1:
                per = price * r / (1 - (1 + r) ** -n) if r > 0 else price / n
                changes["loan_repayment"] = changes.get("loan_repayment", 0.0) + per
                span = min(n, 3)
        if sc.get("months"):
            span = min(span, int(_real(sc["months"], "months")))
    elif kind != "none":
        raise AffordabilityInputError("only the current score, monthly changes, purchases and plans have a score to explain")
    now = explain(build_features(m).iloc[[-1]])
    out = {"now": now, "track_record": track_record(m)}
    if changes is not None and now is not None:
        after = explain(build_features(_apply(m, changes, inc, months=span)).iloc[[-1]])
        moved = {p["key"]: p["points"] for p in after["parts"]}
        for p in now["parts"]:
            moved[p["key"]] = round(moved[p["key"]] - p["points"], 1)
        out["after"] = after
        out["moved"] = sorted(({"key": k, "label": next(lb for kk, lb, _ in SCORE_GROUPS if kk == k), "points": v}
                               for k, v in moved.items()), key=lambda p: -abs(p["points"]))
    return out


def evaluate(payload):
    """Entry point for POST /affordability."""
    if not isinstance(payload, dict):
        raise AffordabilityInputError("request body must be a JSON object")
    hh = payload.get("household") or {}
    size, deps = _real(hh.get("household_size", 1), "household_size"), _real(hh.get("num_dependants", 0), "num_dependants")
    if size < 1 or deps < 0:
        raise AffordabilityInputError("household_size must be at least 1 and num_dependants not negative")
    m = months_frame(payload.get("months"), size, deps)
    balance = _real(payload.get("savings_balance", 0) or 0, "savings_balance")
    if balance < 0:
        raise AffordabilityInputError("savings_balance cannot be negative")
    sc = payload.get("scenario") or {"type": "none"}
    kind = sc.get("type", "none")
    exact = bool(payload.get("statement_safe"))
    if kind == "none":
        return assess(m, state_exact=exact)
    if kind == "monthly_change":
        changes, inc = _changes(sc.get("changes") or {}), _real(sc.get("income_change", 0) or 0, "income_change")
        lasts = sc.get("months")                         # None = for good; a number = a temporary change
        if lasts is not None and (not limits.is_real(lasts) or lasts < 1):
            raise AffordabilityInputError("scenario.months must be at least 1 (leave it out for a lasting change)")
        kw = {"duration": int(lasts) if lasts else None, "savings_balance": balance}
        result = assess(m, changes, inc, state_exact=exact, **kw)
        if result["verdict"] != "Affordable" and not result["track_record"]["lowered_verdict"]:
            result["what_to_cut"] = what_to_cut(m, changes, inc, **kw)
        if result["verdict"] == "Not affordable":
            extra = sum(float(v) for v in changes.values()) - inc
            result["advice"] = _advice(result["before"], extra, kw["duration"], balance)
        return result
    if kind == "purchase":
        return purchase(m, sc.get("price", 0), sc.get("months", 6), sc.get("monthly_interest", 0), balance, exact)
    if kind == "savings_goal":
        return savings_goal(m, _real(sc.get("extra_per_month", 0), "extra_per_month"))
    if kind == "plan":
        return plan(m, sc, balance, exact)
    raise AffordabilityInputError("scenario.type must be none, monthly_change, purchase, savings_goal or plan")
