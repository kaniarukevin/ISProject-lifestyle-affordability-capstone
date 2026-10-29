"""Data layer (capstone): PostgreSQL in production (Neon), SQLite on a laptop and in tests.

The engines (forecast, affordability, budget, commitments) stay stateless calculators. This module stores
what each user enters and what they decide, behind sign-up/log-in, so the app works across devices and the
dynamic budget can see last month. Connection string comes from DATABASE_URL (never from code).
"""
import os
from datetime import date, datetime, timezone
from functools import wraps
from pathlib import Path

from flask import Blueprint, g, jsonify, request
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer
from sqlalchemy import (JSON, Boolean, Date, DateTime, Float, ForeignKey, Integer, String, UniqueConstraint,
                        create_engine, delete, select)
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
    _DB["engine"], _DB["Session"] = engine, sessionmaker(engine, expire_on_commit=False)
    return engine


def session():
    if "Session" not in _DB:
        init()
    return _DB["Session"]()


# ---------------- auth ----------------

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
    b = _body()
    email = str(b.get("email", "")).strip().lower()
    with session() as s:
        user = s.scalar(select(User).where(User.email == email))
        if not user or not check_password_hash(user.password_hash, str(b.get("password", ""))):
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
            "description": t.description, "source": t.source}


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
                                source=str(t.get("source", "manual"))[:20]))
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


@bp.get("/me/months")
@login_required
def monthly_summary():
    """Spending per category per month (oldest first) plus monthly income from the profile:
    exactly the 'months' list the /affordability and /budget engines take."""
    with session() as s:
        txs = s.scalars(select(Transaction).where(Transaction.user_id == g.user_id)).all()
        incomes = s.scalars(select(IncomeSource).where(IncomeSource.user_id == g.user_id)).all()
    income = sum(i.amount * FREQUENCIES[i.frequency] / 12 for i in incomes)
    by_month = {}
    for t in txs:
        key = (t.day.year, t.day.month)
        m = by_month.setdefault(key, {c: 0.0 for c in SPENDING_CATEGORIES})
        m[t.category] += t.amount
    months = [{"year": y, "month": mo, **cats, "income_primary": round(income, 2)}
              for (y, mo), cats in sorted(by_month.items())]
    return jsonify(months=months)


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
