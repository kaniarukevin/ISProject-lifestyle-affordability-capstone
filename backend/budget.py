"""Dynamic monthly budget (capstone). Mirrors notebooks/07_dynamic_budget.ipynb.

Layers: commitments set aside exactly; savings of 10% of income (or the goal's monthly amount);
everyday money split half by a Random Forest learned from Stable households like this one and half by the
average Stable split; entertainment trimmed into savings when Strained (25%) or Critical (50%); a category
overspent last month loses half the overspend this month, which goes to savings.
"""
from pathlib import Path

import joblib
import pandas as pd

import affordability as aff
import limits

MODEL_PATH = Path(__file__).resolve().parent / "models" / "budget_split.joblib"
FIXED = ["housing", "loan_repayment", "school_fees", "other_commitments"]
STATES = ("Stable", "Strained", "Critical")
TRIM_FUN = {"Stable": 0.0, "Strained": 0.25, "Critical": 0.50}
# Everyday lines a household may simply not have. With history, one the user never spends on gets no budget
# (found in testing, 1 Nov: every budget had "money sent" even for people who never send money).
OPTIONAL = {"airtime_data": "airtime and data", "mobile_money_transfers": "money sent to others",
            "entertainment": "entertainment"}
_MODEL = {}


class BudgetInputError(ValueError):
    """Raised for requests that cannot be budgeted; the API turns it into a 400."""


def model():
    if "m" not in _MODEL:
        _MODEL["m"] = joblib.load(MODEL_PATH)
    return _MODEL["m"]


def _num(value, name, minimum=0.0):
    try:
        v = float(value)
    except (TypeError, ValueError, OverflowError):
        raise BudgetInputError(f"{name} must be a number")
    if not limits.is_real(v):
        raise BudgetInputError(f"{name} must be a normal amount (at most {limits.MAX_AMOUNT:,})")
    if v < minimum:
        raise BudgetInputError(f"{name} must be at least {minimum:g}")
    return v


def recommend_budget(income, fixed, household_size=1, num_dependants=0, formal_job=False,
                     urban_rural="urban", state="Stable", goal_per_month=0, last_month=None, own_spending=None):
    """own_spending: the household's usual monthly spending per everyday category (from its own records).
    When given, the split is half the model's (households like this one) and half the household's own
    pattern, and optional lines it never uses get nothing."""
    m = model()
    variable = m["variable"]
    notes = []
    fixed = {c: float(fixed.get(c, 0)) for c in FIXED}
    fixed_total = sum(fixed.values())
    savings = max(0.10 * income, goal_per_month)
    everyday = income - fixed_total - savings
    if everyday < 0:
        savings = max(0.0, income - fixed_total)
        everyday = income - fixed_total - savings
        notes.append("Your commitments leave little or nothing for everyday spending; savings reduced to fit.")
    if everyday <= 0:
        notes.append("Your commitments are more than your income. Start by reviewing rent or loan repayments.")
        everyday = 0.0

    x = pd.DataFrame([{"total_income": income, "available": max(0.0, income - fixed_total - savings),
                       "household_size": household_size, "num_dependants": num_dependants,
                       "is_formal": int(bool(formal_job)), "urban": int(urban_rural == "urban"),
                       "peri_urban": int(urban_rural == "peri_urban")}])
    share = 0.5 * m["split_model"].predict(x[m["x_cols"]])[0] + 0.5 * m["one_size"]
    share = pd.Series(share / share.sum(), index=variable)
    own = pd.Series({c: float((own_spending or {}).get(c, 0)) for c in variable})
    if own.sum() > 0:
        share = 0.5 * share + 0.5 * own / own.sum()
        unused = [c for c in OPTIONAL if c in variable and own[c] == 0]
        share[unused] = 0.0
        share = share / share.sum()
        notes.append("Split using your own spending pattern and households like yours.")
        if "mobile_money_transfers" in unused and fixed.get("other_commitments", 0) > 0:
            unused.remove("mobile_money_transfers")
            notes.append("Money you send (chama, family support) is already set aside under your commitments, "
                         "so it has no separate line.")
        if unused:
            notes.append(f"No budget for {', '.join(OPTIONAL[c] for c in unused)}: you have not spent on "
                         f"{'it' if len(unused) == 1 else 'them'}. Record spending there and it comes back.")
    limits = {c: everyday * float(share[c]) for c in variable}

    if TRIM_FUN[state] > 0 and limits.get("entertainment", 0) > 0:
        trim = limits["entertainment"] * TRIM_FUN[state]
        limits["entertainment"] -= trim
        savings += trim
        notes.append(f"Because things are {state.lower()}, entertainment is KES {round(trim):,} lower "
                     "and that goes to savings to rebuild your buffer.")

    if last_month:
        spent, prev = last_month.get("spent") or {}, last_month.get("limits") or {}
        for c in variable:
            if c in spent and c in prev:
                over = _num(spent[c], f"last_month.spent.{c}") - _num(prev[c], f"last_month.limits.{c}")
                if over > 0:
                    cut = min(0.5 * over, limits[c])
                    limits[c] -= cut
                    savings += cut
                    notes.append(f"You went KES {round(over):,} over on {c} last month, so this month's limit "
                                 f"is KES {round(cut):,} lower and that goes to savings.")

    budget = {**{c: round(v) for c, v in fixed.items()}, **{c: round(v) for c, v in limits.items()}}
    # Savings takes whatever rounding leaves, so the budget always adds up to the income exactly.
    budget["savings"] = round(income) - sum(budget.values()) if everyday > 0 else round(savings)
    return {"income": round(income), "state": state, "budget": budget, "total": sum(budget.values()),
            "notes": notes}


def evaluate(payload):
    """Entry point for POST /budget. The state comes from 'months' if given, else from 'state' (default Stable)."""
    if not isinstance(payload, dict):
        raise BudgetInputError("request body must be a JSON object")
    hh = payload.get("household") or {}
    size = _num(hh.get("household_size", 1), "household_size", 1)
    deps = _num(hh.get("num_dependants", 0), "num_dependants")
    urban_rural = hh.get("urban_rural", "urban")
    if urban_rural not in ("urban", "peri_urban", "rural"):
        raise BudgetInputError("urban_rural must be urban, peri_urban or rural")
    income = _num(payload.get("income"), "income")
    if income <= 0:
        raise BudgetInputError("income must be more than 0")
    fixed = payload.get("fixed") or {}
    if not isinstance(fixed, dict) or any(k not in FIXED for k in fixed):
        raise BudgetInputError("fixed may only contain housing, loan_repayment, school_fees and other_commitments")
    fixed = {k: _num(v, k) for k, v in fixed.items()}
    goal = _num(payload.get("goal_per_month", 0), "goal_per_month")
    own = payload.get("own_spending") or {}
    if not isinstance(own, dict):
        raise BudgetInputError("own_spending must be an object of category amounts")
    own = {k: _num(v, f"own_spending.{k}") for k, v in own.items()}

    if payload.get("months"):
        try:
            frame = aff.months_frame(payload["months"], size, deps)
        except aff.AffordabilityInputError as exc:
            raise BudgetInputError(str(exc))
        state = aff._state(aff.build_features(frame).iloc[[-1]], bool(payload.get("statement_safe")))
    else:
        state = payload.get("state", "Stable")
        if state not in STATES:
            raise BudgetInputError("state must be Stable, Strained or Critical")
    return recommend_budget(income, fixed, size, deps, hh.get("formal_job", False), urban_rural, state,
                            goal, payload.get("last_month"), own)
