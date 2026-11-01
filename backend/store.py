"""Data layer (capstone): PostgreSQL in production (Neon), SQLite on a laptop and in tests.

The engines (forecast, affordability, budget, commitments) stay stateless calculators. This module stores
what each user enters and what they decide, behind sign-up/log-in, so the app works across devices and the
dynamic budget can see last month. Connection string comes from DATABASE_URL (never from code).
"""
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


@bp.get("/me/overview")
@login_required
def overview():
    """Everything the dashboard shows in one call. The current calendar month is still in progress, so it is
    shown as 'so far' and left out of the state and forecast (a half-recorded month looks deceptively cheap)."""
    with session() as s:
        profile = s.get(Profile, g.user_id)
        if profile is None:
            return jsonify(error="set up your household first"), 400
        months, income, one_offs = _user_months(s, g.user_id)
        if not months:
            return jsonify(has_data=False, income_monthly=round(income))
        today = _today()
        cur = (today.year, today.month)
        complete = [m for m in months if (m["year"], m["month"]) < cur]
        current = next((m for m in months if (m["year"], m["month"]) == cur), None)
        basis = complete or months
        fc = forecast_for_user(s, g.user_id, basis, *cur)
    health = aff.evaluate({"household": {"household_size": profile.household_size,
                                         "num_dependants": profile.dependants},
                           "months": basis[-12:]})
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
                   state=health["state_now"], score=health["score_before"],
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
    import commitments as cm
    today = _today()
    y, m = today.year, today.month
    py, pm = (y, m - 1) if m > 1 else (y - 1, 12)
    with session() as s:
        profile = s.get(Profile, g.user_id)
        if profile is None:
            return jsonify(error="set up your household first"), 400
        months, income, _ = _user_months(s, g.user_id)
        c = s.get(Commitments, g.user_id)
        saved_now = s.scalar(select(Budget).where(Budget.user_id == g.user_id, Budget.year == y, Budget.month == m))
        saved_prev = s.scalar(select(Budget).where(Budget.user_id == g.user_id, Budget.year == py, Budget.month == pm))
        saved_now_data = saved_now.data if saved_now else None
        prev_limits = (saved_prev.data or {}).get("budget") if saved_prev else None
    if income <= 0:
        return jsonify(error="add your income in your household profile first"), 400

    notes = []
    fixed, goal = {}, 0
    if c and c.data:
        summary = cm.evaluate(c.data)
        fixed, goal = dict(summary["for_budget"]["fixed"]), summary["for_budget"]["goal_per_month"]
    complete = [mo for mo in months if (mo["year"], mo["month"]) < (y, m)]
    current = next((mo for mo in months if (mo["year"], mo["month"]) == (y, m)), None)
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
        payload["months"] = complete[-12:]
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
