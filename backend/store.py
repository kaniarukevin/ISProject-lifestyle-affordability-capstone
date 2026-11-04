"""Data layer (capstone): PostgreSQL in production (Neon), SQLite on a laptop and in tests.

The engines (forecast, affordability, budget, commitments) stay stateless calculators. This module stores
what each user enters and what they decide, behind sign-up/log-in, so the app works across devices and the
dynamic budget can see last month. Connection string comes from DATABASE_URL (never from code).
"""
import copy
import os
import statistics
import threading
import time
from collections import defaultdict, deque
from datetime import date, datetime, timezone
from functools import wraps
from pathlib import Path

from flask import Blueprint, g, jsonify, request
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer
from sqlalchemy import (JSON, Boolean, Date, DateTime, Float, ForeignKey, Integer, String, UniqueConstraint,
                        create_engine, delete, inspect, select, text)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker
from sqlalchemy.pool import StaticPool
from werkzeug.security import check_password_hash, generate_password_hash

import affordability as aff

ROOT = Path(__file__).resolve().parent.parent
TOKEN_DAYS = 30
SPENDING_CATEGORIES = aff.CATS
URBAN_RURAL = ("urban", "peri_urban", "rural")
FREQUENCIES = {"weekly": 52, "monthly": 12, "termly": 3, "semester": 2, "yearly": 1}


def _load_env_files():
    """Read .env.local / .env written by `neon deploy` (local development only; Render sets real env vars)."""
    for name in (".env.local", ".env"):
        p = ROOT / name
        if not p.exists():
            continue
        for line in p.read_text().splitlines():
            line = line.strip()
            if line.startswith("export "):
                line = line[7:]
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def database_url():
    _load_env_files()
    url = os.environ.get("DATABASE_URL") or f"sqlite:///{Path(__file__).resolve().parent / 'local.db'}"
    if url.startswith("postgres://"):
        url = "postgresql://" + url[len("postgres://"):]
    if url.startswith("postgresql://"):
        url = "postgresql+psycopg://" + url[len("postgresql://"):]   # psycopg 3 driver
    return url


# ---------------- tables ----------------

class Base(DeclarativeBase):
    pass


def _now():
    return datetime.now(timezone.utc)


class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String(254), unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(String(255))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class Profile(Base):
    __tablename__ = "profiles"
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    household_size: Mapped[int] = mapped_column(Integer, default=1)
    dependants: Mapped[int] = mapped_column(Integer, default=0)
    urban_rural: Mapped[str] = mapped_column(String(20), default="urban")
    formal_job: Mapped[bool] = mapped_column(Boolean, default=False)
    pays_own_fees: Mapped[bool] = mapped_column(Boolean, default=False)
    savings_balance: Mapped[float] = mapped_column(Float, default=0.0)   # money already saved (M-Shwari, SACCO, bank)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now, onupdate=_now)


class IncomeSource(Base):
    __tablename__ = "income_sources"
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    name: Mapped[str] = mapped_column(String(80))
    amount: Mapped[float] = mapped_column(Float)
    frequency: Mapped[str] = mapped_column(String(20), default="monthly")


class Transaction(Base):
    __tablename__ = "transactions"
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    day: Mapped[date] = mapped_column(Date, index=True)
    amount: Mapped[float] = mapped_column(Float)
    category: Mapped[str] = mapped_column(String(40))
    description: Mapped[str] = mapped_column(String(200), default="")
    source: Mapped[str] = mapped_column(String(20), default="manual")   # manual, mpesa, bank_csv
    # Big, rare payments (a plot, a car deposit, a wedding): shown, but kept out of usual spending,
    # the health score and the forecast. Their ongoing cost (a mortgage) belongs in commitments as a debt.
    one_off: Mapped[bool] = mapped_column(Boolean, default=False)


class Commitments(Base):
    __tablename__ = "commitments"
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    data: Mapped[dict] = mapped_column(JSON)          # the /commitments request: obligations, debts, goals
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now, onupdate=_now)


class Budget(Base):
    __tablename__ = "budgets"
    __table_args__ = (UniqueConstraint("user_id", "year", "month"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    year: Mapped[int] = mapped_column(Integer)
    month: Mapped[int] = mapped_column(Integer)
    data: Mapped[dict] = mapped_column(JSON)          # the /budget result for that month


class Scenario(Base):
    __tablename__ = "scenarios"
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    request: Mapped[dict] = mapped_column(JSON)
    result: Mapped[dict] = mapped_column(JSON)


_DB = {}


def init(url=None):
    """Create the engine and the tables (idempotent). Call once at start-up, or from tests with 'sqlite://'."""
    url = url or database_url()
    if url.startswith("sqlite"):
        kw = {"connect_args": {"check_same_thread": False}}
        if url in ("sqlite://", "sqlite:///:memory:"):
            kw["poolclass"] = StaticPool
        engine = create_engine(url, **kw)
    else:
        # Neon suspends idle databases: check connections before use and recycle them regularly.
        engine = create_engine(url, pool_pre_ping=True, pool_recycle=300, pool_size=5, max_overflow=5)
    Base.metadata.create_all(engine)
    _upgrade(engine)
    _DB["engine"], _DB["Session"] = engine, sessionmaker(engine, expire_on_commit=False)
    return engine


def _upgrade(engine):
    """Small in-place upgrades for tables created by an earlier version (keeps existing data).
    create_all() makes missing tables but never adds columns to existing ones."""
    cols = {c["name"] for c in inspect(engine).get_columns("transactions")}
    if "one_off" not in cols:
        false = "0" if engine.dialect.name == "sqlite" else "FALSE"
        with engine.begin() as conn:
            conn.execute(text(f"ALTER TABLE transactions ADD COLUMN one_off BOOLEAN NOT NULL DEFAULT {false}"))
    if "savings_balance" not in {c["name"] for c in inspect(engine).get_columns("profiles")}:
        with engine.begin() as conn:
            conn.execute(text("ALTER TABLE profiles ADD COLUMN savings_balance FLOAT NOT NULL DEFAULT 0"))


def session():
    if "Session" not in _DB:
        init()
    return _DB["Session"]()


# ---------------- auth ----------------

# ---------------- rate limits (in memory; the service runs one worker) ----------------

_ATTEMPTS = defaultdict(deque)
_ATTEMPTS_LOCK = threading.Lock()


def _client_ip():
    """Render sits behind a proxy, so the caller's address is the first entry of X-Forwarded-For."""
    return request.headers.get("X-Forwarded-For", "").split(",")[0].strip() or request.remote_addr or "unknown"


def _recent(key, window):
    """How many attempts were recorded for key within the last `window` seconds."""
    now = time.monotonic()
    with _ATTEMPTS_LOCK:
        q = _ATTEMPTS[key]
        while q and now - q[0] > window:
            q.popleft()
        return len(q)


def _record(key):
    with _ATTEMPTS_LOCK:
        _ATTEMPTS[key].append(time.monotonic())


def _serializer():
    return URLSafeTimedSerializer(os.environ.get("SECRET_KEY", "dev-only-change-me"), salt="auth")


def login_required(fn):
    @wraps(fn)
    def wrapper(*args, **kwargs):
        header = request.headers.get("Authorization", "")
        token = header[7:] if header.startswith("Bearer ") else ""
        try:
            g.user_id = _serializer().loads(token, max_age=TOKEN_DAYS * 86400)
        except SignatureExpired:
            return jsonify(error="your session has expired, log in again"), 401
        except BadSignature:
            return jsonify(error="log in first"), 401
        return fn(*args, **kwargs)
    return wrapper


class InputError(ValueError):
    pass


def _body():
    b = request.get_json(silent=True)
    if not isinstance(b, dict):
        raise InputError("request body must be a JSON object")
    return b


def _num(v, name, minimum=0.0):
    try:
        x = float(v)
    except (TypeError, ValueError):
        raise InputError(f"{name} must be a number")
    if x < minimum:
        raise InputError(f"{name} must be at least {minimum:g}")
    return x


bp = Blueprint("store", __name__)


@bp.errorhandler(InputError)
def _bad_input(exc):
    return jsonify(error=str(exc)), 400


@bp.post("/auth/register")
def register():
    ip = _client_ip()
    if _recent(("register", ip), 3600) >= 5:
        return jsonify(error="too many new accounts from this network, try again later"), 429
    _record(("register", ip))
    b = _body()
    email = str(b.get("email", "")).strip().lower()
    password = str(b.get("password", ""))
    if "@" not in email or "." not in email.split("@")[-1]:
        raise InputError("enter a valid email address")
    if len(password) < 8:
        raise InputError("password must be at least 8 characters")
    with session() as s:
        if s.scalar(select(User).where(User.email == email)):
            return jsonify(error="an account with this email already exists"), 409
        user = User(email=email, password_hash=generate_password_hash(password))
        s.add(user)
        s.commit()
        return jsonify(token=_serializer().dumps(user.id), user_id=user.id), 201


@bp.post("/auth/login")
def login():
    ip = _client_ip()
    if _recent(("login-ip", ip), 300) >= 20:
        return jsonify(error="too many log-in attempts, wait a few minutes"), 429
    _record(("login-ip", ip))
    b = _body()
    email = str(b.get("email", "")).strip().lower()
    if _recent(("login-fail", email), 900) >= 5:
        return jsonify(error="too many wrong passwords for this account, wait 15 minutes"), 429
    with session() as s:
        user = s.scalar(select(User).where(User.email == email))
        if not user or not check_password_hash(user.password_hash, str(b.get("password", ""))):
            _record(("login-fail", email))
            return jsonify(error="wrong email or password"), 401
        return jsonify(token=_serializer().dumps(user.id), user_id=user.id), 200


# ---------------- profile ----------------

@bp.get("/me/profile")
@login_required
def get_profile():
    with session() as s:
        p = s.get(Profile, g.user_id)
        if p is None:
            return jsonify(error="no profile yet"), 404
        incomes = s.scalars(select(IncomeSource).where(IncomeSource.user_id == g.user_id)).all()
        return jsonify(householdSize=p.household_size, dependants=p.dependants, urbanRural=p.urban_rural,
                       formalJob=p.formal_job, paysOwnFees=p.pays_own_fees,
                       savingsBalance=p.savings_balance or 0.0,
                       incomes=[{"name": i.name, "amount": i.amount, "frequency": i.frequency} for i in incomes])


@bp.put("/me/profile")
@login_required
def put_profile():
    b = _body()
    size = int(_num(b.get("householdSize", 1), "householdSize", 1))
    deps = int(_num(b.get("dependants", 0), "dependants"))
    if deps >= size:
        raise InputError("dependants must be fewer than the household size")
    where = b.get("urbanRural", "urban")
    if where not in URBAN_RURAL:
        raise InputError("urbanRural must be urban, peri_urban or rural")
    incomes = b.get("incomes") or []
    if not isinstance(incomes, list):
        raise InputError("incomes must be a list")
    rows = []
    for i in incomes:
        if not isinstance(i, dict) or i.get("frequency", "monthly") not in FREQUENCIES:
            raise InputError(f"each income needs a name, an amount and a frequency ({', '.join(FREQUENCIES)})")
        rows.append(IncomeSource(user_id=g.user_id, name=str(i.get("name", "Income"))[:80],
                                 amount=_num(i.get("amount"), "income amount"), frequency=i.get("frequency", "monthly")))
    with session() as s:
        p = s.get(Profile, g.user_id) or Profile(user_id=g.user_id)
        p.household_size, p.dependants, p.urban_rural = size, deps, where
        p.formal_job, p.pays_own_fees = bool(b.get("formalJob")), bool(b.get("paysOwnFees"))
        p.savings_balance = _num(b.get("savingsBalance", 0) or 0, "savingsBalance")
        s.add(p)
        s.execute(delete(IncomeSource).where(IncomeSource.user_id == g.user_id))
        s.add_all(rows)
        s.commit()
    return jsonify(saved=True), 200


# ---------------- transactions ----------------

def _tx_json(t):
    return {"id": t.id, "date": t.day.isoformat(), "amount": t.amount, "category": t.category,
            "description": t.description, "source": t.source, "one_off": bool(t.one_off)}


@bp.get("/me/transactions")
@login_required
def list_transactions():
    q = select(Transaction).where(Transaction.user_id == g.user_id).order_by(Transaction.day.desc())
    with session() as s:
        return jsonify(transactions=[_tx_json(t) for t in s.scalars(q).all()])


@bp.post("/me/transactions")
@login_required
def add_transactions():
    """Accepts one transaction or a list (a parsed statement)."""
    b = request.get_json(silent=True)
    items = b if isinstance(b, list) else [b]
    rows = []
    for t in items:
        if not isinstance(t, dict):
            raise InputError("each transaction must be an object")
        if t.get("category") not in SPENDING_CATEGORIES:
            raise InputError(f"category must be one of {', '.join(SPENDING_CATEGORIES)}")
        try:
            day = date.fromisoformat(str(t.get("date")))
        except ValueError:
            raise InputError("date must look like 2026-10-29")
        rows.append(Transaction(user_id=g.user_id, day=day, amount=_num(t.get("amount"), "amount"),
                                category=t["category"], description=str(t.get("description", ""))[:200],
                                source=str(t.get("source", "manual"))[:20], one_off=bool(t.get("one_off", False))))
    with session() as s:
        s.add_all(rows)
        s.commit()
        return jsonify(added=len(rows), transactions=[_tx_json(t) for t in rows]), 201


@bp.delete("/me/transactions/<int:tx_id>")
@login_required
def delete_transaction(tx_id):
    with session() as s:
        n = s.execute(delete(Transaction).where(Transaction.id == tx_id, Transaction.user_id == g.user_id)).rowcount
        s.commit()
    return (jsonify(deleted=True), 200) if n else (jsonify(error="not found"), 404)


def _user_months(s, user_id):
    """Spending per category per month (oldest first), with monthly income from the profile."""
    txs = s.scalars(select(Transaction).where(Transaction.user_id == user_id)).all()
    incomes = s.scalars(select(IncomeSource).where(IncomeSource.user_id == user_id)).all()
    income = sum(i.amount * FREQUENCIES[i.frequency] / 12 for i in incomes)
    by_month, one_offs = {}, {}
    for t in txs:
        key = (t.day.year, t.day.month)
        if t.one_off:
            one_offs[key] = one_offs.get(key, 0.0) + t.amount
            continue
        m = by_month.setdefault(key, {c: 0.0 for c in SPENDING_CATEGORIES})
        m[t.category] += t.amount
    months = [{"year": y, "month": mo, **cats, "income_primary": round(income, 2)}
              for (y, mo), cats in sorted(by_month.items())]
    return months, income, one_offs


@bp.get("/me/months")
@login_required
def monthly_summary():
    """Exactly the 'months' list the /affordability and /budget engines take."""
    with session() as s:
        months, _, _ = _user_months(s, g.user_id)
    return jsonify(months=months)


def _saved_budget(s, user_id, year, month):
    b = s.scalar(select(Budget).where(Budget.user_id == user_id, Budget.year == year, Budget.month == month))
    lines = (b.data or {}).get("budget") if b else None
    return {c: float(lines.get(c, 0)) for c in SPENDING_CATEGORIES} if isinstance(lines, dict) else None


def _today():
    return date.today()


def forecast_for_user(s, user_id, months, target_year, target_month):
    """The user's own forecast. The total is the median of monthly totals (robust to one wild month, the
    method that won the experiments, docs/experiments.md); it is split by the household's average share per
    category. A per-category median is NOT used: most people skip some categories in some months, so the
    median of each category is often 0 and the forecast collapsed to KES 0 (found in testing, 1 Nov).
    With a saved budget for the month: 0.75 x budget + 0.25 x usual; with only last month's budget: the same
    with that. The boosted-tree split is not used: it was trained on the 17 staging categories, not these 10."""
    hist = months[-12:]
    totals = [sum(m[c] for c in SPENDING_CATEGORIES) for m in hist]
    usual_total = statistics.median(totals)
    shares = {c: sum(m[c] / t for m, t in zip(hist, totals) if t > 0) / len(hist) for c in SPENDING_CATEGORIES}
    norm = sum(shares.values()) or 1.0
    usual = {c: usual_total * shares[c] / norm for c in SPENDING_CATEGORIES}
    py, pm = (target_year, target_month - 1) if target_month > 1 else (target_year - 1, 12)
    this_budget = _saved_budget(s, user_id, target_year, target_month)
    last_budget = _saved_budget(s, user_id, py, pm)
    if this_budget:
        split, method = {c: 0.75 * this_budget[c] + 0.25 * usual[c] for c in SPENDING_CATEGORIES}, "blend_budget_median"
    elif last_budget:
        split, method = {c: 0.75 * last_budget[c] + 0.25 * usual[c] for c in SPENDING_CATEGORIES}, "blend_last_budget_median"
    else:
        split, method = usual, "trailing_median"
    breakdown = {c: round(v) for c, v in split.items() if round(v) > 0}
    return {"year": target_year, "month": target_month, "total": sum(breakdown.values()),
            "breakdown": breakdown, "method": method, "months_used": len(hist)}


def household_picture(s, user_id):
    """ONE view of the household that the dashboard, the budget and 'Can I afford it?' all use, so their numbers
    agree (found in testing, 1 Nov: each screen built its own and they disagreed).
      months    every recorded month, oldest first (one-off purchases kept out)
      complete  months before the current calendar month; the month in progress is never scored (it looks cheap)
      current   the month in progress, or None
      scored    the last 12 completed months (or what exists) with commitments counted even if never recorded
                as spending - exactly what the engines score
      fixed, goal_per_month   from the Commitments screen
      savings_balance         money already saved (profile)"""
    import commitments as cm
    profile = s.get(Profile, user_id)
    months, income, one_offs = _user_months(s, user_id)
    today = _today()
    cur = (today.year, today.month)
    complete = [mo for mo in months if (mo["year"], mo["month"]) < cur]
    current = next((mo for mo in months if (mo["year"], mo["month"]) == cur), None)
    fixed, goal = {}, 0
    c = s.get(Commitments, user_id)
    if c and c.data:
        summary = cm.evaluate(c.data)
        fixed, goal = dict(summary["for_budget"]["fixed"]), summary["for_budget"]["goal_per_month"]
    scored = [dict(mo) for mo in (complete or months)[-12:]]
    for mo in scored:
        for cat in ("housing", "school_fees", "loan_repayment"):
            mo[cat] = max(mo[cat], float(fixed.get(cat, 0)))
        # chama, insurance, support to family are payments to others; max, not +, so nothing is counted twice
        mo["mobile_money_transfers"] = max(mo["mobile_money_transfers"], float(fixed.get("other_commitments", 0)))
    return {"profile": profile, "income": income, "months": months, "complete": complete, "current": current,
            "one_offs": one_offs, "scored": scored, "fixed": fixed, "goal_per_month": goal, "today": today,
            "savings_balance": float(profile.savings_balance or 0) if profile else 0.0}


SCORE_EXPLAINED = ("Your score (0-100) is how closely your recent months match households that stay on top of "
                   "their money: 56 or more is comfortable, below 33 is at risk. Your state (Stable, Strained or "
                   "Critical) describes your latest month on its own, so the two can differ for a while.")


@bp.get("/me/overview")
@login_required
def overview():
    """Everything the dashboard shows in one call. The current calendar month is still in progress, so it is
    shown as 'so far' and left out of the state and forecast (a half-recorded month looks deceptively cheap)."""
    with session() as s:
        pic = household_picture(s, g.user_id)
        profile, months, income, one_offs = pic["profile"], pic["months"], pic["income"], pic["one_offs"]
        if profile is None:
            return jsonify(error="set up your household first"), 400
        if not months:
            return jsonify(has_data=False, income_monthly=round(income), savings_balance=round(pic["savings_balance"]))
        complete, current = pic["complete"], pic["current"]
        basis = complete or months
        fc = forecast_for_user(s, g.user_id, basis, pic["today"].year, pic["today"].month)
    health = aff.evaluate({"household": {"household_size": profile.household_size,
                                         "num_dependants": profile.dependants},
                           "months": pic["scored"]})
    shown = current or basis[-1]
    spent = {c: round(shown[c]) for c in SPENDING_CATEGORIES if shown[c] > 0}
    total = sum(spent.values())
    notes = []
    if not complete:
        notes.append("You have only recorded spending for this month so far. Your health score and forecast "
                     "become reliable once at least one full month is recorded.")
    elif len(complete) < 3:
        notes.append(f"Based on {len(complete)} full month(s) of records. Add more for a more reliable picture.")
    if fc["total"] > income > 0:
        notes.append(f"This month's spending is expected to be KES {fc['total']:,}, more than your income of "
                     f"KES {round(income):,}.")
    return jsonify(has_data=True, income_monthly=round(income), months_count=len(complete),
                   state=health["state_now"], score=health["score_before"], score_explained=SCORE_EXPLAINED,
                   savings_balance=round(pic["savings_balance"]),
                   latest={"year": shown["year"], "month": shown["month"], "spent": total, "by_category": spent,
                           "left_over": round(income - total), "partial": current is not None,
                           "one_off": round(one_offs.get((shown["year"], shown["month"]), 0))},
                   history=[{"year": m["year"], "month": m["month"],
                             "spent": round(sum(m[c] for c in SPENDING_CATEGORIES))} for m in months[-6:]],
                   forecast=fc, notes=notes)


@bp.get("/me/budget-plan")
@login_required
def budget_plan():
    """This month's dynamic budget, assembled from everything the user has saved: income (profile), commitments
    (rent, fees, debts, goals), health state (completed months), and last month's saved budget and spending
    (overspend rule). Also returns what has been spent so far this month and any budget already saved."""
    import budget as bud
    with session() as s:
        pic = household_picture(s, g.user_id)
        profile, income = pic["profile"], pic["income"]
        if profile is None:
            return jsonify(error="set up your household first"), 400
        y, m = pic["today"].year, pic["today"].month
        py, pm = (y, m - 1) if m > 1 else (y - 1, 12)
        saved_now = s.scalar(select(Budget).where(Budget.user_id == g.user_id, Budget.year == y, Budget.month == m))
        saved_prev = s.scalar(select(Budget).where(Budget.user_id == g.user_id, Budget.year == py, Budget.month == pm))
        saved_now_data = saved_now.data if saved_now else None
        prev_limits = (saved_prev.data or {}).get("budget") if saved_prev else None
    if income <= 0:
        return jsonify(error="add your income in your household profile first"), 400

    notes = []
    fixed, goal = dict(pic["fixed"]), pic["goal_per_month"]
    complete, current = pic["complete"], pic["current"]
    # Rent, fees or loans recorded as spending but not entered as commitments: use the usual amount.
    for cat, label in (("housing", "rent"), ("school_fees", "school fees"), ("loan_repayment", "loan repayments")):
        usual = statistics.median([mo[cat] for mo in complete]) if complete else 0
        if not fixed.get(cat) and usual > 0:
            fixed[cat] = round(usual)
            notes.append(f"Your usual {label} (KES {round(usual):,}) is set aside. Add it under Commitments to make it exact.")

    payload = {"income": income, "fixed": fixed, "goal_per_month": goal,
               "household": {"household_size": profile.household_size, "num_dependants": profile.dependants,
                             "urban_rural": profile.urban_rural, "formal_job": profile.formal_job}}
    if complete:
        payload["months"] = pic["scored"]          # the same months the dashboard and Afford screen score
    else:
        payload["state"] = "Stable"
        notes.append("Your health state is assumed Stable until a full month of spending is recorded.")
    prev_month = next((mo for mo in complete if (mo["year"], mo["month"]) == (py, pm)), None)
    if isinstance(prev_limits, dict) and prev_month:
        payload["last_month"] = {"limits": prev_limits,
                                 "spent": {cat: prev_month[cat] for cat in SPENDING_CATEGORIES if cat in prev_limits}}
    plan = bud.evaluate(payload)
    plan["notes"] = notes + plan["notes"]
    spent = {cat: round(current[cat]) for cat in SPENDING_CATEGORIES if current and current[cat] > 0}
    return jsonify(year=y, month=m, plan=plan, spent_so_far=spent, saved=saved_now_data)


PRESETS = ("move_house", "new_expense", "new_baby", "purchase", "loan", "savings_goal", "income_change")


def _scenario_from_preset(p, months):
    """Turn a choice from the app ('move house, new rent 18,000') into an affordability-engine scenario.
    Kept on the server so the logic is in one tested place."""
    kind = p.get("preset")
    if kind not in PRESETS:
        raise InputError(f"preset must be one of {', '.join(PRESETS)}")

    def usual(cat):
        return statistics.median([mo[cat] for mo in months]) if months else 0.0

    if kind == "move_house":
        rent = _num(p.get("new_rent"), "new_rent")
        changes = {"housing": rent - usual("housing")}
        if p.get("extra_transport"):
            changes["transport"] = _num(p["extra_transport"], "extra_transport")
        return {"type": "monthly_change", "changes": changes}, f"Move to a place with rent of KES {round(rent):,}"
    if kind == "new_expense":
        cat = p.get("category")
        if cat not in SPENDING_CATEGORIES:
            raise InputError(f"category must be one of {', '.join(SPENDING_CATEGORIES)}")
        amount = _num(p.get("amount"), "amount")
        label = str(p.get("label") or "A new monthly cost")[:60]
        sc, title = {"type": "monthly_change", "changes": {cat: amount}}, f"{label}: KES {round(amount):,} a month"
        if p.get("months"):                       # a temporary cost, e.g. a 3-month course
            sc["months"] = int(_num(p["months"], "months", 1))
            title += f" for {sc['months']} month(s)"
        return sc, title
    if kind == "new_baby":
        food, utilities = _num(p.get("food", 6000), "food"), _num(p.get("utilities", 1500), "utilities")
        help_ = _num(p.get("house_help", 0), "house_help")
        changes = {"food_groceries": food, "utilities": utilities}
        if help_:
            changes["mobile_money_transfers"] = help_      # wages paid to a house help
        return {"type": "monthly_change", "changes": changes}, "A new baby"
    if kind in ("purchase", "loan"):
        price = _num(p.get("price" if kind == "purchase" else "amount"), "amount", 1)
        months_n = int(_num(p.get("months", 6), "months", 1))
        rate = _num(p.get("annual_rate", 0), "annual_rate")
        label = str(p.get("label") or ("A purchase" if kind == "purchase" else "A loan"))[:60]
        return ({"type": "purchase", "price": price, "months": months_n, "monthly_interest": rate / 1200},
                f"{label}: KES {round(price):,} over {months_n} months")
    if kind == "savings_goal":
        target = _num(p.get("target"), "target", 1)
        months_n = int(_num(p.get("months", 6), "months", 1))
        label = str(p.get("label") or "A savings goal")[:60]
        return ({"type": "savings_goal", "extra_per_month": target / months_n},
                f"{label}: KES {round(target):,} in {months_n} months")
    try:
        delta = float(p.get("amount"))
    except (TypeError, ValueError):
        raise InputError("amount must be a number (negative for a drop in income)")
    word = "rises" if delta >= 0 else "drops"
    sc, title = {"type": "monthly_change", "changes": {}, "income_change": delta}, f"Income {word} by KES {abs(round(delta)):,} a month"
    if p.get("months"):                           # e.g. HELB delayed for 2 months
        sc["months"] = int(_num(p["months"], "months", 1))
        title += f" for {sc['months']} month(s)"
    return sc, title


@bp.post("/me/afford")
@login_required
def afford():
    """'Can I afford this?' on the user's own saved data. Every check is kept in the history (scenarios)."""
    b = _body()
    with session() as s:
        pic = household_picture(s, g.user_id)
        profile, months = pic["profile"], pic["scored"]
        if profile is None:
            return jsonify(error="set up your household first"), 400
        if not months:
            return jsonify(error="record your spending for a few weeks first, so the answer is about your real money"), 400
        scenario, title = _scenario_from_preset(b, months)
        try:
            result = aff.evaluate({"household": {"household_size": profile.household_size,
                                                 "num_dependants": profile.dependants},
                                   "months": months, "scenario": scenario,
                                   "savings_balance": pic["savings_balance"]})
        except aff.AffordabilityInputError as exc:
            raise InputError(str(exc))
        result["title"] = title
        result["months_used"] = len(months)
        row = Scenario(user_id=g.user_id, request=b, result=result)
        s.add(row)
        s.commit()
        result["id"] = row.id
    return jsonify(result), 200


# ---------------- commitments, budgets, scenarios ----------------

@bp.get("/me/commitments")
@login_required
def get_commitments():
    with session() as s:
        c = s.get(Commitments, g.user_id)
        return jsonify(c.data if c else {"obligations": [], "debts": [], "goals": []})


@bp.put("/me/commitments")
@login_required
def put_commitments():
    import commitments as cm
    b = _body()
    try:
        result = cm.evaluate(b)          # validate with the same rules as /commitments before saving
    except cm.CommitmentsInputError as exc:
        raise InputError(str(exc))
    with session() as s:
        c = s.get(Commitments, g.user_id) or Commitments(user_id=g.user_id)
        c.data = b
        s.add(c)
        s.commit()
    return jsonify(saved=True, summary=result), 200


@bp.get("/me/budgets/<int:year>/<int:month>")
@login_required
def get_budget(year, month):
    with session() as s:
        b = s.scalar(select(Budget).where(Budget.user_id == g.user_id, Budget.year == year, Budget.month == month))
        return (jsonify(b.data), 200) if b else (jsonify(error="no budget for that month"), 404)


@bp.put("/me/budgets/<int:year>/<int:month>")
@login_required
def put_budget(year, month):
    if not 1 <= month <= 12:
        raise InputError("month must be 1-12")
    data = _body()
    with session() as s:
        b = s.scalar(select(Budget).where(Budget.user_id == g.user_id, Budget.year == year, Budget.month == month))
        b = b or Budget(user_id=g.user_id, year=year, month=month)
        b.data = data
        s.add(b)
        s.commit()
    return jsonify(saved=True), 200


@bp.get("/me/scenarios")
@login_required
def list_scenarios():
    with session() as s:
        rows = s.scalars(select(Scenario).where(Scenario.user_id == g.user_id)
                         .order_by(Scenario.created_at.desc())).all()
        return jsonify(scenarios=[{"id": r.id, "created_at": r.created_at.isoformat(), "request": r.request,
                                   "result": r.result} for r in rows])


@bp.post("/me/scenarios")
@login_required
def save_scenario():
    b = _body()
    if not isinstance(b.get("request"), dict) or not isinstance(b.get("result"), dict):
        raise InputError("send the scenario's request and result")
    with session() as s:
        r = Scenario(user_id=g.user_id, request=b["request"], result=b["result"])
        s.add(r)
        s.commit()
        return jsonify(id=r.id), 201


def _apply_choice(s, user_id, req, result, how):
    """Turn a checked scenario into a real change to the household, so the budget, dashboard and future checks
    use it (found in testing, 1 Nov: deciding to go ahead changed nothing). Returns what changed, in words.
    Only lasting things become commitments; everyday habits (a gym, more transport) are learnt from spending."""
    import commitments as cm
    kind = req.get("preset")
    label = str(req.get("label") or result.get("title") or "Plan")[:60]
    profile = s.get(Profile, user_id)
    c = s.get(Commitments, user_id) or Commitments(user_id=user_id, data={})
    data = copy.deepcopy({"obligations": [], "debts": [], "goals": [], **(c.data or {})})
    notes = []

    def obligation(name, cat, amount, months=None):
        data["obligations"].append({"name": name, "category": cat, "amount": round(amount), "frequency": "monthly"})
        notes.append(f"Added {name} (KES {round(amount):,} a month) to your commitments.")
        if months:
            notes.append(f"It lasts {months} month(s): remove it under Commitments when it ends.")

    if kind in ("purchase", "loan"):
        price = float(req.get("price" if kind == "purchase" else "amount"))
        if how == "from_savings":
            if (profile.savings_balance or 0) < price:
                raise InputError("your savings are less than the price")
            profile.savings_balance = (profile.savings_balance or 0) - price
            s.add(profile)
            notes.append(f"Paid from savings. Your savings are now KES {round(profile.savings_balance):,}.")
        else:
            pay = float(result.get("instalment_per_month_KES") or price / max(1, int(req.get("months", 6))))
            data["debts"].append({"name": label, "balance": round(price), "annual_rate": float(req.get("annual_rate", 0)),
                                  "monthly_payment": round(pay)})
            notes.append(f"Added {label} as a debt: KES {round(pay):,} a month until it is paid off.")
    elif kind == "move_house":
        data["obligations"] = [o for o in data["obligations"] if o.get("category") != "housing"]
        obligation("Rent", "housing", float(req["new_rent"]))
        if req.get("extra_transport"):
            notes.append("Record your new transport costs under Spending; your budget learns them from there.")
    elif kind == "new_expense":
        cat = req.get("category")
        if cat in ("school_fees", "mobile_money_transfers"):
            obligation(label, "school_fees" if cat == "school_fees" else "other_commitments",
                       float(req["amount"]), req.get("months"))
        else:
            notes.append(f"{label} is everyday spending, not a commitment. Record it under Spending and your "
                         "budget and forecast adjust from next month.")
    elif kind == "new_baby":
        profile.household_size += 1
        profile.dependants += 1
        s.add(profile)
        notes.append(f"Your household is now {profile.household_size} people, {profile.dependants} dependant(s).")
        if float(req.get("house_help", 0) or 0) > 0:
            obligation("House help", "other_commitments", float(req["house_help"]))
    elif kind == "savings_goal":
        months = int(req.get("months", 6))
        data["goals"].append({"name": label, "target": round(float(req["target"])), "saved": 0, "months_left": months})
        notes.append(f"Added the goal {label}: KES {round(float(req['target']) / months):,} a month is set aside in your budget.")
    elif kind == "income_change":
        delta = float(req["amount"])
        if req.get("months"):
            notes.append("This is temporary, so your usual income is unchanged. Your savings carry the gap.")
        elif delta > 0:
            s.add(IncomeSource(user_id=user_id, name=label if req.get("label") else "Extra income",
                               amount=round(delta), frequency="monthly"))
            notes.append(f"Added KES {round(delta):,} a month to your income.")
        else:
            cut = -delta
            sources = sorted(s.scalars(select(IncomeSource).where(IncomeSource.user_id == user_id)).all(),
                             key=lambda i: i.amount * FREQUENCIES[i.frequency], reverse=True)
            for i in sources:                     # take it off the biggest source first
                per_month = i.amount * FREQUENCIES[i.frequency] / 12
                take = min(cut, per_month)
                i.amount = round((per_month - take) * 12 / FREQUENCIES[i.frequency], 2)
                cut -= take
                s.add(i)
                if cut <= 0:
                    break
            notes.append(f"Your income is now KES {round(-delta):,} a month lower in your profile.")
    else:
        raise InputError("this check cannot be applied")
    try:
        cm.evaluate(data)
    except cm.CommitmentsInputError as exc:
        raise InputError(str(exc))
    c.data = data
    s.add(c)
    return notes


@bp.post("/me/scenarios/<int:sid>/apply")
@login_required
def apply_scenario(sid):
    """'I'm doing this': record the decision. Body: {"how": "instalments" | "from_savings"} for purchases."""
    how = (_body() if request.data else {}).get("how", "instalments")
    with session() as s:
        r = s.get(Scenario, sid)
        if r is None or r.user_id != g.user_id:
            return jsonify(error="no such check"), 404
        if (r.result or {}).get("applied"):
            return jsonify(error="you already went ahead with this one"), 409
        notes = _apply_choice(s, g.user_id, r.request or {}, r.result or {}, how)
        r.result = {**(r.result or {}), "applied": {"at": _now().isoformat(), "how": how, "notes": notes}}
        s.add(r)
        s.commit()
    return jsonify(applied=True, notes=notes), 200


@bp.delete("/me/scenarios/<int:sid>")
@login_required
def delete_scenario(sid):
    with session() as s:
        r = s.get(Scenario, sid)
        if r is None or r.user_id != g.user_id:
            return jsonify(error="no such check"), 404
        s.delete(r)
        s.commit()
    return jsonify(deleted=True), 200


@bp.delete("/me")
@login_required
def delete_account():
    """Privacy: a user (or a tester after the study) can remove everything about them."""
    with session() as s:
        for table in (Scenario, Budget, Commitments, Transaction, IncomeSource, Profile):
            s.execute(delete(table).where(table.user_id == g.user_id))
        s.execute(delete(User).where(User.id == g.user_id))
        s.commit()
    return jsonify(deleted=True), 200
