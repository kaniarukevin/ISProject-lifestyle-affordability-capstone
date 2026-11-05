"""Commitments: obligations, debts and goals (capstone).

Turns what a household owes and plans into monthly figures the budget and the affordability engine use:
- obligations with real timing (school fees per term, insurance per year) become monthly equivalents;
- debts get a month-by-month payoff plan: debt-free date, total interest, and what extra payments save,
  paying the most expensive debt first (avalanche) or the smallest first (snowball);
- goals with deadlines become a monthly saving amount.
Plain arithmetic, no model: every number can be checked by hand.
"""
from datetime import date

FREQ_PER_YEAR = {"weekly": 52, "monthly": 12, "quarterly": 4, "termly": 3, "semester": 2, "yearly": 1}
STEP_MONTHS = {"monthly": 1, "quarterly": 3, "termly": 4, "semester": 6, "yearly": 12}   # termly: Jan, May, Sep
DUE_SOON_DAYS = 7
OBLIGATION_CATEGORIES = ("housing", "school_fees", "other_commitments")
STRATEGIES = ("avalanche", "snowball")
MAX_MONTHS = 600


class CommitmentsInputError(ValueError):
    """Raised for requests that cannot be processed; the API turns it into a 400."""


def _num(value, name, minimum=0.0):
    try:
        v = float(value)
    except (TypeError, ValueError):
        raise CommitmentsInputError(f"{name} must be a number")
    if v < minimum:
        raise CommitmentsInputError(f"{name} must be at least {minimum:g}")
    return v


def monthly_equivalent(amount, frequency):
    """KES per month for an amount paid at the given frequency (termly = 3 school terms a year)."""
    if frequency not in FREQ_PER_YEAR:
        raise CommitmentsInputError(f"frequency must be one of {', '.join(FREQ_PER_YEAR)}")
    return amount * FREQ_PER_YEAR[frequency] / 12


def month_label(months_from_now, today=None):
    today = today or date.today()
    y, m = divmod(today.month - 1 + months_from_now, 12)
    return f"{today.year + y}-{m + 1:02d}"


def simulate_debts(debts, extra=0.0, strategy="avalanche"):
    """Month-by-month payoff. Each debt gets its minimum payment; the extra amount, plus minimums freed when
    a debt is cleared, goes to the target debt: highest interest rate first (avalanche) or smallest balance
    first (snowball). Returns the month each debt is cleared (None if not within 50 years) and interest paid."""
    n = len(debts)
    bal = [d["balance"] for d in debts]
    rate = [d["annual_rate"] / 100 / 12 for d in debts]
    mins = [d["monthly_payment"] for d in debts]
    interest, cleared = [0.0] * n, [None] * n
    monthly_pot = sum(mins) + extra
    for month in range(1, MAX_MONTHS + 1):
        if all(b <= 0.005 for b in bal):
            break
        for i in range(n):
            if bal[i] > 0.005:
                it = bal[i] * rate[i]
                bal[i] += it
                interest[i] += it
        pot = monthly_pot
        for i in range(n):
            if bal[i] > 0.005:
                p = min(mins[i], bal[i], pot)
                bal[i] -= p
                pot -= p
        live = [i for i in range(n) if bal[i] > 0.005]
        order = sorted(live, key=(lambda i: -rate[i]) if strategy == "avalanche" else (lambda i: bal[i]))
        for i in order:
            if pot <= 0:
                break
            p = min(pot, bal[i])
            bal[i] -= p
            pot -= p
        for i in range(n):
            if cleared[i] is None and bal[i] <= 0.005:
                cleared[i] = month
    return cleared, interest


def _debt_plan(debts, extra, strategy):
    cleared, interest = simulate_debts(debts, extra, strategy)
    rows = [{"name": d["name"], "cleared_in_months": c, "cleared_by": month_label(c) if c else None,
             "interest_KES": round(i)} for d, c, i in zip(debts, cleared, interest)]
    done = all(c is not None for c in cleared)
    months = max(cleared) if done else None
    return {"debts": rows, "debt_free_in_months": months, "debt_free_by": month_label(months) if done else None,
            "total_interest_KES": round(sum(interest))}


def _date(value, name):
    try:
        return date.fromisoformat(str(value))
    except ValueError:
        raise CommitmentsInputError(f"{name} must look like 2026-12-05")


def next_due_after(due, frequency):
    """The following due date after a payment: a week, or 1, 3, 4, 6 or 12 months later (same day of the month,
    or the month's last day when it is shorter)."""
    import calendar
    from datetime import timedelta
    if frequency == "weekly":
        return due + timedelta(days=7)
    n = due.month - 1 + STEP_MONTHS[frequency]
    y, m = due.year + n // 12, n % 12 + 1
    return date(y, m, min(due.day, calendar.monthrange(y, m)[1]))


def due_status(due, today):
    """('overdue' | 'due_soon' | 'later', days until due; negative when late)."""
    days = (due - today).days
    return ("overdue" if days < 0 else "due_soon" if days <= DUE_SOON_DAYS else "later"), days


def months_until(deadline, today):
    """Months left to save for a goal due in month 'YYYY-MM' (at least 1: this month still counts)."""
    try:
        y, m = int(str(deadline)[:4]), int(str(deadline)[5:7])
    except ValueError:
        raise CommitmentsInputError("goal deadline must look like 2027-03")
    return max(1, (y * 12 + m) - (today.year * 12 + today.month))


def _validate_list(payload, key):
    items = payload.get(key) or []
    if not isinstance(items, list):
        raise CommitmentsInputError(f"{key} must be a list")
    for it in items:
        if not isinstance(it, dict):
            raise CommitmentsInputError(f"each item in {key} must be an object")
    return items


def evaluate(payload, today=None):
    """Entry point for POST /commitments. today: for due dates and goal deadlines (tests pass a fixed date)."""
    if not isinstance(payload, dict):
        raise CommitmentsInputError("request body must be a JSON object")
    today = today or date.today()

    obligations = []
    for o in _validate_list(payload, "obligations"):
        cat = o.get("category", "other_commitments")
        if cat not in OBLIGATION_CATEGORIES:
            raise CommitmentsInputError(f"obligation category must be one of {', '.join(OBLIGATION_CATEGORIES)}")
        amount = _num(o.get("amount"), "obligation amount")
        freq = o.get("frequency", "monthly")
        row = {"name": str(o.get("name", cat)), "category": cat, "frequency": freq, "amount_KES": round(amount),
               "monthly_equivalent_KES": round(monthly_equivalent(amount, freq))}
        if o.get("next_due"):               # optional: the date the next payment is due
            due = _date(o["next_due"], "next_due")
            row["next_due"] = due.isoformat()
            row["status"], row["due_in_days"] = due_status(due, today)
        if o.get("last_paid"):
            row["last_paid"] = str(o["last_paid"])
        obligations.append(row)

    debts = []
    for d in _validate_list(payload, "debts"):
        debts.append({"name": str(d.get("name", "debt")),
                      "balance": _num(d.get("balance"), "debt balance"),
                      "annual_rate": _num(d.get("annual_rate", 0), "annual_rate"),
                      "monthly_payment": _num(d.get("monthly_payment"), "monthly_payment")})

    goals, completed = [], []
    for g in _validate_list(payload, "goals"):
        if g.get("done"):                     # reached: listed, but nothing more is set aside for it
            completed.append({"name": str(g.get("name", "goal")), "done_on": g.get("done_on")})
            continue
        target = _num(g.get("target"), "goal target")
        saved = _num(g.get("saved", 0), "goal saved")
        # A deadline month counts down by itself; months_left alone (goals saved before 5 Nov) does not.
        months = months_until(g["deadline"], today) if g.get("deadline") else _num(g.get("months_left"), "months_left", 1)
        remaining = max(0.0, target - saved)
        goals.append({"name": str(g.get("name", "goal")), "remaining_KES": round(remaining),
                      "months_left": int(months), "monthly_needed_KES": round(remaining / months),
                      **({"deadline": str(g["deadline"])[:7]} if g.get("deadline") else {})})

    extra = _num(payload.get("extra_per_month", 0), "extra_per_month")
    strategy = payload.get("strategy", "avalanche")
    if strategy not in STRATEGIES:
        raise CommitmentsInputError("strategy must be avalanche or snowball")

    result = {"obligations": obligations, "goals": goals, "completed_goals": completed, "warnings": []}

    if debts:
        plan = _debt_plan(debts, 0.0, strategy)
        for d, row in zip(debts, plan["debts"]):
            if row["cleared_in_months"] is None and d["monthly_payment"] <= d["balance"] * d["annual_rate"] / 1200:
                result["warnings"].append(f"{d['name']}: the monthly payment does not even cover the interest, "
                                          "so this debt will never be paid off at this rate.")
        debt_section = {"total_balance_KES": round(sum(d["balance"] for d in debts)),
                        "total_monthly_payment_KES": round(sum(d["monthly_payment"] for d in debts)),
                        "strategy": strategy, "as_planned": plan}
        if extra > 0:
            faster = {s: _debt_plan(debts, extra, s) for s in STRATEGIES}
            chosen = faster[strategy]
            debt_section["with_extra"] = chosen
            if plan["debt_free_in_months"] and chosen["debt_free_in_months"]:
                debt_section["extra_saves"] = {
                    "months": plan["debt_free_in_months"] - chosen["debt_free_in_months"],
                    "interest_KES": plan["total_interest_KES"] - chosen["total_interest_KES"]}
            debt_section["strategy_comparison_interest_KES"] = {s: faster[s]["total_interest_KES"] for s in STRATEGIES}
        result["debts"] = debt_section

    fixed = {c: 0 for c in OBLIGATION_CATEGORIES}
    for o in obligations:
        fixed[o["category"]] += o["monthly_equivalent_KES"]
    fixed["loan_repayment"] = round(sum(d["monthly_payment"] for d in debts) + extra)
    result["for_budget"] = {"fixed": fixed, "goal_per_month": sum(g["monthly_needed_KES"] for g in goals)}
    return result
