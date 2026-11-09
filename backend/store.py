"""Data layer (capstone): PostgreSQL in production (Neon), SQLite on a laptop and in tests.

The engines (forecast, affordability, budget, commitments) stay stateless calculators. This module stores
what each user enters and what they decide, behind sign-up/log-in, so the app works across devices and the
dynamic budget can see last month. Connection string comes from DATABASE_URL (never from code).
"""
import calendar
import copy
import hashlib
import hmac
import json
import math
import re
import os
import secrets
import statistics
import threading
import time
from collections import Counter, defaultdict, deque
from datetime import date, datetime, timezone
from functools import wraps
from pathlib import Path

from flask import Blueprint, g, jsonify, request
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer
from sqlalchemy import (JSON, Boolean, Date, DateTime, Float, ForeignKey, Integer, String, UniqueConstraint,
                        create_engine, delete, func, inspect, select, text)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker
from sqlalchemy.pool import StaticPool
from werkzeug.security import check_password_hash, generate_password_hash

import affordability as aff
import limits
import mailer
import monitor
from model_register import DATASETS, MODEL_REGISTER

ROOT = Path(__file__).resolve().parent.parent
TOKEN_DAYS = 14             # audit A-08: 30 days was long for a finance app; logging out now also revokes
SPENDING_CATEGORIES = aff.CATS
UNSORTED = "unsorted"          # a statement payment whose category is not certain (never guessed)
# Spending that is known but has no place in the models' 10 categories (or is not known at all): shown by its
# real name, spread over everyday categories for the engines like unsorted money.
OUTSIDE = [UNSORTED, "shopping", "health", "personal_care", "other", "charges"]
OWN_ACCOUNT = "own_account"    # tagged by the user as moving money to their own account: not spending
EVERYDAY = ["food_groceries", "transport", "utilities", "airtime_data", "mobile_money_transfers", "entertainment"]
URBAN_RURAL = ("urban", "peri_urban", "rural")
# How money comes in, pick all that apply (onboarding). Close to the kinds of income household surveys record:
# wages, casual work, own business, farming, money sent by others, pensions. Only "salary" reaches the models
# (as formal_job, the formal/informal split the training data was built on); the rest tailors examples and wording.
INCOME_TYPES = ("salary", "casual", "business", "farming", "support", "pension", "none")
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
    # Which privacy notice the user agreed to, and when (Data Protection Act 2019: consent must be recorded).
    consent_version: Mapped[str | None] = mapped_column(String(20), nullable=True)
    consent_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # Raised by "log out everywhere": every token carries the value it was issued with (audit A-08).
    session_epoch: Mapped[int] = mapped_column(Integer, default=0)
    # Set when an admin pauses the account: it cannot log in or use the app, and its data is kept.
    blocked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class Rating(Base):
    """A user's answer to "Does this match your real finances?" (1 to 5), on the overview or on one
    affordability result: the volunteers' judgement of the outputs that the proposal's validation asks for."""
    __tablename__ = "ratings"
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    place: Mapped[str] = mapped_column(String(20))            # overview | afford ("where" is an SQL word)
    score: Mapped[int] = mapped_column(Integer)
    scenario_id: Mapped[int | None] = mapped_column(Integer, nullable=True)


class AdminAction(Base):
    """A permanent record of what admins did to accounts (Data Protection Act 2019: accountability). Holds the
    account number and the action only, never the email or any of the account's data."""
    __tablename__ = "admin_actions"
    id: Mapped[int] = mapped_column(primary_key=True)
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    admin_id: Mapped[int] = mapped_column(Integer)
    action: Mapped[str] = mapped_column(String(20))           # delete | block | unblock
    target_id: Mapped[int] = mapped_column(Integer)


class PasswordReset(Base):
    """A 6-digit code emailed to reset a forgotten password. Only a keyed hash is stored; it lasts 30 minutes,
    allows 5 tries and works once."""
    __tablename__ = "password_resets"
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    code_hash: Mapped[str] = mapped_column(String(64))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    tries: Mapped[int] = mapped_column(Integer, default=0)


class ForecastSnapshot(Base):
    """What the forecast said about a month before it happened (6 Nov), so it can be checked against what was
    spent once the month is recorded: the real-world accuracy the synthetic test set cannot give."""
    __tablename__ = "forecast_snapshots"
    __table_args__ = (UniqueConstraint("user_id", "year", "month"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    year: Mapped[int] = mapped_column(Integer)
    month: Mapped[int] = mapped_column(Integer)
    spending: Mapped[float] = mapped_column(Float)              # expected spending, saving left out
    low: Mapped[float | None] = mapped_column(Float, nullable=True)
    high: Mapped[float | None] = mapped_column(Float, nullable=True)
    made_on: Mapped[date] = mapped_column(Date)
    made_before: Mapped[bool] = mapped_column(Boolean)          # made before the month began (the fair test)
    basis: Mapped[str] = mapped_column(String(10))              # records | setup
    actual: Mapped[float | None] = mapped_column(Float, nullable=True)


class RevokedToken(Base):
    """A token logged out before it expired. Kept only until it would have expired anyway."""
    __tablename__ = "revoked_tokens"
    jti: Mapped[str] = mapped_column(String(32), primary_key=True)
    user_id: Mapped[int] = mapped_column(Integer, index=True)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class Profile(Base):
    __tablename__ = "profiles"
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    household_size: Mapped[int] = mapped_column(Integer, default=1)
    dependants: Mapped[int] = mapped_column(Integer, default=0)
    urban_rural: Mapped[str] = mapped_column(String(20), default="urban")
    formal_job: Mapped[bool] = mapped_column(Boolean, default=False)
    pays_own_fees: Mapped[bool] = mapped_column(Boolean, default=False)
    savings_balance: Mapped[float] = mapped_column(Float, default=0.0)   # money already saved (M-Shwari, SACCO, bank)
    estimates: Mapped[dict | None] = mapped_column(JSON, nullable=True)  # rough usual monthly spending, from setup
    income_low: Mapped[float | None] = mapped_column(Float, nullable=True)  # "a low month", if income varies
    name: Mapped[str | None] = mapped_column(String(40), nullable=True)      # what to call the user (first name)
    income_types: Mapped[list | None] = mapped_column(JSON, nullable=True)  # INCOME_TYPES, pick all that apply
    studying: Mapped[bool] = mapped_column(Boolean, default=False)
    children_in_school: Mapped[int] = mapped_column(Integer, default=0)
    # Budget lines the user set by hand ({category: KES}); kept for later months, the rest rebalances around them.
    budget_edits: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    # Money Tosha cannot see because it never touches M-PESA (an allowance spent by card, cash): rough monthly
    # amounts the user gave, added to every statement month. income_gap_answered: the "your statement shows less
    # than you told us" question was answered, so it is not asked again.
    outside_income: Mapped[float] = mapped_column(Float, default=0.0)
    outside_spending: Mapped[float] = mapped_column(Float, default=0.0)
    income_gap_answered: Mapped[bool] = mapped_column(Boolean, default=False)


class MonthIncome(Base):
    """A month's money in, set by the user ("this month I really had KES 30,000"): wins over everything else."""
    __tablename__ = "month_income"
    __table_args__ = (UniqueConstraint("user_id", "year", "month"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    year: Mapped[int] = mapped_column(Integer)
    month: Mapped[int] = mapped_column(Integer)
    amount: Mapped[float] = mapped_column(Float)
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
    ref: Mapped[str | None] = mapped_column(String(60), nullable=True, index=True)   # M-PESA receipt, to skip repeats
    # From statements: M-PESA's own type (exact), who was paid, the label shown, what the reader decided before any
    # user tag (so a tag can be undone), and whether the user fixed this one payment by hand.
    mpesa_type: Mapped[str | None] = mapped_column(String(20), nullable=True)
    payee: Mapped[str | None] = mapped_column(String(120), nullable=True)
    payee_key: Mapped[str | None] = mapped_column(String(160), nullable=True, index=True)
    label: Mapped[str | None] = mapped_column(String(60), nullable=True)
    auto_category: Mapped[str | None] = mapped_column(String(40), nullable=True)
    pinned: Mapped[bool] = mapped_column(Boolean, default=False)


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


class IncomeHistory(Base):
    """When the profile income changed: from (year, month) on, the monthly income was `monthly`. Past months are
    scored with the income of their time, so raising the income today does not rewrite earlier months. (0, 0)
    holds the income from before the first recorded change. No rows: every month uses the current income."""
    __tablename__ = "income_history"
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    year: Mapped[int] = mapped_column(Integer)
    month: Mapped[int] = mapped_column(Integer)
    monthly: Mapped[float] = mapped_column(Float)


class MoneyIn(Base):
    """Money coming in from a statement: the user's pay or allowance ('income'), their own money moving between
    accounts ('own_account'), or someone paying them back or a gift ('received'). The statement cannot tell a
    bank transfer of the user's own money from someone paying them from a bank, so the user tags the source."""
    __tablename__ = "money_in"
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    day: Mapped[date] = mapped_column(Date, index=True)
    amount: Mapped[float] = mapped_column(Float)
    kind: Mapped[str] = mapped_column(String(20))
    auto_kind: Mapped[str | None] = mapped_column(String(20), nullable=True)
    payee: Mapped[str | None] = mapped_column(String(120), nullable=True)
    payee_key: Mapped[str | None] = mapped_column(String(160), nullable=True, index=True)
    label: Mapped[str | None] = mapped_column(String(60), nullable=True)
    description: Mapped[str] = mapped_column(String(200), default="")
    ref: Mapped[str | None] = mapped_column(String(60), nullable=True, index=True)
    pinned: Mapped[bool] = mapped_column(Boolean, default=False)   # changed on its own: a source tag leaves it


class StatementRule(Base):
    """A user's answer about a payee in a statement ("Equity Acc. ••••4521 is rent"), reused on later uploads."""
    __tablename__ = "statement_rules"
    __table_args__ = (UniqueConstraint("user_id", "key"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    key: Mapped[str] = mapped_column(String(160))
    choice: Mapped[str] = mapped_column(String(30))
    was: Mapped[str | None] = mapped_column(String(40), nullable=True)   # the reader's category before the tag

def init(url=None):
    """Create the engine and the tables (idempotent). Call once at start-up, or from tests with 'sqlite://'."""
    url = url or database_url()
    secret_key()                       # fail at start-up, not on the first log-in
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
    if "ref" not in {c["name"] for c in inspect(engine).get_columns("transactions")}:
        with engine.begin() as conn:
            conn.execute(text("ALTER TABLE transactions ADD COLUMN ref VARCHAR(60)"))
    if "estimates" not in {c["name"] for c in inspect(engine).get_columns("profiles")}:
        with engine.begin() as conn:
            conn.execute(text("ALTER TABLE profiles ADD COLUMN estimates JSON"))
    false = "0" if engine.dialect.name == "sqlite" else "FALSE"
    for table, cols in {"transactions": {"mpesa_type": "VARCHAR(20)", "payee": "VARCHAR(120)",
                                         "payee_key": "VARCHAR(160)", "label": "VARCHAR(60)",
                                         "auto_category": "VARCHAR(40)",
                                         "pinned": f"BOOLEAN NOT NULL DEFAULT {false}"},
                        "statement_rules": {"was": "VARCHAR(40)"},
                        "money_in": {"pinned": f"BOOLEAN NOT NULL DEFAULT {false}"},
                        "profiles": {"income_low": "FLOAT", "name": "VARCHAR(40)", "income_types": "JSON",
                                     "studying": f"BOOLEAN NOT NULL DEFAULT {false}",
                                     "children_in_school": "INTEGER NOT NULL DEFAULT 0", "budget_edits": "JSON",
                                     "outside_income": "FLOAT NOT NULL DEFAULT 0",
                                     "outside_spending": "FLOAT NOT NULL DEFAULT 0",
                                     "income_gap_answered": f"BOOLEAN NOT NULL DEFAULT {false}"},
                        "users": {"consent_version": "VARCHAR(20)", "consent_at": "TIMESTAMP",
                                  "session_epoch": "INTEGER NOT NULL DEFAULT 0", "blocked_at": "TIMESTAMP"}}.items():
        have = {c["name"] for c in inspect(engine).get_columns(table)}
        for name, ddl in cols.items():
            if name not in have:
                with engine.begin() as conn:
                    conn.execute(text(f"ALTER TABLE {table} ADD COLUMN {name} {ddl}"))


def session():
    if "Session" not in _DB:
        init()
    return _DB["Session"]()


# ---------------- auth ----------------

# ---------------- rate limits (in memory; the service runs one worker) ----------------

_ATTEMPTS = defaultdict(deque)
_ATTEMPTS_LOCK = threading.Lock()


def _client_ip():
    """The caller's address for rate limits (audit A-04). Render sits behind Cloudflare, which sets
    CF-Connecting-IP itself and overwrites any value a client sends, so it cannot be faked. The first
    X-Forwarded-For entry CAN be faked (Render keeps whatever the client sent), so it is only a last resort.
    The admin overview shows which source was used, to check this on the live server."""
    return _client_ip_source()[0]


def _client_ip_source():
    for header in ("CF-Connecting-IP", "True-Client-IP"):
        v = request.headers.get(header, "").strip()
        if v:
            return v, header
    if production():
        v = request.headers.get("X-Forwarded-For", "").split(",")[0].strip()
        if v:
            return v, "X-Forwarded-For (can be faked)"
    return request.remote_addr or "unknown", "connection"


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


DEV_SECRET = "dev-only-change-me"


def production():
    """True on the hosted server. Render sets RENDER=true for every service; APP_ENV=production works anywhere."""
    return bool(os.environ.get("RENDER")) or os.environ.get("APP_ENV") == "production"


def secret_key():
    """The key that signs log-in tokens. The development fallback is public (it is in this repository), so anyone
    could forge a token with it and read any user's finances: the hosted server refuses to start without a real
    key of at least 32 characters (generate one with: python -c "import secrets; print(secrets.token_hex(32))")."""
    key = os.environ.get("SECRET_KEY", "")
    if production() and (len(key) < 32 or key == DEV_SECRET):
        raise RuntimeError("SECRET_KEY must be set to a random value of at least 32 characters in production")
    return key or DEV_SECRET


def _serializer():
    return URLSafeTimedSerializer(secret_key(), salt="auth")


# What the statement reader found in each row. The preview signs these for the logged-in user and the import
# checks the signature, so only rows read from a real statement can be saved; the user's own choices (one-off,
# payee tags) are not signed and stay free (audit A-03: forged rows with any amount used to be stored).
STATEMENT_ROW_FIELDS = ("ref", "date", "amount", "direction", "kind", "type", "category", "auto_category",
                        "payee", "payee_key", "source", "label", "details", "auto_kind")
MAX_STATEMENT_ROWS = 20_000


def _row_sig(user_id, r):
    def norm(k, v):
        if k == "amount":                    # 1240.0 may come back as 1240 from the app; same amount, same text
            return f"{float(v):.2f}" if limits.is_real(v) else None
        return None if v is None else str(v)
    msg = json.dumps([user_id] + [norm(k, r.get(k)) for k in STATEMENT_ROW_FIELDS], separators=(",", ":"))
    return hmac.new(secret_key().encode(), b"statement-row:" + msg.encode(), hashlib.sha256).hexdigest()[:32]


def _stamp(user):
    """A short fingerprint of the password hash, carried in the token: changing the password changes it, so every
    token issued before (a lost phone, a shared laptop) stops working."""
    return hashlib.sha256(user.password_hash.encode()).hexdigest()[:16]


def _token(user):
    """u: user, p: password fingerprint, e: session epoch ("log out everywhere"), j: this token's id (logout)."""
    return _serializer().dumps({"u": user.id, "p": _stamp(user), "e": user.session_epoch or 0,
                                "j": secrets.token_hex(8)})


BLOCKED = "This account is paused. Please contact the Tosha team."


def login_required(fn):
    @wraps(fn)
    def wrapper(*args, **kwargs):
        header = request.headers.get("Authorization", "")
        token = header[7:] if header.startswith("Bearer ") else ""
        try:
            data, issued = _serializer().loads(token, max_age=TOKEN_DAYS * 86400, return_timestamp=True)
        except SignatureExpired:
            return jsonify(error="your session has expired, log in again"), 401
        except BadSignature:
            return jsonify(error="log in first"), 401
        if not isinstance(data, dict) or "j" not in data:     # a token from before 6 Nov: log in once more
            return jsonify(error="please log in again"), 401
        with session() as s:
            user = s.get(User, data.get("u"))
            if user is None or _stamp(user) != data.get("p"):
                return jsonify(error="your password was changed or the account was removed, log in again"), 401
            if data.get("e", 0) != (user.session_epoch or 0) or s.get(RevokedToken, str(data["j"])) is not None:
                return jsonify(error="you were logged out, log in again"), 401
            if user.blocked_at is not None:        # 401: the app returns to the log-in screen, which explains
                return jsonify(error=BLOCKED), 401
        g.user_id, g.token_id, g.token_issued = user.id, str(data["j"]), issued
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
    except (TypeError, ValueError, OverflowError):
        raise InputError(f"{name} must be a number")
    if not limits.is_real(x):
        raise InputError(f"{name} must be a normal amount (at most {limits.MAX_AMOUNT:,})")
    if x < minimum:
        raise InputError(f"{name} must be at least {minimum:g}")
    return x


def _spend_day(v):
    """A spending date: a real date, not in the future and not older than limits.MAX_YEARS_BACK years (audit A-07:
    1901 and 2099 were accepted and skewed every average)."""
    try:
        day = date.fromisoformat(str(v))
    except ValueError:
        raise InputError("date must look like 2026-10-29")
    today = _today()
    if day > today:
        raise InputError("the date cannot be in the future")
    if day < date(today.year - limits.MAX_YEARS_BACK, today.month, 1):
        raise InputError(f"the date must be within the last {limits.MAX_YEARS_BACK} years")
    return day


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
        if b.get("consent") is True:             # the sign-up screen shows the notice with a tick box
            user.consent_version, user.consent_at = PRIVACY["version"], _now()
        s.add(user)
        s.commit()
        return jsonify(token=_token(user), user_id=user.id), 201


# ---------------- privacy notice and consent (Kenya Data Protection Act 2019) ----------------

PRIVACY = {
    "version": "2026-11-07",
    "title": "How Tosha uses your data",
    "sections": [
        {"title": "Who runs this app",
         "text": "Tosha is a final-year project by Kevin Kaniaru, a Computer Science student at Strathmore "
                 "University, Nairobi. It is a study prototype, not a bank or a licensed financial adviser, and its "
                 "answers are guidance, not financial advice."},
        {"title": "What we keep",
         "text": "Your email address and a scrambled form of your password (never the password itself); your "
                 "household details and income; the spending you enter; and from M-PESA statements you upload, "
                 "each transaction's date, amount, type and the name of the person or business as the statement "
                 "shows it, so the app can remember how you sorted them."},
        {"title": "What we never keep",
         "text": "Uploaded statement files and their passwords. A statement is read in memory, you review what was "
                 "found, and only the transactions you confirm are saved. The file and password are discarded."},
        {"title": "Why",
         "text": "Only to work out your budget, your financial health score, your spending forecast and whether a "
                 "choice is affordable, for you. Your data is not sold, not shared with anyone and not used for "
                 "advertising. The app's models were trained on made-up data, not on users' data."},
        {"title": "Where it is stored",
         "text": "In a cloud database (Neon) and on a cloud server (Render), which may be outside Kenya. Connections "
                 "are encrypted, and the database host encrypts stored data."},
        {"title": "Who can see it",
         "text": "Only you, through your account. The administrator sees counts and partly hidden email addresses, "
                 "not your transactions."},
        {"title": "Your rights",
         "text": "You can see everything the app keeps about you in the app, correct any entry, and delete your "
                 "account at any time under You. Deleting removes all your data immediately and "
                 "permanently, which also withdraws this consent. For any question, contact the developer through "
                 "Strathmore University."},
        {"title": "How long",
         "text": "Until you delete your account. All accounts will be deleted when the project ends."},
    ],
}


def _consented(user):
    return user is not None and user.consent_version == PRIVACY["version"]


@bp.get("/privacy")
def privacy_notice():
    return jsonify(PRIVACY), 200


@bp.get("/me/consent")
@login_required
def get_consent():
    with session() as s:
        user = s.get(User, g.user_id)
        return jsonify(version=PRIVACY["version"], accepted=_consented(user),
                       accepted_at=user.consent_at.isoformat() if user and user.consent_at else None), 200


@bp.post("/me/consent")
@login_required
def give_consent():
    b = _body()
    if b.get("accept") is not True or b.get("version") != PRIVACY["version"]:
        raise InputError("to continue, agree to the current privacy notice")
    with session() as s:
        user = s.get(User, g.user_id)
        user.consent_version, user.consent_at = PRIVACY["version"], _now()
        s.commit()
    return jsonify(accepted=True), 200


def _needs_consent(s):
    """Reading statements handles other people's names: only after the user has agreed to the notice."""
    if not _consented(s.get(User, g.user_id)):
        return jsonify(error="please read and agree to the privacy notice first", consent_required=True), 403
    return None


@bp.post("/auth/login")
def login():
    ip = _client_ip()
    if _recent(("login-ip", ip), 300) >= 20:
        return jsonify(error="too many log-in attempts, wait a few minutes"), 429
    _record(("login-ip", ip))
    b = _body()
    email = str(b.get("email", "")).strip().lower()
    # Wrong passwords are counted per account AND address (audit A-05: counting per account alone let a
    # stranger lock anyone out for 15 minutes with 5 guesses). A looser cap per account still stops guessing
    # spread over many addresses.
    if _recent(("login-fail", email, ip), 900) >= 5 or _recent(("login-fail", email), 3600) >= 30:
        return jsonify(error="too many wrong passwords for this account, wait 15 minutes"), 429
    with session() as s:
        user = s.scalar(select(User).where(User.email == email))
        if not user or not check_password_hash(user.password_hash, str(b.get("password", ""))):
            _record(("login-fail", email, ip))
            _record(("login-fail", email))
            # One message for a wrong email and a wrong password: saying which would tell anyone who has a
            # Tosha account (OWASP; banks do the same).
            return jsonify(error="That email and password don't match. Check both, or reset your password."), 401
        if user.blocked_at is not None:
            return jsonify(error=BLOCKED), 403
        return jsonify(token=_token(user), user_id=user.id), 200


@bp.post("/auth/logout")
@login_required
def logout():
    """Log out (audit A-08: the token used to stay valid for 30 days). This device's token stops working at once;
    with {"everywhere": true} every device is logged out, e.g. after losing a phone."""
    b = request.get_json(silent=True) or {}
    everywhere = bool(b.get("everywhere")) if isinstance(b, dict) else False
    now = _now()
    with session() as s:
        s.execute(delete(RevokedToken).where(RevokedToken.expires_at < now))      # tidy: those expired anyway
        if everywhere:
            user = s.get(User, g.user_id)
            user.session_epoch = (user.session_epoch or 0) + 1
        else:
            expires = datetime.fromtimestamp(g.token_issued.timestamp() + TOKEN_DAYS * 86400, timezone.utc)
            s.add(RevokedToken(jti=g.token_id, user_id=g.user_id, expires_at=expires))
        s.commit()
    return jsonify(logged_out=True, everywhere=everywhere), 200


@bp.post("/me/password")
@login_required
def change_password():
    """Change the password. The current one is required (someone holding an unlocked phone cannot take over the
    account), and the answer carries a new token: this device stays logged in, every other one is logged out."""
    b = _body()
    current, new = str(b.get("current", "")), str(b.get("new", ""))
    key = ("password-fail", g.user_id)
    if _recent(key, 900) >= 5:
        return jsonify(error="too many wrong passwords, wait 15 minutes"), 429
    if len(new) < 8:
        raise InputError("the new password must be at least 8 characters")
    with session() as s:
        user = s.get(User, g.user_id)
        if not check_password_hash(user.password_hash, current):
            _record(key)
            return jsonify(error="your current password is not right"), 403
        if check_password_hash(user.password_hash, new):
            raise InputError("the new password must be different from the current one")
        user.password_hash = generate_password_hash(new)
        s.commit()
        mailer.send(user.email, "Your Tosha password was changed", _CHANGED_TEXT)
        return jsonify(token=_token(user), changed=True), 200


_CHANGED_TEXT = ("Your Tosha password was just changed, and every other device was logged out.\n\n"
                 "If this was you, there is nothing to do. If it was not, reset your password from the log-in "
                 "screen with \"Forgot password?\" straight away.\n\nTosha")
RESET_MINUTES = 30


def _code_hash(code):
    return hmac.new(secret_key().encode(), f"reset:{code}".encode(), hashlib.sha256).hexdigest()


@bp.post("/auth/forgot")
def forgot_password():
    """Account recovery, step 1: email a 6-digit code. The answer is the same whether or not the email has an
    account, so this cannot be used to find out who uses Tosha."""
    ip = _client_ip()
    b = _body()
    email = str(b.get("email", "")).strip().lower()
    if _recent(("forgot-ip", ip), 3600) >= 10 or _recent(("forgot", email), 3600) >= 3:
        return jsonify(error="too many reset requests, try again in an hour"), 429
    _record(("forgot-ip", ip))
    _record(("forgot", email))
    answer = {"sent": True, "minutes": RESET_MINUTES,
              "message": "If this email has a Tosha account, a 6-digit code is on its way. Check spam too."}
    with session() as s:
        user = s.scalar(select(User).where(User.email == email))
        if user is None or user.blocked_at is not None:
            return jsonify(answer), 200
        code = f"{secrets.randbelow(1_000_000):06d}"
        s.execute(delete(PasswordReset).where(PasswordReset.user_id == user.id))
        s.add(PasswordReset(user_id=user.id, code_hash=_code_hash(code),
                            expires_at=datetime.fromtimestamp(time.time() + RESET_MINUTES * 60, timezone.utc)))
        s.commit()
    if not mailer.send(email, f"Your Tosha code: {code}",
                       f"Your code to reset your Tosha password is {code}.\n\nIt works for {RESET_MINUTES} "
                       "minutes. If you did not ask for it, ignore this email: your password stays the same.\n\n"
                       "Tosha"):
        return jsonify(error="email is not working right now, please try again later"), 503
    return jsonify(answer), 200


@bp.post("/auth/reset")
def reset_password():
    """Account recovery, step 2: the emailed code and a new password. Logs out every device (the token stamp
    follows the password) and logs this one in."""
    b = _body()
    email = str(b.get("email", "")).strip().lower()
    code, new = str(b.get("code", "")).strip(), str(b.get("new", ""))
    if len(new) < 8:
        raise InputError("the new password must be at least 8 characters")
    wrong = jsonify(error="that code is not right or has expired; ask for a new one"), 400
    with session() as s:
        user = s.scalar(select(User).where(User.email == email))
        row = s.scalar(select(PasswordReset).where(PasswordReset.user_id == user.id)) if user else None
        if row is None:
            return wrong
        expires = row.expires_at if row.expires_at.tzinfo else row.expires_at.replace(tzinfo=timezone.utc)
        if expires < _now() or row.tries >= 5:
            s.delete(row)
            s.commit()
            return wrong
        if not hmac.compare_digest(row.code_hash, _code_hash(code)):
            row.tries += 1
            s.commit()
            return wrong
        if user.blocked_at is not None:
            return jsonify(error=BLOCKED), 403
        user.password_hash = generate_password_hash(new)
        s.delete(row)
        s.commit()
        token = _token(user)
    mailer.send(email, "Your Tosha password was changed", _CHANGED_TEXT)
    monitor.log_event("account", "Password reset by email")
    return jsonify(token=token, user_id=user.id, reset=True), 200


# ---------------- "Does this match your real finances?" ----------------

@bp.post("/me/ratings")
@login_required
def add_rating():
    b = _body()
    where = b.get("where")
    score = b.get("score")
    if where not in ("overview", "afford"):
        raise InputError("where must be overview or afford")
    if not isinstance(score, int) or isinstance(score, bool) or not 1 <= score <= 5:
        raise InputError("score must be a whole number from 1 to 5")
    sid = b.get("scenario_id")
    with session() as s:
        if sid is not None:
            sc = s.get(Scenario, sid) if isinstance(sid, int) and not isinstance(sid, bool) else None
            if sc is None or sc.user_id != g.user_id:
                raise InputError("no such check")
        s.add(Rating(user_id=g.user_id, place=where, score=score, scenario_id=sid))
        s.commit()
    return jsonify(saved=True), 201


# ---------------- profile ----------------

def _record_income(s, user_id, old, new, change="from_now"):
    """Keep income history (IncomeHistory). from_now: past months keep the old income and the new one applies
    from this month. correction: the old figure was a mistake, so the history is cleared and every month uses
    the new income."""
    if change == "correction":
        s.execute(delete(IncomeHistory).where(IncomeHistory.user_id == user_id))
        return
    if abs(new - old) < 1:
        return
    today = _today()
    have = s.scalars(select(IncomeHistory).where(IncomeHistory.user_id == user_id)).all()
    if not have:
        s.add(IncomeHistory(user_id=user_id, year=0, month=0, monthly=round(old, 2)))
    s.execute(delete(IncomeHistory).where(IncomeHistory.user_id == user_id, IncomeHistory.year == today.year,
                                          IncomeHistory.month == today.month))
    s.add(IncomeHistory(user_id=user_id, year=today.year, month=today.month, monthly=round(new, 2)))


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
                       savingsBalance=p.savings_balance or 0.0, estimates=p.estimates or {},
                       incomeLow=p.income_low, name=p.name, incomeTypes=p.income_types or [],
                       studying=bool(p.studying), childrenInSchool=p.children_in_school or 0,
                       outsideIncome=p.outside_income or 0.0, outsideSpending=p.outside_spending or 0.0,
                       email=s.get(User, g.user_id).email,
                       incomes=[{"name": i.name, "amount": i.amount, "frequency": i.frequency} for i in incomes])


@bp.put("/me/profile")
@login_required
def put_profile():
    with session() as s:
        if _is_admin(s, g.user_id):     # role separation: an admin account runs the app and keeps no household
            return jsonify(error="admin accounts keep no household; use a normal account for your own budget"), 403
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
    est = b.get("estimates") or {}
    if not isinstance(est, dict) or any(k not in SPENDING_CATEGORIES for k in est):
        raise InputError("estimates must be an object of spending categories and monthly amounts")
    estimates = {k: _num(v or 0, f"estimate for {k}") for k, v in est.items() if v}
    types = b.get("incomeTypes")
    if types is not None and (not isinstance(types, list) or any(x not in INCOME_TYPES for x in types)):
        raise InputError(f"incomeTypes must be a list of: {', '.join(INCOME_TYPES)}")
    name = b.get("name")
    if name is not None and (not isinstance(name, str) or len(name.strip()) > 40):
        raise InputError("name must be text of at most 40 characters")
    children = int(_num(b.get("childrenInSchool", 0) or 0, "childrenInSchool"))
    if children >= size:
        raise InputError("children in school must be fewer than the household size")
    change = b.get("incomeChange", "from_now")
    if change not in ("from_now", "correction"):
        raise InputError("incomeChange must be from_now or correction")
    with session() as s:
        existing = s.get(Profile, g.user_id)
        p = existing or Profile(user_id=g.user_id)
        if existing is not None:                   # a new income, from this month or as a correction
            old = sum(i.amount * FREQUENCIES[i.frequency] / 12
                      for i in s.scalars(select(IncomeSource).where(IncomeSource.user_id == g.user_id)))
            new = sum(r.amount * FREQUENCIES[r.frequency] / 12 for r in rows)
            _record_income(s, g.user_id, old, new, change)
        p.household_size, p.dependants, p.urban_rural = size, deps, where
        p.formal_job, p.pays_own_fees = bool(b.get("formalJob")), bool(b.get("paysOwnFees"))
        if types is not None:
            p.income_types = list(dict.fromkeys(types))
            p.formal_job = "salary" in types          # the one part of the answer the models use
        if name is not None:
            p.name = name.strip() or None
        if "studying" in b:
            p.studying = bool(b.get("studying"))
        if "childrenInSchool" in b:
            p.children_in_school = children
        p.savings_balance = _num(b.get("savingsBalance", 0) or 0, "savingsBalance")
        p.estimates = estimates
        if "incomeLow" in b:                       # optional; an app that does not send it keeps the answer
            low = b.get("incomeLow")
            p.income_low = None if low in (None, "", 0) else _num(low, "incomeLow")
        s.add(p)
        s.execute(delete(IncomeSource).where(IncomeSource.user_id == g.user_id))
        s.add_all(rows)
        s.commit()
    return jsonify(saved=True), 200


# ---------------- transactions ----------------

def _tx_json(t):
    return {"id": t.id, "date": t.day.isoformat(), "amount": t.amount, "category": t.category,
            "description": t.description, "source": t.source, "one_off": bool(t.one_off),
            "type": t.mpesa_type, "payee": t.payee, "payee_key": t.payee_key, "label": t.label,
            "pinned": bool(t.pinned)}


@bp.get("/me/transactions")
@login_required
def list_transactions():
    """All records, or one month's with ?month=YYYY-MM (the spending screen loads a month when it is opened:
    a year of M-PESA statements is well over a thousand records, too many to send to a phone at once)."""
    q = select(Transaction).where(Transaction.user_id == g.user_id).order_by(Transaction.day.desc(),
                                                                             Transaction.id.desc())
    month = request.args.get("month")
    if month:
        try:
            first = date(int(month[:4]), int(month[5:7]), 1)
        except (ValueError, IndexError):
            raise InputError("month must look like 2026-10")
        after = date(first.year + first.month // 12, first.month % 12 + 1, 1)
        q = q.where(Transaction.day >= first, Transaction.day < after)
    with session() as s:
        return jsonify(transactions=[_tx_json(t) for t in s.scalars(q).all()])


def _month_summaries(s, user_id):
    """One line per month, newest first: usual spending by category, one-offs apart, the user's own money moving
    left out, and how many records the month holds. Also whether any record came from a statement."""
    q = select(Transaction.day, Transaction.amount, Transaction.category, Transaction.one_off, Transaction.source) \
        .where(Transaction.user_id == user_id)
    months, statement = {}, False
    for day, amount, category, one_off, source in s.execute(q):
        m = months.setdefault((day.year, day.month), {"year": day.year, "month": day.month, "count": 0,
                                                      "total": 0.0, "one_off": 0.0, "by_category": {}})
        m["count"] += 1
        statement = statement or source == "mpesa"
        if category == "own_account":
            continue
        if one_off:
            m["one_off"] += amount
            continue
        m["total"] += amount
        m["by_category"][category] = m["by_category"].get(category, 0.0) + amount
    return [months[k] for k in sorted(months, reverse=True)], statement


@bp.get("/me/transactions/summary")
@login_required
def transaction_summary():
    with session() as s:
        rows, statement = _month_summaries(s, g.user_id)
    return jsonify(months=rows, has_statement=statement), 200


@bp.get("/me/records")
@login_required
def records():
    """The Records screen in one trip: every month's summary, plus one month's records (?month=YYYY-MM, default
    the newest month with records). Two requests one after the other cost two long round trips from a phone."""
    month = request.args.get("month")
    with session() as s:
        rows, statement = _month_summaries(s, g.user_id)
        if month:
            try:
                first = date(int(month[:4]), int(month[5:7]), 1)
            except (ValueError, IndexError):
                raise InputError("month must look like 2026-10")
        elif rows:
            first = date(rows[0]["year"], rows[0]["month"], 1)
        else:
            first = date(_today().year, _today().month, 1)
        after = date(first.year + first.month // 12, first.month % 12 + 1, 1)
        txs = s.scalars(select(Transaction).where(Transaction.user_id == g.user_id, Transaction.day >= first,
                                                  Transaction.day < after)
                        .order_by(Transaction.day.desc(), Transaction.id.desc())).all()
        return jsonify(months=rows, has_statement=statement, month=f"{first.year}-{first.month:02d}",
                       transactions=[_tx_json(t) for t in txs]), 200


@bp.post("/me/transactions")
@login_required
def add_transactions():
    """Accepts one transaction or a list (a parsed statement)."""
    b = request.get_json(silent=True)
    items = b if isinstance(b, list) else [b]
    if len(items) > limits.MAX_ROWS:
        raise InputError(f"send at most {limits.MAX_ROWS:,} records at a time")
    rows = []
    for t in items:
        if not isinstance(t, dict):
            raise InputError("each transaction must be an object")
        if t.get("category") not in SPENDING_CATEGORIES:
            raise InputError(f"category must be one of {', '.join(SPENDING_CATEGORIES)}")
        day = _spend_day(t.get("date"))
        amount = _num(t.get("amount"), "amount")
        if amount <= 0:
            raise InputError("amount must be more than 0")
        rows.append(Transaction(user_id=g.user_id, day=day, amount=amount,
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


def _all_txs(s, user_id):
    """All of a user's records, read once per request and shared by the helpers that used to query them one by
    one (the dashboard read the transactions table 5 times, found 7 Nov)."""
    memo = s.info.setdefault("txs", {})
    if user_id not in memo:
        memo[user_id] = s.scalars(select(Transaction).where(Transaction.user_id == user_id)).all()
    return memo[user_id]


def _user_months(s, user_id):
    """Spending per category per month (oldest first), with monthly income from the profile."""
    txs = _all_txs(s, user_id)
    incomes = s.scalars(select(IncomeSource).where(IncomeSource.user_id == user_id)).all()
    income = sum(i.amount * FREQUENCIES[i.frequency] / 12 for i in incomes)
    history = sorted(s.scalars(select(IncomeHistory).where(IncomeHistory.user_id == user_id)).all(),
                     key=lambda r: r.year * 12 + r.month)

    def income_at(key):
        """The profile income in a given month: the latest change on or before it (current income if none)."""
        if not history:
            return income
        at = key[0] * 12 + key[1]
        got = [r.monthly for r in history if r.year * 12 + r.month <= at]
        return got[-1] if got else history[0].monthly
    # Income actually received, when the user has tagged a source in a statement as their pay or allowance. For
    # the months a statement covers, that replaces the profile figure (a late or short allowance then shows);
    # other months keep the profile income.
    ins = s.scalars(select(MoneyIn).where(MoneyIn.user_id == user_id)).all()
    actual, mixed, other, covered = {}, {}, {}, set()
    for x in ins:
        key = (x.day.year, x.day.month)
        covered.add(key)
        if x.kind == "income":
            actual[key] = actual.get(key, 0.0) + x.amount
        elif x.kind == "mixed":                      # pay and the user's own money together
            mixed[key] = mixed.get(key, 0.0) + x.amount
        elif x.kind in ("own_account", "received"):  # own money moved in, or money from someone
            other[key] = other.get(key, 0.0) + x.amount
    # Only once the user has tagged a source as their pay or allowance: salary lines alone would ignore an
    # allowance that arrives by bank transfer and make income look far too low.
    tags_in = set(s.scalars(select(StatementRule.choice).where(StatementRule.user_id == user_id,
                                                                StatementRule.key.like("in:%"))))
    use_actual = bool(tags_in & {"income", "mixed"})

    def month_income(key):
        # "A mix": the profile income stays the plan, but a month where less arrived uses the lower amount
        # (a late or short allowance shows; moving one's own savings never inflates income).
        got = actual.get(key, 0.0)
        paid = min(income_at(key), got + mixed.get(key, 0.0)) if "mixed" in tags_in else got
        # Money from the user's own accounts or from people tops the tagged pay up, to at most the usual income.
        # An allowance paid into a bank and moved to M-PESA looks exactly like that (7 Nov: months with no pay
        # scored as no income; 8 Nov: a 16,000 salary month with the rest of a 30,000 income moved in from the
        # bank scored as 16,000). Moving extra savings around still never raises income above the usual.
        return paid + min(other.get(key, 0.0), max(0.0, income_at(key) - paid))
    by_month, outside, one_offs = {}, {}, {}
    profile = s.get(Profile, user_id)
    out_in = float(profile.outside_income or 0) if profile else 0.0
    out_spend = float(profile.outside_spending or 0) if profile else 0.0
    statement_months = {(t.day.year, t.day.month) for t in txs if t.source in ("mpesa", "messages")}
    overrides = {(r.year, r.month): r.amount
                 for r in s.scalars(select(MonthIncome).where(MonthIncome.user_id == user_id))}
    for t in txs:
        key = (t.day.year, t.day.month)
        if t.category == OWN_ACCOUNT:
            continue                                 # the user's own money moving: not spending
        if t.one_off:
            one_offs[key] = one_offs.get(key, 0.0) + t.amount
            continue
        m = by_month.setdefault(key, {c: 0.0 for c in SPENDING_CATEGORIES})
        if t.category in m:
            m[t.category] += t.amount
        else:                                        # unsorted, shopping, health, personal care, other
            o = outside.setdefault(key, {})
            o[t.category] = o.get(t.category, 0.0) + t.amount
    # Unsorted money still counts in every total. For the engines' category inputs it is spread across everyday
    # categories in the household's own sorted proportions (the average split if nothing is sorted), so a big
    # unsorted amount neither disappears nor pushes one category up. "known" keeps what is actually known, for
    # display and for personalising the budget.
    known_every = {c: sum(m[c] for m in by_month.values()) for c in EVERYDAY}
    total_every = sum(known_every.values())
    if total_every > 0:
        weights = {c: v / total_every for c, v in known_every.items()}
    else:
        import budget as bud
        weights = dict(zip(bud.model()["variable"], [float(x) for x in bud.model()["one_size"]]))
        weights = {c: w / (sum(weights.values()) or 1) for c, w in weights.items()}
    months = []
    for (y, mo), cats in sorted(by_month.items()):
        out = outside.get((y, mo), {})
        un = sum(out.values())
        # Card and cash spending the user estimated (statement months only: typed-in months already have it).
        extra = out_spend if (y, mo) in statement_months else 0.0
        spread = {c: cats[c] + ((un + extra) * weights.get(c, 0.0) if c in EVERYDAY else 0.0)
                  for c in SPENDING_CATEGORIES}
        from_statement = use_actual and (y, mo) in covered
        if (y, mo) in overrides:
            money_in, source = overrides[(y, mo)], "you"
        elif from_statement:
            money_in, source = month_income((y, mo)) + out_in, "statement"
        else:
            money_in, source = income_at((y, mo)), "profile"
        months.append({"year": y, "month": mo, **spread,
                       "income_primary": round(money_in, 2),
                       "income_from": source, "outside_estimate": round(extra, 2),
                       "unsorted": round(un, 2), "outside": {k: round(v, 2) for k, v in out.items()},
                       "known": {c: round(v, 2) for c, v in cats.items()}})
    return months, income, one_offs


def _known(m):
    """What is actually known about a month: sorted categories plus 'unsorted' (estimates have no unsorted)."""
    k = m.get("known")
    if k is None:                                    # estimates: everything is in the 10 categories
        return {c: m[c] for c in SPENDING_CATEGORIES}
    return {**k, **m.get("outside", {})}


@bp.get("/me/months")
@login_required
def monthly_summary():
    """Exactly the 'months' list the /affordability and /budget engines take."""
    with session() as s:
        months, _, _ = _user_months(s, g.user_id)
    return jsonify(months=months)


# Shopping, health and personal care get budget lines of their own when the household spends on them in most
# months (8 Nov), sized from its own average.
EXTRA_LINES = ["shopping", "health", "personal_care"]
BUDGET_LINES = SPENDING_CATEGORIES + ["other_commitments"] + EXTRA_LINES


def _budget_lines(data):
    """The usable lines of a saved budget: known categories with real numbers. Anything else is ignored, so a
    budget saved before validation existed can never break the dashboard (audit A-02), or None."""
    lines = data.get("budget") if isinstance(data, dict) else None
    if not isinstance(lines, dict):
        return None
    return {c: float(v) for c, v in lines.items()
            if c in BUDGET_LINES and limits.is_real(v)}


def _commitments_row(s, user_id):
    """The user's Commitments row, read once per request. s.get() alone went back to the database every time,
    because the session forgets objects nothing holds on to: 13 reads in one dashboard load (found 7 Nov)."""
    memo = s.info.setdefault("commitments", {})
    if user_id not in memo:
        memo[user_id] = s.get(Commitments, user_id)
    return memo[user_id]


def _saved_budget(s, user_id, year, month):
    memo = s.info.setdefault("budgets", {})
    if (user_id, year, month) not in memo:
        memo[(user_id, year, month)] = s.scalar(select(Budget).where(Budget.user_id == user_id, Budget.year == year,
                                                                      Budget.month == month))
    b = memo[(user_id, year, month)]
    lines = _budget_lines(b.data) if b else None
    return {c: lines.get(c, 0.0) for c in SPENDING_CATEGORIES} if lines is not None else None


def _today():
    return date.today()


_USER_FORECAST = {}
USER_FORECAST_PATH = Path(__file__).resolve().parent / "models" / "user_forecast.joblib"


def user_forecast_model():
    """The boosted tree chosen in scripts/kihbs_forecast_experiment.py (docs/experiments.md, 4 Nov), or None."""
    if "m" not in _USER_FORECAST:
        import joblib
        _USER_FORECAST["m"] = joblib.load(USER_FORECAST_PATH) if USER_FORECAST_PATH.exists() else None
    return _USER_FORECAST["m"]


def _model_total(hist, totals, profile, target_month, ahead=1, pays_fees=True):
    """A month's total from the model: a multiple of the household's median, using only what is known before the
    month starts (past months, income, household, and which calendar month it is). ahead: 1 = the month after
    the last recorded one, 2 or 3 = further out. The same model serves all three (it beat separate per-horizon
    models on validation); the range is widened more further out (docs/experiments.md, 5 Nov)."""
    eng = user_forecast_model()
    median = statistics.median(totals)
    if eng is None or profile is None or median <= 0:
        return None
    fee_months = eng["fee_months"]
    incomes = [m.get("income_primary", 0) for m in hist]
    fees_seen = [m["school_fees"] for m in hist if m["month"] in fee_months]
    x = {"h": len(hist), "median": median, "mean": statistics.mean(totals), "last": totals[-1],
         "min": min(totals), "max": max(totals), "std": statistics.stdev(totals) if len(totals) > 1 else 0.0,
         "income": incomes[-1], "income_mean": statistics.mean(incomes),
         "household_size": profile.household_size, "num_dependants": profile.dependants,
         "formal": int(bool(profile.formal_job)), "month": target_month,
         # A fee month only for someone who pays fees (fees in their records, a school-fees bill, or "I pay my own
         # fees"): otherwise the model added about KES 1,200 to a student's January, May and September for no reason.
         # Ignoring it for non-payers lowered held-out error in those months (10,833 to 10,490; experiments, 6 Nov).
         "fee_month": int(target_month in fee_months and pays_fees), "december": int(target_month == 12),
         "fees_seen": max(fees_seen) if fees_seen else 0.0,
         "fees_median": statistics.median([m["school_fees"] for m in hist])}
    import pandas as pd
    row = pd.DataFrame([x])[eng["features"]]
    models = eng.get("horizons", {}).get(ahead) or {"model": eng["model"], "low": eng.get("low"), "high": eng.get("high")}
    mid = median * max(float(models["model"].predict(row)[0]), 0.0)
    if x["fee_month"] and x["fees_seen"] > 0:
        # Safety floor: in a fee month, a fee-paying household spends at least its usual non-fee spending plus
        # last term's fees. Neutral on accuracy (validation 10,923 vs 10,912; test 9,936 vs 9,967) and active in
        # 4% of forecasts, but stops implausible answers (found walking through the app: a family's January,
        # a fee month, came out below a normal month).
        mid = max(mid, statistics.median([tt - m["school_fees"] for tt, m in zip(totals, hist)]) + x["fees_seen"])
    x["range"] = None
    if "low" in eng:            # 80% range: two quantile trees, widened on validation (docs/experiments.md, 4 Nov)
        lo, hi = median * float(models["low"].predict(row)[0]), median * float(models["high"].predict(row)[0])
        w = eng.get("horizon_widen", {}).get(ahead, eng.get("widen", 1.0))
        down, up = max(0.0, mid - lo), max(0.0, hi - mid)
        if "own_z" in eng and len(hist) >= eng.get("personal_range_min_months", 3):
            # Personal range: half the model's spread, half this household's own month-to-month spread, so a
            # steady household gets a narrower range (found walking through the app: a family spending the
            # same every month was told 31,000-73,000).
            own = eng["own_z"] * x["std"]
            down, up = 0.5 * down + 0.5 * own, 0.5 * up + 0.5 * own
        x["range"] = (max(0.0, mid - w * down), mid + w * up)
    return mid, x


def _commitment_changes(s, user_id, hist):
    """Rent or loan repayments entered under Commitments that differ from what history shows (a move, a new
    loan after "I'm doing this"). Known exactly, so added as they are rather than waiting for history."""
    import commitments as cm
    c = _commitments_row(s, user_id)
    if not (c and c.data):
        return {}
    fixed = cm.evaluate(c.data, _today())["for_budget"]["fixed"]
    out = {}
    for cat in ("housing", "loan_repayment"):
        if cat in fixed and float(fixed[cat]) > 0:
            diff = float(fixed[cat]) - statistics.median([m[cat] for m in hist])
            if abs(diff) >= 1:
                out[cat] = diff
    return out


def _pays_fees(s, user_id, hist, profile):
    """Does this person pay school fees? Fees in their records, a school-fees bill under Plans, or the profile's
    "I pay my own fees"."""
    if any(m.get("school_fees", 0) > 0 for m in hist) or (profile is not None and profile.pays_own_fees):
        return True
    c = _commitments_row(s, user_id)
    return bool(c and c.data and any(o.get("category") == "school_fees" for o in c.data.get("obligations", [])))


def forecast_for_user(s, user_id, months, target_year, target_month, ahead=1, blend=True):
    """The user's own forecast.
    Total: a boosted tree trained on the KIHBS-informed households (history + calendar month), which beat the
    median of monthly totals on held-out households at every history length (test MAE KES 9,794 vs 10,719,
    docs/experiments.md, 4 Nov). It knows that school fees fall in January, May and September and that
    December is costly. Falls back to the median if the model is missing.
    Split: the household's average share per category; in a fee month school fees get the amount paid in past
    fee months (fee-aware split). A per-category median is NOT used for the split: most people skip some
    categories in some months, so it often collapsed to KES 0 (found in testing, 1 Nov).
    With a saved budget for the month: 0.75 x budget + 0.25 x usual; with only last month's budget: the same.
    Also returns an 80% range (8 months in 10 fall inside on held-out households) and adds rent or loan changes
    entered under Commitments. Tested and rejected (docs/experiments.md, 4 Nov): forecasting commitments
    separately, a personal bias correction, and tuning; none beat this on validation."""
    hist = months[-12:]
    totals = [sum(m[c] for c in SPENDING_CATEGORIES) for m in hist]
    parts = SPENDING_CATEGORIES + OUTSIDE            # unsorted and other spending shown by name, not guessed
    shares = {c: sum(_known(m).get(c, 0.0) / t for m, t in zip(hist, totals) if t > 0) / len(hist) for c in parts}
    norm = sum(shares.values()) or 1.0
    shares = {c: v / norm for c, v in shares.items()}
    profile = s.get(Profile, user_id)
    model = _model_total(hist, totals, profile, target_month, ahead, _pays_fees(s, user_id, hist, profile))
    if model:
        usual_total, x = model
        fees = x["fees_seen"] if x["fee_month"] else x["fees_median"]
        rest_share = (1 - shares["school_fees"]) or 1.0
        rest = max(0.0, usual_total - fees)
        usual = {c: rest * shares[c] / rest_share for c in parts if c != "school_fees"}
        usual["school_fees"] = fees
        base = "model"
        rng = x["range"]
    else:
        usual_total = statistics.median(totals)
        usual = {c: usual_total * shares[c] for c in parts}
        base, rng = "median", None
    changes = _commitment_changes(s, user_id, hist)
    for cat, diff in changes.items():
        usual[cat] = max(0.0, usual[cat] + diff)
    shift = sum(changes.values())
    py, pm = (target_year, target_month - 1) if target_month > 1 else (target_year - 1, 12)
    # blend=False: the plain model, "at your usual pace" (what the budget forecast compares the budget with; the
    # held-out error KES 9,967 was measured on this, without a budget).
    this_budget = _saved_budget(s, user_id, target_year, target_month) if blend else None
    last_budget = _saved_budget(s, user_id, py, pm) if blend else None
    if this_budget:
        split, method = {c: 0.75 * this_budget.get(c, 0) + 0.25 * usual[c] for c in parts}, f"blend_budget_{base}"
    elif last_budget:
        split, method = {c: 0.75 * last_budget.get(c, 0) + 0.25 * usual[c] for c in parts}, f"blend_last_budget_{base}"
    else:
        split, method = usual, ("forecast_model" if base == "model" else "trailing_median")
    breakdown = {c: round(v) for c, v in split.items() if round(v) > 0}
    total = sum(breakdown.values())
    out = {"year": target_year, "month": target_month, "total": total, "ahead": ahead,
           "breakdown": breakdown, "method": method, "months_used": len(hist)}
    if rng:
        # The same blend applied to the ends of the range (a budget makes the forecast surer, so the range narrows).
        w = 0.25 if (this_budget or last_budget) else 1.0
        lo, hi = (w * (v + shift) + (total - w * (sum(usual.values()))) for v in rng)
        out["range"] = {"low": round(max(0.0, min(lo, total))), "high": round(max(hi, total))}
    if changes:
        out["note"] = "Includes your new " + " and ".join(
            {"housing": "rent", "loan_repayment": "loan repayments"}[c] for c in changes) + " from Commitments."
    return out


OUTLOOK_MONTHS = 3          # the proposal's "one to three months" (3.2.3)


def outlook_for_user(s, user_id, months, year, month, blend=True):
    """This month and the next two: [forecast_for_user(...) for each], built from the same recorded history.
    Held-out households, error vs the median: 1 month ahead 9,967 vs 10,719; 2 months 10,354 vs 11,738;
    3 months 11,000 vs 11,791; 80% ranges hold 83-85% of months (scripts/forecast_horizons.py)."""
    out = []
    last = months[-1]["year"] * 12 + months[-1]["month"] if months else year * 12 + month - 1
    for k in range(OUTLOOK_MONTHS):
        y, m = year + (month - 1 + k) // 12, (month - 1 + k) % 12 + 1
        # How far past the last recorded month (old records make "this month" further ahead); beyond 3 the
        # 3-month range is used, the widest that was checked.
        ahead = min(max(1, y * 12 + m - last), OUTLOOK_MONTHS)
        out.append(forecast_for_user(s, user_id, months, y, m, ahead=ahead, blend=blend))
    return out


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
    estimated = False
    if not complete and profile is not None and profile.estimates:
        # Day one: the user's rough figures from setup stand in for last month until a real month is recorded,
        # so the dashboard, budget and "Can I afford it?" work in the first minute (audit: cold start).
        py, pm = (cur[0], cur[1] - 1) if cur[1] > 1 else (cur[0] - 1, 12)
        complete = [{"year": py, "month": pm, **{c: float(profile.estimates.get(c, 0)) for c in SPENDING_CATEGORIES},
                     "income_primary": round(income, 2)}]
        estimated = True
    fixed, goal, summary = {}, 0, None
    c = _commitments_row(s, user_id)
    tracked = []
    if c and c.data:
        effective, tracked = _tracked_goals(s, user_id, c.data)
        summary = cm.evaluate(effective, _today())
        fixed, goal = dict(summary["for_budget"]["fixed"]), summary["for_budget"]["goal_per_month"]
    scored = [dict(mo) for mo in (complete or months)[-12:]]
    for mo in scored:
        for cat in ("housing", "school_fees", "loan_repayment"):
            mo[cat] = max(mo[cat], float(fixed.get(cat, 0)))
        # chama, insurance, support to family are payments to others; max, not +, so nothing is counted twice
        mo["mobile_money_transfers"] = max(mo["mobile_money_transfers"], float(fixed.get("other_commitments", 0)))
    spent = sum(sum(mo[c] for c in SPENDING_CATEGORIES if c != "savings") for mo in scored)
    unsorted_share = sum(mo.get("unsorted", 0.0) for mo in scored) / spent if spent else 0.0      # outside the 10
    not_sorted = sum(mo.get("outside", {}).get(UNSORTED, 0.0) for mo in scored) / spent if spent else 0.0
    return {"profile": profile, "income": income, "months": months, "complete": complete, "current": current,
            "estimated": estimated, "unsorted_share": unsorted_share, "not_sorted_share": not_sorted,
            # More than 10% unsorted: use the state model that needs no category split.
            "statement_safe": unsorted_share > 0.10,
            "one_offs": one_offs, "scored": scored, "fixed": fixed, "goal_per_month": goal, "today": today,
            "commitments": summary, "goal_progress": tracked,
            "savings_balance": float(profile.savings_balance or 0) if profile else 0.0}


LOW_MONTH_SHARE = 0.85      # income "varies" when the low month is below 85% of the usual one
LOW_MONTH_WINDOW = 6        # months of income that actually arrived
LOW_MONTH_MIN = 3           # fewer than this: not enough history to know


def _low_month(pic):
    """How low income gets (6 Nov): many Kenyan households are paid irregularly (casual work, commission, a
    business, a late HELB), and a plan that only works in a good month is risky. The low month is the lowest of
    the last 6 months of income that actually arrived (statement, tagged as pay), or the user's own answer at
    setup. Returned only when it is clearly lower than usual: {"status": varies | steady | unknown, ...}."""
    got = [m for m in pic["scored"] if m.get("income_from") == "statement"][-LOW_MONTH_WINDOW:]
    if len(got) >= LOW_MONTH_MIN:
        low = min(got, key=lambda m: m["income_primary"])
        usual = statistics.median(m["income_primary"] for m in got)
        out = {"income_KES": round(low["income_primary"]), "usual_KES": round(usual), "from": "statement",
               "year": low["year"], "month": low["month"], "months_seen": len(got)}
        return {**out, "status": "varies" if low["income_primary"] < LOW_MONTH_SHARE * usual else "steady"}
    p = pic["profile"]
    if p is not None and p.income_low and pic["income"] > 0:
        status = "varies" if p.income_low < LOW_MONTH_SHARE * pic["income"] else "steady"
        return {"status": status, "income_KES": round(p.income_low), "usual_KES": round(pic["income"]), "from": "you"}
    return {"status": "unknown", "months_seen": len(got)}


def _low_month_check(pic, profile, scenario, low):
    """The same check again as if the coming months brought only the low month's income."""
    months = [dict(m) for m in pic["scored"]]
    for m in months[-3:]:
        m["income_primary"] = min(m["income_primary"], low["income_KES"])
    r = aff.evaluate({"household": {"household_size": profile.household_size, "num_dependants": profile.dependants},
                      "months": months, "scenario": scenario, "savings_balance": pic["savings_balance"],
                      "statement_safe": pic["statement_safe"]})
    left = r["after"]["left_over_KES"] if "after" in r else r.get("left_over_KES")
    when = (f"a month like {calendar.month_name[low['month']]} {low['year']}" if low.get("month")
            else "a low month")
    return {"income_KES": low["income_KES"], "usual_KES": low["usual_KES"], "from": low["from"], "when": when,
            "verdict": r["verdict"], "score_after": r.get("score_after"), "left_over_KES": left}


# Short-term digital credit: borrowing to get through the month. Bank loans, SACCO loans and HELB are planned
# debts and are not counted here.
FULIZA = re.compile(r"od loan repayment|overdraw|fuliza", re.I)
DIGITAL_LENDERS = re.compile(r"m-?shwari loan|kcb m-?pesa loan|\btala\b|branch (international|microfinance)|"
                             r"\bzenka\b|\bokash\b|hustler fund|\btimiza\b", re.I)
BORROW_MONTHS = 2           # borrowed in 2 or more of the last 3 months...
FULIZA_IN_A_MONTH = 4       # ...or used Fuliza 4 or more times in one month


def _borrowing(s, user_id, pic):
    """Borrowing to get through the month (6 Nov), a strain signal the proposal did not cover. Each Fuliza use
    is cleared by an automatic 'OD Loan Repayment', so the repayments count the uses; repayments to mobile
    lenders (M-Shwari, KCB M-PESA, Tala, Branch, Zenka, Okash, Hustler Fund...) count the rest. A stated rule,
    not a model: flagged when it happened in 2 or more of the last 3 months, or Fuliza 4+ times in one month.
    Shown beside the score; it never changes it."""
    recent = [(m["year"], m["month"]) for m in pic["complete"][-3:]] if not pic["estimated"] else []
    if not recent:
        return None
    first = date(recent[0][0], recent[0][1], 1)
    rows = [t for t in _all_txs(s, user_id) if t.day >= first and t.category == "loan_repayment"]
    per = {k: {"fuliza": 0, "fuliza_KES": 0.0, "lenders_KES": 0.0} for k in recent}
    lenders = Counter()
    for t in rows:
        key = (t.day.year, t.day.month)
        if key not in per:
            continue
        text = " ".join(x for x in (t.description, t.payee, t.label) if x)
        if FULIZA.search(text):
            per[key]["fuliza"] += 1
            per[key]["fuliza_KES"] += t.amount
        else:
            m = DIGITAL_LENDERS.search(text)
            if m:
                per[key]["lenders_KES"] += t.amount
                lenders[m.group(0).title()] += 1
    months_with = sum(1 for v in per.values() if v["fuliza"] or v["lenders_KES"])
    busiest = max(v["fuliza"] for v in per.values())
    return {"flag": months_with >= BORROW_MONTHS or busiest >= FULIZA_IN_A_MONTH,
            "months_with": months_with, "of_months": len(recent),
            "fuliza_times": sum(v["fuliza"] for v in per.values()),
            "fuliza_KES": round(sum(v["fuliza_KES"] for v in per.values())),
            "fuliza_most_in_a_month": busiest,
            "lenders": [name for name, _ in lenders.most_common()],
            "lenders_KES": round(sum(v["lenders_KES"] for v in per.values()))}


def _borrowing_sentence(b):
    parts = []
    if b["fuliza_times"]:
        parts.append(f"used Fuliza {b['fuliza_times']} time(s) (about KES {b['fuliza_KES']:,} repaid)")
    if b["lenders_KES"]:
        parts.append(f"repaid KES {b['lenders_KES']:,} to {', '.join(b['lenders'])}")
    return (f"In the last {b['of_months']} months you " + " and ".join(parts) +
            ". Borrowing to cover gaps means the month started short.")


# ---------- goals tracked from savings (proposal 3.6.5: "automatically tracks progress from transaction data") ----------

def _stamp_goals(new, old):
    """Every goal remembers the month it was set (tracking starts there) and whether the user agreed to count
    savings towards it. The app may not send these fields back, so they are carried over by goal name."""
    before = {str(gl.get("name")): gl for gl in (old or {}).get("goals", []) if isinstance(gl, dict)}
    month = f"{_today():%Y-%m}"
    for gl in (new or {}).get("goals", []):
        if not isinstance(gl, dict):
            continue
        prev = before.get(str(gl.get("name")), {})
        gl["tracking_from"] = str(gl.get("tracking_from") or prev.get("tracking_from") or month)[:7]
        if gl.get("track") not in ("yes", "no") and prev.get("track") in ("yes", "no"):
            gl["track"] = prev["track"]
    return new


def _tracked_goals(s, user_id, data):
    """Money that went into savings since each goal was set: deposits to M-Shwari, KCB M-PESA, lock savings,
    unit trusts or a bank (from statements, net of withdrawals each month) and savings typed in. A deposit counts
    once: goals the user agreed to track take it in deadline order, earliest first (the order 'goals at risk'
    uses). Returns (data with each tracked goal's saved raised, per-goal progress)."""
    data = copy.deepcopy(data or {})
    goals = [gl for gl in data.get("goals", []) if isinstance(gl, dict) and not gl.get("done")]
    if not goals:
        return data, []
    start = min(str(gl.get("tracking_from") or f"{_today():%Y-%m}") for gl in goals)
    first = date(int(start[:4]), int(start[5:7]), 1)
    deposits = [[t.day, float(t.amount)] for t in sorted(
        (t for t in _all_txs(s, user_id) if t.category == "savings" and t.day >= first and not t.one_off),
        key=lambda t: t.day)]
    order = sorted(goals, key=lambda gl: (str(gl.get("deadline") or "9999"), float(gl.get("months_left") or 999)))
    progress = []
    for gl in order:
        since = str(gl.get("tracking_from") or f"{_today():%Y-%m}")
        d0 = date(int(since[:4]), int(since[5:7]), 1)
        found = sum(amt for day, amt in deposits if day >= d0)
        counted = 0.0
        if gl.get("track") == "yes":
            need = max(0.0, float(gl.get("target") or 0) - float(gl.get("saved") or 0))
            for dep in deposits:
                if dep[0] >= d0 and need > 0 and dep[1] > 0:
                    take = min(dep[1], need)
                    dep[1] -= take
                    need -= take
                    counted += take
            gl["saved"] = float(gl.get("saved") or 0) + counted
        progress.append({"name": gl.get("name"), "tracking_from": since, "track": gl.get("track"),
                         "found_KES": round(found), "counted_KES": round(counted)})
    return data, progress


def _records_until(s, user_id):
    """The last day anything was recorded (statement, message or typed in), so screens can say "Up to date
    until 31 Oct" and ask for the rest, instead of quietly going stale."""
    last = max((t.day for t in _all_txs(s, user_id)), default=None)
    return last.isoformat() if last else None


def _snapshot(s, user_id, plain, today, estimated):
    """Keep what the plain forecast says about each coming month. A month that has not begun is updated until it
    begins (the latest forecast made before it); the month in progress is only recorded if nothing was kept
    before it began, and marked as made during the month."""
    # One read for all the months, and a write only when something changed (it ran on every dashboard load:
    # 7 queries each time, found 7 Nov).
    keys = {(f["year"], f["month"]) for f in plain}
    have = {(r.year, r.month): r for r in s.scalars(select(ForecastSnapshot).where(ForecastSnapshot.user_id == user_id))
            if (r.year, r.month) in keys}
    changed = False
    for f in plain:
        y, m = f["year"], f["month"]
        sav = f["breakdown"].get("savings", 0)
        spending = f["total"] - sav
        rng = f.get("range") or {}
        row = have.get((y, m))
        before = (y, m) > (today.year, today.month)
        if row is not None and not before:
            continue                                  # frozen once the month has begun
        low = float(rng["low"] - sav) if rng else None
        high = float(rng["high"] - sav) if rng else None
        basis = "setup" if estimated else "records"
        if row is not None and (row.spending, row.made_on, row.low, row.high, row.basis) == \
                (float(spending), today, low, high, basis):
            continue                                  # already kept today, nothing new
        row = row or ForecastSnapshot(user_id=user_id, year=y, month=m)
        row.spending, row.made_on, row.made_before = float(spending), today, before
        row.low, row.high, row.basis = low, high, basis
        s.add(row)
        changed = True
    if changed:
        s.commit()


def _forecast_checks(s, user_id, pic):
    """Each recorded month the forecast had spoken about: expected against actual spending (saving left out),
    and whether it fell inside the 80% range. The actual figure is stored so the admin view can pool them."""
    if pic["estimated"]:
        return []
    actual = {(m["year"], m["month"]): sum(m[c] for c in SPENDING_CATEGORIES if c != "savings")
              for m in pic["complete"]}
    out = []
    for row in s.scalars(select(ForecastSnapshot).where(ForecastSnapshot.user_id == user_id)
                         .order_by(ForecastSnapshot.year, ForecastSnapshot.month)):
        got = actual.get((row.year, row.month))
        if got is None:
            continue
        if row.actual is None or abs(row.actual - got) >= 1:
            row.actual = float(got)
            s.add(row)
        diff = got - row.spending
        out.append({"year": row.year, "month": row.month, "expected": round(row.spending), "actual": round(got),
                    "diff": round(diff), "pct": round(diff / got, 3) if got else None,
                    "in_range": row.low is not None and row.low <= got <= row.high,
                    "made_before": row.made_before, "basis": row.basis})
    s.commit()
    return out[-6:]


def _checks_sentence(checks):
    fair = [c for c in checks if c["made_before"] and c["pct"] is not None]
    if not fair:
        return None
    off = statistics.mean(abs(c["pct"]) for c in fair)
    inside = sum(1 for c in fair if c["in_range"])
    last = fair[-1]
    word = "more" if last["diff"] > 0 else "less"
    return (f"{calendar.month_name[last['month']]}: we expected KES {last['expected']:,}; you spent KES "
            f"{last['actual']:,}, KES {abs(last['diff']):,} {word}. Over {len(fair)} month(s) the forecast was "
            f"off by {off:.0%} on average, and {inside} of {len(fair)} fell inside its range.")


def _bills_due(pic):
    """Bills with a due date that are late or due within a week, soonest first, with their place in the list
    (for the Paid button)."""
    rows = [dict(o, index=i) for i, o in enumerate((pic["commitments"] or {}).get("obligations", []))
            if o.get("status") in ("overdue", "due_soon")]
    return sorted(rows, key=lambda o: o["due_in_days"])


def _put_aside(scored):
    """What the household can usually put aside a month: income minus spending other than saving, averaged over
    the last 3 months (one month alone swings too much)."""
    recent = scored[-3:]
    if not recent:
        return 0.0
    return statistics.mean(m["income_primary"] - sum(m[c] for c in SPENDING_CATEGORIES if c != "savings")
                           for m in recent)


def _goals_at_risk(pic):
    """Goals the usual put-aside money cannot reach in time. Earlier deadlines are served first; a goal is at
    risk when it and the goals before it need more a month than is usually left. 'realistic_months' is how long
    it would take with what is left after the earlier goals."""
    goals = sorted((pic["commitments"] or {}).get("goals", []), key=lambda g: g["months_left"])
    room = max(0.0, _put_aside(pic["scored"]))
    out, used = [], 0.0
    for gl in goals:
        need = gl["monthly_needed_KES"]
        if need <= 0:
            continue
        if used + need > room:
            free = room - used
            out.append({"name": gl["name"], "monthly_needed_KES": need, "months_left": gl["months_left"],
                        "put_aside_KES": round(room),
                        "realistic_months": math.ceil(gl["remaining_KES"] / free) if free > 0 else None})
        used += need
    return out


# Simple, stated rules of thumb, each one already used elsewhere in the app or common Kenyan budgeting advice.
LIFESTYLE = [
    ("housing", "Rent and housing", "high", 0.30, "Keeping rent to about 30% of income is a common rule of thumb."),
    ("loan_repayment", "Loan repayments", "high", 0.30, "Above 30% of income, debt makes every month tight."),
    ("savings", "Saving", "low", 0.10, "Your budget aims to save 10% of income."),
    ("food_groceries", "Food and groceries", None, None, None),
    ("transport", "Transport", None, None, None),
    ("mobile_money_transfers", "Money sent to family and others", None, None, None),
]


def _lifestyle(pic, betting):
    """How the last 3 months look as shares of income (proposal 3.4.6: rent relative to income and similar)."""
    recent = pic["scored"][-3:]
    income = statistics.mean(m["income_primary"] for m in recent) if recent else 0.0
    if income <= 0:
        return []
    out = []
    for cat, label, bad, line, guide in LIFESTYLE:
        kes = statistics.mean(m[cat] for m in recent)
        if kes <= 0 and bad != "low":
            continue
        share = kes / income
        status = None
        if bad == "high":
            status = "high" if share > line else "ok"
        elif bad == "low":
            status = "low" if share < line else "ok"
        out.append({"key": cat, "label": label, "KES": round(kes), "share": round(share, 3), "status": status,
                    "guide": guide})
    if betting > 0:
        out.append({"key": "betting", "label": "Betting", "KES": round(betting), "share": round(betting / income, 3),
                    "status": None, "guide": "Counted under Fun. Shown on its own because it adds up quietly."})
    return out


def _betting(s, user_id, scored):
    """Average a month paid to betting companies (from statement labels) over the last 3 scored months."""
    recent = scored[-3:]
    if not recent:
        return 0.0
    first = date(recent[0]["year"], recent[0]["month"], 1)
    last = recent[-1]
    after = date(last["year"] + last["month"] // 12, last["month"] % 12 + 1, 1)
    total = sum(t.amount for t in _all_txs(s, user_id)
                if t.label == "Betting" and not t.one_off and first <= t.day < after)
    return float(total) / len(recent)


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
        if not months and not pic["estimated"]:
            return jsonify(has_data=False, income_monthly=round(income), savings_balance=round(pic["savings_balance"]))
        complete, current = pic["complete"], pic["current"]
        basis = complete or months
        outlook = outlook_for_user(s, g.user_id, basis, pic["today"].year, pic["today"].month)
        fc = outlook[0]
        betting = _betting(s, g.user_id, pic["scored"])
        borrowing = _borrowing(s, g.user_id, pic)
        records_until = _records_until(s, g.user_id)
        _snapshot(s, g.user_id, outlook_for_user(s, g.user_id, basis, pic["today"].year, pic["today"].month,
                                                 blend=False), pic["today"], pic["estimated"])
        forecast_checks = _forecast_checks(s, g.user_id, pic)
        saved_budget = _saved_budget(s, g.user_id, pic["today"].year, pic["today"].month)
    health = aff.evaluate({"household": {"household_size": profile.household_size,
                                         "num_dependants": profile.dependants},
                           "months": pic["scored"], "statement_safe": pic["statement_safe"]})
    # Month by month: each completed month scored with only the data up to then (how things were at the time).
    timeline = []
    by_month = aff.timeline(pic["scored"], profile.household_size, profile.dependants, pic["statement_safe"])
    for mo, r in zip(pic["scored"], by_month):
        timeline.append({"year": mo["year"], "month": mo["month"], "state": r["state"], "score": r["score"],
                         "spent": round(sum(mo[c] for c in SPENDING_CATEGORIES if c != "savings")),
                         "saved": round(mo["savings"]), "income": round(mo["income_primary"]),
                         "income_from": mo.get("income_from", "profile"), "estimated": pic["estimated"]})
    counts = Counter(x["state"] for x in timeline)
    summary = None
    if len(timeline) >= 2:
        summary = (f"Past {len(timeline)} months: " +
                   ", ".join(f"{counts[st]} {st}" for st in ("Stable", "Strained", "Critical") if counts[st]) + ".")
        if len(timeline) >= 4:
            recent = statistics.mean(x["score"] for x in timeline[-2:])
            before = statistics.mean(x["score"] for x in timeline[-4:-2])
            summary += (" Improving lately." if recent - before >= 15 else
                        " Getting harder lately." if before - recent >= 15 else " Steady lately.")
    shown = current or basis[-1]
    known = _known(shown)
    # The month in progress: the allowance may not have arrived yet, so "left over" uses the profile income.
    shown_income = income if current is not None else shown.get("income_primary", income)
    spent = {c: round(v) for c, v in known.items() if v > 0 and c != "savings"}
    total = sum(spent.values())
    saved = round(known["savings"])          # saving is not spending: shown on its own line (audit 6)
    notes = []
    if pic["estimated"]:
        notes.append("Based on the rough figures you gave when setting up. Record your spending or upload a "
                     "statement and your real numbers take over.")
    if pic["not_sorted_share"] > 0.10:
        notes.append(f"{pic['not_sorted_share']:.0%} of your spending is not sorted yet. Your totals are exact; sort "
                     "your top payees in Who you pay for a sharper budget.")
    if not pic["estimated"] and not complete:
        notes.append("You have only recorded spending for this month so far. Your health score and forecast "
                     "become reliable once at least one full month is recorded.")
    elif not pic["estimated"] and len(complete) < 3:
        notes.append(f"Based on {len(complete)} full month(s) of records. Add more for a more reliable picture.")
    last = months[-1] if months else None
    today = pic["today"]
    if last and (today.year * 12 + today.month) - (last["year"] * 12 + last["month"]) >= 2:
        notes.append(f"Your latest records are from {calendar.month_name[last['month']]} {last['year']}. Upload a recent "
                     "statement or add spending for an up-to-date picture.")
    from_statement = [m["income_primary"] for m in pic["scored"] if m.get("income_from") == "statement"]
    if from_statement and income > 0 and statistics.median(from_statement) < 0.85 * income:
        notes.append(f"The pay or allowance that actually arrived averaged KES {statistics.median(from_statement):,.0f} a "
                     f"month, less than the KES {round(income):,} in your profile. Your score uses what arrived.")
    if fc["total"] > income > 0:
        notes.append(f"This month's spending is expected to be KES {fc['total']:,}, more than your income of "
                     f"KES {round(income):,}.")
    later = [f for f in outlook[1:] if f["total"] > income > 0]
    if later:
        f = later[0]
        fees = f["breakdown"].get("school_fees", 0)
        notes.append(f"{calendar.month_name[f['month']]} is expected to cost about KES {f['total']:,}, more than your "
                     f"income" + (f", including about KES {fees:,} in school fees" if fees else "") +
                     ". Setting a little aside now will help.")
    due = _bills_due(pic)
    warnings = []
    if saved_budget and current is not None:
        import budget as bud
        warnings = budget_warnings(saved_budget, {c: v for c, v in _known(current).items()}, pic["today"],
                                   bud.model()["variable"])
    at_risk = _goals_at_risk(pic)
    if at_risk:
        r = at_risk[0]
        notes.append(f"To reach {r['name']} in {r['months_left']} month(s) you need KES {r['monthly_needed_KES']:,} a "
                     f"month, but you usually have about KES {r['put_aside_KES']:,} to put aside"
                     + (f", so it would take about {r['realistic_months']} months." if r["realistic_months"]
                        else ", and nothing is left after your other goals.")
                     + " Move the date or lower the target under Commitments.")
    if borrowing and borrowing["flag"]:
        notes.append(_borrowing_sentence(borrowing))
    checked = _checks_sentence(forecast_checks)
    if checked:
        notes.append(checked)
    record = health["track_record"]
    if record["fragile"] and health["score_before"] >= aff.engine()["cutoffs"]["affordable"]:
        notes.append(f"Your score looks at your recent months, which went well. But you spent more than came in during "
                     f"{record['overspent_months']} of the last {record['months']} months, so keep a buffer before "
                     "taking on new costs.")
    return jsonify(has_data=True, income_monthly=round(income), months_count=len(complete),
                   state=health["state_now"], score=health["score_before"], score_explained=SCORE_EXPLAINED, estimated=pic["estimated"],
                   unsorted_share=round(pic["not_sorted_share"], 3), outside_share=round(pic["unsorted_share"], 3),
                   statement_safe=pic["statement_safe"],
                   savings_balance=round(pic["savings_balance"]),
                   latest={"year": shown["year"], "month": shown["month"], "spent": total, "by_category": spent,
                           "saved": saved, "income": round(shown_income),
                           "income_from": "profile" if current is not None else shown.get("income_from", "profile"),
                           "left_over": round(shown_income - total - saved),
                           "partial": current is not None,
                           "one_off": round(one_offs.get((shown["year"], shown["month"]), 0))},
                   history=[{"year": m["year"], "month": m["month"],
                             "spent": round(sum(m[c] for c in SPENDING_CATEGORIES if c != "savings")),
                             "saved": round(m["savings"])} for m in months[-6:]],
                   forecast=fc, outlook=[{k: f[k] for k in ("year", "month", "total", "range", "ahead")
                                          if k in f} | {"school_fees": f["breakdown"].get("school_fees", 0)}
                                         for f in outlook],
                   notes=notes, timeline=timeline, bills_due=due, goals_at_risk=at_risk, budget_warnings=warnings,
                   lifestyle=_lifestyle(pic, betting), timeline_summary=summary, track_record=record,
                   borrowing=borrowing, goal_progress=pic["goal_progress"], records_until=records_until,
                   forecast_checks=forecast_checks, income_gap=_income_gap(pic),
                   # "Since November KES 8,500 went into savings. Count it towards Laptop?" (asked once per goal)
                   goal_suggestions=[x for x in pic["goal_progress"] if x["track"] is None and x["found_KES"] > 0])


def _recommend(pic, prev_limits, py, pm, set_aside=0.0):
    """This month's recommended budget: the Random Forest split (budget.evaluate) fed with the household's income,
    commitments, financial state, own spending and last month's overspending. set_aside: a new everyday cost
    (from 'Can I afford it?') kept back before the everyday money is shared out."""
    import budget as bud
    profile, income = pic["profile"], pic["income"]
    notes = []
    fixed, goal = dict(pic["fixed"]), pic["goal_per_month"]
    complete = pic["complete"]
    # Rent, fees or loans recorded as spending but not entered as commitments: use the usual amount.
    for cat, label in (("housing", "rent"), ("school_fees", "school fees"), ("loan_repayment", "loan repayments")):
        usual = statistics.median([mo[cat] for mo in complete]) if complete else 0
        if not fixed.get(cat) and usual > 0:
            fixed[cat] = round(usual)
            notes.append(f"Your usual {label} (KES {round(usual):,}) is set aside. Add it under Commitments to make it exact.")

    payload = {"income": income, "fixed": fixed, "goal_per_month": goal, "statement_safe": pic["statement_safe"],
               "household": {"household_size": profile.household_size, "num_dependants": profile.dependants,
                             "urban_rural": profile.urban_rural, "formal_job": profile.formal_job}}
    if complete:
        payload["months"] = pic["scored"]          # the same months the dashboard and Afford screen score
    else:
        payload["state"] = "Stable"
        notes.append("Your health state is assumed Stable until a full month of spending is recorded.")
    if complete:
        recent = complete[-6:]
        own = {cat: sum(_known(mo)[cat] for mo in recent) / len(recent) for cat in SPENDING_CATEGORIES}   # sorted only
        # Chama, family support and insurance entered under Commitments are already set aside; take them out of
        # "money sent" so they are not budgeted twice (audit 5.3).
        own["mobile_money_transfers"] = max(0.0, own["mobile_money_transfers"] - float(fixed.get("other_commitments", 0)))
        payload["own_spending"] = {cat: round(v, 2) for cat, v in own.items()
                                   if cat not in ("housing", "school_fees", "loan_repayment", "savings")}
        payload["own_months"] = len(recent)
        payload["own_savings"] = round(own["savings"], 2)
    prev_month = next((mo for mo in complete if (mo["year"], mo["month"]) == (py, pm)), None)
    if isinstance(prev_limits, dict) and prev_month:
        payload["last_month"] = {"limits": prev_limits,
                                 "spent": {cat: _known(prev_month)[cat] for cat in SPENDING_CATEGORIES if cat in prev_limits}}
    if set_aside:
        fixed["other_commitments"] = float(fixed.get("other_commitments", 0)) + set_aside
    plan = bud.evaluate(payload)
    plan["notes"] = notes + plan["notes"]
    _add_extra_lines(plan, complete[-6:] if complete else [])
    _apply_edits(plan, profile.budget_edits or {})
    return plan


def _add_extra_lines(plan, recent):
    """Shopping, health or personal care spent on in at least half of the recent months gets its own line, at
    the household's average; the money comes out of the everyday lines, so the total still fits the income."""
    if len(recent) < 2:
        return plan
    b = plan["budget"]
    extras = {}
    for c in EXTRA_LINES:
        amounts = [mo.get("outside", {}).get(c, 0.0) for mo in recent]
        if sum(1 for a in amounts if a > 0) * 2 >= len(recent) and statistics.mean(amounts) >= 200:
            extras[c] = statistics.mean(amounts)
    if not extras:
        return plan
    import budget as bud
    everyday = [c for c in bud.model()["variable"] if c in b]
    total = sum(float(b[c]) for c in everyday)
    if total <= 0:
        return plan
    take = min(sum(extras.values()), total * 0.5)        # never more than half of the everyday money
    k = take / sum(extras.values())
    for c in everyday:
        b[c] = round(float(b[c]) * (total - take) / total)
    for c, v in extras.items():
        b[c] = round(v * k)
    plan["notes"].append("You spend on " + " and ".join(c.replace("_", " ") for c in extras)
                         + " most months, so " + ("it has its own line" if len(extras) == 1 else "they have their own lines")
                         + ", sized from what you usually spend.")
    return plan


# When money has to be found (a new rent, a loan, raising one line by hand), wants are cut before needs, and no
# line is cut below a floor of what it is now (9 Nov: moving house cut food by 37%, as hard as eating out, and left
# shopping untouched). Order: fun, shopping, personal care; then money sent to family and friends; then needs.
SHRINK_TIERS = [
    (("entertainment", "shopping", "personal_care"), 0.25),
    (("mobile_money_transfers",), 0.50),
    (("food_groceries", "transport", "utilities", "airtime_data", "health"), 0.85),
]


def _shrink(lines, cats, cut):
    """Take `cut` KES out of the lines in `cats`, wants first, each tier down to its floor, in proportion to what
    each line can give. Anything still missing comes from every line in proportion (needs below their usual).
    Returns (new lines, KES taken from needs below their floor)."""
    out = {c: float(lines.get(c, 0)) for c in cats}
    left = max(0.0, float(cut))
    for tier, floor in SHRINK_TIERS:
        room = {c: out[c] * (1 - floor) for c in tier if c in out and out[c] > 0}
        total = sum(room.values())
        if left <= 0 or total <= 0:
            continue
        take = min(left, total)
        for c, r in room.items():
            out[c] -= take * r / total
        left -= take
    below = 0.0
    if left > 0:
        total = sum(out.values())
        for c in out:
            out[c] -= min(out[c], left * out[c] / total) if total > 0 else 0
        below = left
    # Whole shillings that still add up exactly: the rounding remainder goes to the line that was cut the most
    # (never to a protected one), so a budget is never a shilling more or less than the income (found by test,
    # 9 Nov: 30,001 of 30,000).
    rounded = {c: round(v) for c, v in out.items()}
    start = sum(float(lines.get(c, 0)) for c in cats)
    target = round(start - min(float(cut), start))
    if rounded and sum(rounded.values()) != target:
        most_cut = max(rounded, key=lambda c: float(lines.get(c, 0)) - out[c])
        rounded[most_cut] += target - sum(rounded.values())
    return rounded, round(below)


def everyday_lines(plan):
    import budget as bud
    return [c for c in bud.model()["variable"] + EXTRA_LINES if c != "savings" and c in plan["budget"]]


def _apply_edits(plan, edits):
    """The user's own limits win; the other everyday lines are scaled so everyday money still adds up to the same
    total. Savings and commitments are never touched (a budget edit cannot quietly stop saving or paying rent)."""
    everyday = everyday_lines(plan)
    mine = {c: max(0.0, float(v)) for c, v in edits.items() if c in everyday}
    plan["edited"] = sorted(mine)
    if not mine:
        return plan
    b = plan["budget"]
    total = sum(float(b[c]) for c in everyday)
    if sum(mine.values()) > total:                    # asked for more than there is: keep their proportions
        k = total / sum(mine.values())
        mine = {c: v * k for c, v in mine.items()}
    rest = [c for c in everyday if c not in mine]
    left = total - sum(mine.values())
    others = sum(float(b[c]) for c in rest)
    if others > left:                                  # the other lines must give: wants first, needs last
        b.update(_shrink(b, rest, others - left)[0])
    else:
        for c in rest:
            b[c] = round(float(b[c]) * left / others) if others > 0 else round(left / len(rest))
    for c, v in mine.items():
        b[c] = round(v)
    plan["notes"].append("You set " + ", ".join(f"{NOTE_LABELS.get(c, c)} to KES {round(v):,}" for c, v in mine.items())
                         + "; the other everyday lines were adjusted so the total still fits your income.")
    return plan


INCOME_GAP_SHARE = 0.7     # statement income under 70% of the profile income, in most statement months


def _income_gap(pic):
    """When the statement shows clearly less money coming in than the user said they have (an allowance paid to
    a bank and spent by card, cash wages), say so and ask, instead of silently scoring months as poorer than they
    were. Asked once."""
    p = pic["profile"]
    if p is None or p.income_gap_answered or (p.outside_income or 0) > 0 or pic["income"] <= 0:
        return None
    seen = [mo["income_primary"] for mo in pic["complete"] if mo.get("income_from") == "statement"]
    if len(seen) < 2:
        return None
    usual = statistics.median(seen)
    if usual >= INCOME_GAP_SHARE * pic["income"]:
        return None
    return {"statement_KES": round(usual), "profile_KES": round(pic["income"]),
            "gap_KES": round(pic["income"] - usual)}


@bp.post("/me/outside-money")
@login_required
def set_outside_money():
    """Money that never touches M-PESA, roughly per month: {"income": 14000, "spending": 9000}. Added to every
    statement month (income) and spread over the everyday lines in the household's own proportions (spending)."""
    b = _body()
    with session() as s:
        p = s.get(Profile, g.user_id)
        if p is None:
            return jsonify(error="set up your household first"), 400
        p.outside_income = _num(b.get("income", 0), "income")
        p.outside_spending = _num(b.get("spending", 0), "spending")
        p.income_gap_answered = True
        s.commit()
    return jsonify(saved=True), 200


@bp.post("/me/income-gap/dismiss")
@login_required
def dismiss_income_gap():
    """"No, what the statement shows is right": stop asking."""
    with session() as s:
        p = s.get(Profile, g.user_id)
        if p is not None:
            p.income_gap_answered = True
            s.commit()
    return jsonify(saved=True), 200


@bp.put("/me/months/<int:year>/<int:month>/income")
@login_required
def set_month_income(year, month):
    """The user's own figure for one month's money in (a bonus paid to the bank, a month the allowance did not
    come). Wins over the statement and the profile for that month only."""
    if not 1 <= month <= 12:
        raise InputError("month must be 1-12")
    amount = _num(_body().get("amount"), "amount")
    with session() as s:
        row = s.scalar(select(MonthIncome).where(MonthIncome.user_id == g.user_id, MonthIncome.year == year,
                                                 MonthIncome.month == month))
        row = row or MonthIncome(user_id=g.user_id, year=year, month=month, amount=amount)
        row.amount = amount
        s.add(row)
        s.commit()
    return jsonify(saved=True), 200


@bp.delete("/me/months/<int:year>/<int:month>/income")
@login_required
def clear_month_income(year, month):
    with session() as s:
        s.execute(delete(MonthIncome).where(MonthIncome.user_id == g.user_id, MonthIncome.year == year,
                                            MonthIncome.month == month))
        s.commit()
    return jsonify(cleared=True), 200


FIXED_LINES = ("housing", "school_fees", "loan_repayment", "other_commitments")


def _budget_review(budget_data, month):
    """A past month's saved budget against what was really spent: every line, and how many everyday lines were
    kept. month is that month's row from _user_months (or None if nothing was recorded)."""
    lines = _budget_lines(budget_data) or {}
    known = (month or {}).get("known", {})
    outside = (month or {}).get("outside", {})
    rows = []
    for c, planned in lines.items():
        if c == "savings" or (planned <= 0 and not known.get(c) and not outside.get(c)):
            continue
        spent = float(known.get(c, outside.get(c, 0.0)))
        rows.append({"category": c, "budget": round(planned), "spent": round(spent), "diff": round(spent - planned),
                     "fixed": c in FIXED_LINES})
    everyday = [r for r in rows if not r["fixed"] and r["budget"] > 0]
    kept = sum(1 for r in everyday if r["spent"] <= r["budget"])
    unsorted = float(outside.get(UNSORTED, 0.0))
    return {"lines": sorted(rows, key=lambda r: (r["fixed"], -r["budget"])),
            "kept": kept, "everyday_lines": len(everyday),
            "planned": round(sum(r["budget"] for r in rows)), "spent": round(sum(r["spent"] for r in rows) + unsorted),
            "unsorted": round(unsorted),
            "savings_planned": round(float(lines.get("savings", 0))), "saved": round(float(known.get("savings", 0))),
            "notes": [n for n in (budget_data or {}).get("notes", []) if isinstance(n, str)]}


@bp.get("/me/budgets/history")
@login_required
def budget_history():
    """Past months' budgets against what was spent, newest first (8 Nov). A month with records but no saved
    budget says so: Tosha never rebuilds a budget the user did not see."""
    with session() as s:
        months, _, _ = _user_months(s, g.user_id)
        saved = {(b.year, b.month): b.data for b in s.scalars(select(Budget).where(Budget.user_id == g.user_id))}
    today = _today()
    by_key = {(m["year"], m["month"]): m for m in months}
    keys = sorted({k for k in set(by_key) | set(saved) if k < (today.year, today.month)}, reverse=True)[:12]
    out = []
    for k in keys:
        if k in saved:
            out.append({"year": k[0], "month": k[1], "has_budget": True, **_budget_review(saved[k], by_key.get(k))})
        else:
            out.append({"year": k[0], "month": k[1], "has_budget": False})
    return jsonify(months=out), 200


@bp.post("/me/budget-plan/edit")
@login_required
def edit_budget_line():
    """Set one everyday line by hand ({"category": "food_groceries", "amount": 9000}). Remembered for later
    months; this month's budget is rebuilt around it."""
    b = _body()
    cat = b.get("category")
    amount = _num(b.get("amount"), "amount")
    with session() as s:
        profile = s.get(Profile, g.user_id)
        if profile is None:
            return jsonify(error="set up your household first"), 400
        import budget as bud
        if cat not in bud.model()["variable"] + EXTRA_LINES or cat == "savings":
            raise InputError("only everyday lines can be set by hand")
        profile.budget_edits = {**(profile.budget_edits or {}), cat: amount}
        t = _today()
        s.execute(delete(Budget).where(Budget.user_id == g.user_id, Budget.year == t.year, Budget.month == t.month))
        s.commit()
    return budget_plan()


@bp.post("/me/budget-plan/reset")
@login_required
def reset_budget_edits():
    """Back to the recommended budget: forget the lines set by hand and rebuild this month's budget."""
    with session() as s:
        profile = s.get(Profile, g.user_id)
        if profile is not None:
            profile.budget_edits = None
        t = _today()
        s.execute(delete(Budget).where(Budget.user_id == g.user_id, Budget.year == t.year, Budget.month == t.month))
        s.commit()
    return budget_plan()


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
        prev_limits = _budget_lines(saved_prev.data) if saved_prev else None
    if income <= 0:
        return jsonify(error="add your income in your household profile first"), 400
    plan = _recommend(pic, prev_limits, py, pm)
    complete, current = pic["complete"], pic["current"]
    spent = {cat: round(v) for cat, v in (_known(current) if current else {}).items() if v > 0}
    auto_saved = False
    if saved_now_data is None and complete:
        # Save the month's budget the first time it is opened, so next month's overspend rule and forecast can
        # use it even if the user never presses Save (audit 5.4). They can still update it later.
        with session() as s:
            s.add(Budget(user_id=g.user_id, year=y, month=m, data=plan))
            s.commit()
        saved_now_data, auto_saved = plan, True
    # Safe to spend per day: what is left of the everyday limits, spread over the days left (audit 5.5).
    lines = (_budget_lines(saved_now_data) if saved_now_data else None) or plan["budget"]
    everyday = bud.model()["variable"] + [c for c in EXTRA_LINES if c in lines]
    left = sum(float(lines.get(cat, 0)) for cat in everyday) - sum(spent.get(cat, 0) for cat in set(everyday) | set(OUTSIDE))
    days_left = calendar.monthrange(y, m)[1] - pic["today"].day + 1
    return jsonify(year=y, month=m, plan=plan, spent_so_far=spent, saved=saved_now_data, auto_saved=auto_saved,
                   everyday=everyday_lines(plan), edited=plan.get("edited", []), lines=lines,
                   days_in_month=calendar.monthrange(y, m)[1],
                   everyday_left=round(left), days_left=days_left, safe_per_day=round(max(0.0, left) / days_left),
                   warnings=budget_warnings(lines, spent, pic["today"], everyday))


NOTE_LABELS = {"food_groceries": "food", "transport": "transport", "utilities": "power, water and gas",
               "airtime_data": "airtime and data", "mobile_money_transfers": "family, friends and giving",
               "entertainment": "going out and fun"}
WATCH_MIN_KES = 500          # a gap smaller than this is noise, not advice
WATCH_SHARE = 0.10           # ...and so is one under 10% of the budget line


@bp.get("/me/budget-forecast")
@login_required
def budget_forecast():
    """The next three months against the budget (proposal 3.2.3: the forecast feeds the recommendation).
    For this month and the next two: money in, spending at the household's usual pace (the plain forecast model,
    no pull towards the budget, so the comparison is honest), what is left, school fees, and each everyday line's
    budget against the usual pace. Then what it adds up to: the savings path if what is left is saved, the first
    short month and how much to put aside each month before it, the lines most likely to run over, and goals
    the money will not reach. Works from day one on the setup estimates, and says so."""
    import budget as bud
    with session() as s:
        pic = household_picture(s, g.user_id)
        profile, income = pic["profile"], pic["income"]
        if profile is None:
            return jsonify(error="set up your household first"), 400
        if income <= 0:
            return jsonify(error="add your income in your household profile first"), 400
        if not pic["months"] and not pic["estimated"]:
            return jsonify(has_data=False)
        today = pic["today"]
        y, m = today.year, today.month
        py, pm = (y, m - 1) if m > 1 else (y - 1, 12)
        saved_now = s.scalar(select(Budget).where(Budget.user_id == g.user_id, Budget.year == y, Budget.month == m))
        saved_prev = s.scalar(select(Budget).where(Budget.user_id == g.user_id, Budget.year == py, Budget.month == pm))
        prev_limits = _budget_lines(saved_prev.data) if saved_prev else None
        chosen = _budget_lines(saved_now.data) if saved_now else None
        outlook = outlook_for_user(s, g.user_id, pic["complete"] or pic["months"], y, m, blend=False)
        _snapshot(s, g.user_id, outlook, today, pic["estimated"])
    plan = chosen or _recommend(pic, prev_limits, py, pm)["budget"]
    everyday = bud.model()["variable"]
    current = pic["current"]
    rows, watch = [], defaultdict(float)
    for k, f in enumerate(outlook):
        b = f["breakdown"]
        spending = sum(v for c, v in b.items() if c != "savings")
        lines = []
        for c in everyday:
            budget_c, usual_c = round(float(plan.get(c, 0))), round(b.get(c, 0))
            if budget_c <= 0 and usual_c <= 0:
                continue
            gap = usual_c - budget_c
            lines.append({"category": c, "budget": budget_c, "usual": usual_c, "gap": gap})
            if gap >= WATCH_MIN_KES and gap >= WATCH_SHARE * max(budget_c, 1):
                watch[c] += gap
        row = {"year": f["year"], "month": f["month"], "ahead": f["ahead"], "income": round(income),
               "spending": round(spending), "range": f.get("range"), "left_over": round(income - spending),
               "school_fees": round(b.get("school_fees", 0)), "bills": round(sum(b.get(c, 0) for c in
                                                                                  ("housing", "loan_repayment"))),
               "other_spending": round(sum(b.get(c, 0) for c in OUTSIDE)), "lines": lines}
        if k == 0 and current is not None:
            row["spent_so_far"] = round(sum(v for c, v in _known(current).items() if c != "savings"))
        rows.append(row)
    # Follow the money month by month: savings now plus what is left (or missing) each month, at the usual pace
    # and if every everyday line kept to its budget (bills, fees and other spending as forecast either way).
    plan_everyday = sum(float(plan.get(c, 0)) for c in everyday)
    for r in rows:
        usual_everyday = sum(line["usual"] for line in r["lines"])
        r["left_over_on_budget"] = round(r["left_over"] + usual_everyday - plan_everyday)
    path, bal, bal_b = [], pic["savings_balance"], pic["savings_balance"]
    for r in rows:
        bal, bal_b = bal + r["left_over"], bal_b + r["left_over_on_budget"]
        path.append({"year": r["year"], "month": r["month"], "usual_pace": round(bal), "on_budget": round(bal_b)})
    low, low_path = _low_month(pic), None
    if low["status"] == "varies":
        bal_l, low_path = pic["savings_balance"], []
        for r in rows:
            bal_l += r["left_over"] - (r["income"] - low["income_KES"])
            low_path.append({"year": r["year"], "month": r["month"], "savings": round(bal_l)})
    notes, put_aside = [], None
    name = lambda r: calendar.month_name[r["month"]]
    fees = lambda r: f", with about KES {r['school_fees']:,} in school fees" if r["school_fees"] else ""
    runs_out = next((i for i, x in enumerate(path) if x["usual_pace"] < 0), None)
    short = next((i for i, r in enumerate(rows) if r["left_over"] < 0), None)
    if runs_out is None and short is None:
        status = "fine"
        notes.append(f"At your usual pace every month of the next {len(rows)} has money left over.")
    elif runs_out is None:
        status = "tight"
        r = rows[short]
        gap = -r["left_over"]
        notes.append(f"{name(r)} costs KES {gap:,} more than comes in{fees(r)}.")
        if short > 0:
            # The forecast feeding the budget: spread the coming gap over the months before it.
            per = math.ceil(gap / short / 100) * 100
            put_aside = {"for_year": r["year"], "for_month": r["month"], "short_KES": gap, "per_month_KES": per,
                         "months": short}
            notes.append(f"Keep about KES {per:,} a month of what is left aside until then and it is covered.")
        else:
            notes.append("Your savings cover it.")
    else:
        status = "runs_out"
        r = rows[runs_out]
        notes.append(f"At your usual pace your money runs out in {name(r)}{fees(r)}.")
        over = max(0.0, statistics.mean(sum(line["usual"] for line in x["lines"]) for x in rows) - plan_everyday)
        if all(x["on_budget"] >= 0 for x in path):
            notes.append(f"Keeping to your budget gets you through: about KES {round(over, -2):,.0f} a month less on "
                         "everyday spending.")
        else:
            worst = min(path, key=lambda x: x["on_budget"])
            notes.append(f"Even on your budget you would be about KES {-worst['on_budget']:,} short by "
                         f"{calendar.month_name[worst['month']]}. Plan for it now: check a change in Can I afford it?")
    if low_path:
        out_l = next((x for x in low_path if x["savings"] < 0), None)
        notes.append(f"Your income varies: a low month brought KES {low['income_KES']:,}. "
                     + (f"If the coming months were like that, your money would run out in "
                        f"{calendar.month_name[out_l['month']]}." if out_l else
                        "Even then your savings would carry you through the next three months."))
    top = sorted(watch.items(), key=lambda kv: -kv[1])[:3]
    if top:
        c, total_gap = top[0]
        notes.append(f"At your usual pace {NOTE_LABELS.get(c, c)} runs about KES {round(total_gap / len(rows)):,} a "
                     "month over its budget.")
    at_risk = _goals_at_risk(pic)
    based_on = "setup" if pic["estimated"] else "records"
    if pic["estimated"]:
        notes.append("Based on the rough figures you gave at setup. Upload a statement or record spending and "
                     "your own pattern takes over.")
    first = (rows[0]["year"], rows[0]["month"]) if rows else (9999, 1)
    history = [{"year": m["year"], "month": m["month"],
                "spent": round(sum(m[c] for c in SPENDING_CATEGORIES if c != "savings"))}
               for m in pic["months"] if (m["year"], m["month"]) < first][-5:]
    return jsonify(has_data=True, based_on=based_on, months_used=outlook[0]["months_used"], history=history,
                   budget_source="saved" if chosen else "recommended", status=status, months=rows,
                   savings_path=path, savings_now=round(pic["savings_balance"]), put_aside=put_aside,
                   income_pattern=low["status"], low_month=(dict(low, path=low_path) if low_path else None),
                   watch=[{"category": c, "over_per_month": round(v / len(rows))} for c, v in top],
                   goals_at_risk=[{"name": r["name"], "monthly_needed_KES": r["monthly_needed_KES"],
                                   "realistic_months": r["realistic_months"]} for r in at_risk],
                   notes=notes)

def budget_warnings(limits, spent, today, categories):
    """Budget lines running out this month: over the limit, or 80%+ used while well ahead of the calendar (more
    than 15 points ahead of the share of the month gone). Each says the amount left and, at this pace, the
    month-end total. limits/spent: {category: KES}; categories: the everyday lines the budget sets."""
    days = calendar.monthrange(today.year, today.month)[1]
    gone = today.day / days
    out = []
    for cat in categories:
        limit, used = float(limits.get(cat, 0) or 0), float(spent.get(cat, 0) or 0)
        if limit <= 0 or used <= 0:
            continue
        share = used / limit
        if share >= 1 or (share >= 0.8 and share > gone + 0.15):
            out.append({"category": cat, "limit_KES": round(limit), "spent_KES": round(used),
                        "share": round(share, 2), "over": share >= 1, "days_left": days - today.day + 1,
                        "pace_KES": round(used / gone)})
    return sorted(out, key=lambda w: -w["share"])


PRESETS = ("move_house", "new_expense", "new_baby", "purchase", "loan", "savings_goal", "income_change", "plan")
PER = {"month": 1, "term": 3 / 12, "semester": 2 / 12, "year": 1 / 12}     # to a monthly amount
MAX_PLAN_COSTS = 10


def _scenario_from_preset(p, months):
    """Turn a choice from the app ('move house, new rent 18,000') into an affordability-engine scenario.
    Kept on the server so the logic is in one tested place."""
    kind = p.get("preset")
    if kind not in PRESETS:
        raise InputError(f"preset must be one of {', '.join(PRESETS)}")

    def usual(cat):
        return statistics.median([mo[cat] for mo in months]) if months else 0.0

    if kind == "plan":
        return _plan_scenario(p, usual)
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
    except (TypeError, ValueError, OverflowError):
        raise InputError("amount must be a number (negative for a drop in income)")
    if not limits.is_real(delta):
        raise InputError(f"amount must be a normal amount (at most {limits.MAX_AMOUNT:,})")
    word = "rises" if delta >= 0 else "drops"
    sc, title = {"type": "monthly_change", "changes": {}, "income_change": delta}, f"Income {word} by KES {abs(round(delta)):,} a month"
    if p.get("months"):                           # e.g. HELB delayed for 2 months
        sc["months"] = int(_num(p["months"], "months", 1))
        title += f" for {sc['months']} month(s)"
    return sc, title


FIXED_LINES = ("housing", "school_fees", "loan_repayment")


def _plan_costs(p):
    costs = p.get("costs") or []
    if not isinstance(costs, list) or len(costs) > MAX_PLAN_COSTS:
        raise InputError(f"costs must be a list of at most {MAX_PLAN_COSTS} items")
    out = []
    for item in costs:
        if not isinstance(item, dict) or item.get("category") not in SPENDING_CATEGORIES:
            raise InputError(f"each cost needs a category, one of {', '.join(SPENDING_CATEGORIES)}")
        per = item.get("per", "month")
        if per not in PER:
            raise InputError("per must be month, term, semester or year")
        amount = _num(item.get("amount"), "cost amount")
        if amount > 0:
            out.append({"category": item["category"], "amount": amount, "per": per,
                        "label": str(item.get("label") or "")[:40]})
    return out


def _plan_scenario(p, usual):
    """'Plan a change' (6 Nov): one check for a whole decision. Body:
      label, upfront {amount, pay: savings | instalments, months, annual_rate},
      new_rent (the whole new rent; the change is worked out from the usual rent),
      costs [{category, amount, per: month | term | semester | year, label}],
      income (KES a month it brings in; negative for less pay), months (how long; leave out for good),
      add_dependants (people joining the household; used when you go ahead)."""
    changes, parts = {}, []
    if p.get("new_rent") not in (None, ""):
        rent = _num(p.get("new_rent"), "new_rent")
        changes["housing"] = rent - usual("housing")
        parts.append(f"rent of KES {round(rent):,}")
    for item in _plan_costs(p):
        monthly = item["amount"] * PER[item["per"]]
        changes[item["category"]] = changes.get(item["category"], 0.0) + monthly
        what = item["label"] or item["category"].replace("_", " ")
        parts.append(f"{what} KES {round(item['amount']):,} a {item['per']}")
    try:
        income = float(p.get("income") or 0)
    except (TypeError, ValueError, OverflowError):
        raise InputError("income must be a number (negative for less pay)")
    if not limits.is_real(income):
        raise InputError(f"income must be a normal amount (at most {limits.MAX_AMOUNT:,})")
    sc = {"type": "plan", "changes": changes, "income_change": income}
    if p.get("months"):
        sc["months"] = int(_num(p["months"], "months", 1))
    up = p.get("upfront")
    if up:
        if not isinstance(up, dict):
            raise InputError("upfront must be an object with amount and how you pay")
        price = _num(up.get("amount"), "upfront amount", 1)
        pay = up.get("pay", "savings")
        if pay not in ("savings", "instalments"):
            raise InputError("pay must be savings or instalments")
        sc["upfront"] = {"price": price, "pay": pay}
        if pay == "instalments":
            sc["upfront"]["months"] = int(_num(up.get("months", 6), "upfront months", 1))
            sc["upfront"]["monthly_interest"] = _num(up.get("annual_rate", 0), "annual_rate") / 1200
            parts.insert(0, f"KES {round(price):,} upfront over {sc['upfront']['months']} months")
        else:
            parts.insert(0, f"KES {round(price):,} upfront from savings")
    if income:
        parts.append(f"{'bringing in' if income > 0 else 'less pay of'} KES {abs(round(income)):,} a month")
    if not changes and not income and not up:
        raise InputError("add at least one cost, an upfront amount or a change in income")
    label = str(p.get("label") or "Your plan")[:60]
    title = f"{label}: " + ", ".join(parts)
    if sc.get("months"):
        title += f", for {sc['months']} month(s)"
    return sc, title[:200]


def _as_monthly(scenario, result):
    """A plan seen as one monthly change while it costs the most (instalments included), for the budget view."""
    if scenario.get("type") != "plan":
        return scenario
    changes = dict(scenario.get("changes") or {})
    if result.get("instalment_per_month_KES"):
        changes["loan_repayment"] = changes.get("loan_repayment", 0.0) + result["instalment_per_month_KES"]
    return {"type": "monthly_change", "changes": changes, "income_change": scenario.get("income_change", 0)}


def _budget_side_by_side(s, pic, scenario, result):
    """Proposal 3.4.6: 'a side-by-side comparison of current and projected budget allocations'. The same
    recommendation as the Budget screen (_recommend), run again with the change: a new rent, loan or bill becomes
    a fixed line, a new everyday cost is set aside first and shown on its own line, a savings goal raises the
    saving, an income change changes the money shared out. The financial state used is today's. None when the
    household has no income set."""
    if pic["income"] <= 0:
        return None
    today = pic["today"]
    py, pm = (today.year, today.month - 1) if today.month > 1 else (today.year - 1, 12)
    saved_prev = s.scalar(select(Budget).where(Budget.user_id == g.user_id, Budget.year == py, Budget.month == pm))
    prev_limits = _budget_lines(saved_prev.data) if saved_prev else None
    before = _recommend(pic, prev_limits, py, pm)["budget"]
    after_pic, fixed = dict(pic), dict(pic["fixed"])
    everyday_added = {}
    kind = scenario.get("type")
    if kind == "monthly_change":
        for cat, delta in (scenario.get("changes") or {}).items():
            if cat in FIXED_LINES:
                fixed[cat] = max(0.0, float(fixed.get(cat) or before.get(cat, 0)) + delta)
            elif delta > 0:
                everyday_added[cat] = everyday_added.get(cat, 0.0) + delta
        after_pic["income"] = pic["income"] + float(scenario.get("income_change") or 0)
    elif kind == "purchase":
        per = float(result.get("instalment_per_month_KES") or 0)
        fixed["loan_repayment"] = float(fixed.get("loan_repayment") or before.get("loan_repayment", 0)) + per
    elif kind == "savings_goal":
        after_pic["goal_per_month"] = pic["goal_per_month"] + float(scenario.get("extra_per_month") or 0)
    after_pic["fixed"] = fixed
    after = None
    if after_pic["income"] > 0:
        import budget as bud
        try:
            after = dict(_recommend(after_pic, prev_limits, py, pm, sum(everyday_added.values()))["budget"])
        except bud.BudgetInputError:
            after = None
    note = None
    if after is not None:
        # The recommendation for the new situation splits the smaller everyday money afresh, which cuts every line
        # alike. People cut wants first: rebuild the everyday lines from today's plan, cutting wants before needs.
        flex = [c for c in EVERYDAY + EXTRA_LINES if c in before or c in after]
        have, need = sum(float(before.get(c, 0)) for c in flex), sum(float(after.get(c, 0)) for c in flex)
        if need < have:
            new, below = _shrink(before, flex, have - need)
            after.update(new)
            note = ("Fun, shopping and personal care go down first, then money sent to others; food, transport "
                    "and bills stay close to what you spend now.")
            if below > 0:
                note = (f"To fit, essentials like food and transport would have to drop below what you usually "
                        f"spend, by about KES {below:,} a month. That is hard to keep up.")
        for cat, add in everyday_added.items():         # show the new cost on its own line, not as "other"
            after[cat] = after.get(cat, 0) + round(add)
            after["other_commitments"] = after.get("other_commitments", 0) - round(add)
    order = [c for c in BUDGET_LINES if before.get(c) or (after or {}).get(c)]
    return {"lines": [{"category": c, "now": round(before.get(c, 0)),
                       "after": None if after is None else round(after.get(c, 0))} for c in order],
            "note": note if after is not None else "With this change there is no income left to share out."}


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
            return jsonify(error="record your spending for a few weeks first, or add your usual month under "
                                 "Your household, so the answer is about your real money"), 400
        scenario, title = _scenario_from_preset(b, months)
        try:
            result = aff.evaluate({"household": {"household_size": profile.household_size,
                                                 "num_dependants": profile.dependants},
                                   "months": months, "scenario": scenario,
                                   "savings_balance": pic["savings_balance"], "statement_safe": pic["statement_safe"]})
        except aff.AffordabilityInputError as exc:
            raise InputError(str(exc))
        result["title"] = title
        result["months_used"] = len(months)
        borrowing = _borrowing(s, g.user_id, pic)
        if borrowing and borrowing["flag"]:
            result["borrowing"] = borrowing
            result.setdefault("reasons", []).append(
                _borrowing_sentence(borrowing).replace("Borrowing to cover gaps means the month started short.",
                                                       "Keep a buffer before adding this."))
        low = _low_month(pic)
        result["income_pattern"] = low["status"]
        if low["status"] == "varies":
            result["low_month"] = _low_month_check(pic, profile, scenario, low)
            lm = result["low_month"]
            if lm["verdict"] != result["verdict"]:
                result.setdefault("reasons", []).append(
                    f"On {lm['when']} (KES {lm['income_KES']:,} came in) this would be {lm['verdict'].lower()}"
                    + (f": KES {-lm['left_over_KES']:,} short that month." if (lm["left_over_KES"] or 0) < 0 else "."))
        result["budgets"] = (None if result.get("upfront_short_KES") else
                             _budget_side_by_side(s, pic, _as_monthly(scenario, result), result))
        if b.get("preset") == "plan":
            for item in _plan_costs(b):
                if item["per"] != "month":
                    result.setdefault("reasons", []).append(
                        f"{item['label'] or item['category'].replace('_', ' ').capitalize()} is paid as KES "
                        f"{round(item['amount']):,} each {item['per']}: put aside about KES "
                        f"{round(item['amount'] * PER[item['per']]):,} a month so it is ready when due.")
        row = Scenario(user_id=g.user_id, request=b, result=result)
        s.add(row)
        s.commit()
        result["id"] = row.id
    return jsonify(result), 200


@bp.post("/me/explain")
@login_required
def explain_score():
    """'Why this score?' (SHAP, proposal 3.5.7). Empty body: the dashboard score. A 'Can I afford it?' body
    (same presets): the score after it and what moved. Computed on request, because each explanation scores
    12,800 rows (about 0.4 s), and nothing is stored."""
    b = _body()
    with session() as s:
        pic = household_picture(s, g.user_id)
        profile, months = pic["profile"], pic["scored"]
        if profile is None:
            return jsonify(error="set up your household first"), 400
        if not months:
            return jsonify(error="record a month of spending first, so there is a score to explain"), 400
        scenario, title = _scenario_from_preset(b, months) if b.get("preset") else ({"type": "none"}, None)
    try:
        out = aff.explain_request({"household": {"household_size": profile.household_size,
                                                 "num_dependants": profile.dependants},
                                   "months": months, "scenario": scenario})
    except aff.AffordabilityInputError as exc:
        raise InputError(str(exc))
    if out["now"] is None:
        return jsonify(error="explanations are not available on this server yet"), 503
    out["title"] = title
    out["note"] = ("Each part shows how many points it adds to or takes from the score, compared with a typical "
                   f"household (score {out['now']['typical_score']}). The parts add up to your score.")
    return jsonify(out), 200


# ---------------- commitments, budgets, scenarios ----------------

@bp.get("/me/commitments")
@login_required
def get_commitments():
    with session() as s:
        c = s.get(Commitments, g.user_id)
        data = copy.deepcopy(c.data) if c and c.data else {"obligations": [], "debts": [], "goals": []}
        tracked, progress = _tracked_goals(s, g.user_id, data)
    import commitments as cm
    try:        # the same summary a save returns, so the app can show it without saving on every visit
        summary = cm.evaluate(tracked, _today())
    except cm.CommitmentsInputError:
        summary = None
    by_name = {p["name"]: p for p in progress}
    for gl in data.get("goals", []):
        p = by_name.get(gl.get("name"))
        if p:   # 'saved' stays what the user typed; the app shows saved + counted_KES (saving it back is safe)
            gl.update(counted_KES=p["counted_KES"], found_KES=p["found_KES"])
    return jsonify({**data, "summary": summary})


@bp.put("/me/commitments")
@login_required
def put_commitments():
    import commitments as cm
    b = _body()
    b.pop("summary", None)                       # sent back by an app that saved what it read: not stored
    try:
        result = cm.evaluate(b, _today())          # validate with the same rules as /commitments before saving
    except cm.CommitmentsInputError as exc:
        raise InputError(str(exc))
    for gl in b.get("goals", []) or []:
        if isinstance(gl, dict):
            gl.pop("counted_KES", None)
            gl.pop("found_KES", None)
    with session() as s:
        c = s.get(Commitments, g.user_id) or Commitments(user_id=g.user_id)
        c.data = _stamp_goals(b, c.data)
        s.add(c)
        s.commit()
        result = cm.evaluate(_tracked_goals(s, g.user_id, c.data)[0], _today())
    return jsonify(saved=True, summary=result), 200


@bp.post("/me/goals/track")
@login_required
def track_goal():
    """Count savings towards a goal, or not: {"name": "Laptop", "count": true}. Asked once per goal, because
    the app cannot know which goal a deposit was meant for."""
    b = _body()
    with session() as s:
        c = s.get(Commitments, g.user_id)
        data = copy.deepcopy(c.data) if c and c.data else {}
        goal = next((gl for gl in data.get("goals", []) if gl.get("name") == b.get("name")), None)
        if goal is None:
            return jsonify(error="no such goal"), 404
        goal["track"] = "yes" if b.get("count") else "no"
        c.data = data
        s.add(c)
        s.commit()
        _, progress = _tracked_goals(s, g.user_id, data)
    return jsonify(saved=True, goal=next(p for p in progress if p["name"] == b.get("name"))), 200


@bp.post("/me/commitments/paid")
@login_required
def mark_paid():
    """A bill was paid: record the day and move its due date to the next one (a week, month, term... later).
    Body: {"index": position in the obligations list}. Paying early moves from the due date, not from today."""
    import commitments as cm
    b = _body()
    with session() as s:
        c = s.get(Commitments, g.user_id)
        data = copy.deepcopy(c.data) if c and c.data else {}
        items = data.get("obligations") or []
        i = b.get("index")
        if not isinstance(i, int) or not 0 <= i < len(items):
            raise InputError("no such bill")
        o = items[i]
        if not o.get("next_due"):
            raise InputError("add a due date to this bill first")
        due = cm._date(o["next_due"], "next_due")
        o["last_paid"], o["next_due"] = _today().isoformat(), cm.next_due_after(due, o.get("frequency", "monthly")).isoformat()
        c.data = data
        s.add(c)
        s.commit()
        summary = cm.evaluate(data, _today())
    return jsonify(saved=True, next_due=o["next_due"], summary=summary), 200


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
    today = _today()
    if not today.year - 1 <= year <= today.year + 1:
        raise InputError("a budget can be saved for last year, this year or next year")
    data = _body()
    lines = data.get("budget")
    if not isinstance(lines, dict) or not lines:
        raise InputError("send the budget as an object of categories and monthly amounts")
    for c, v in lines.items():
        if c not in BUDGET_LINES:
            raise InputError(f"{c} is not a budget category")
        if not limits.is_real(v) or (v < 0 and c != "savings"):
            raise InputError(f"the budget for {c} must be a normal amount of at least 0")
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


def _apply_plan(s, user_id, req, result, data, profile, label, obligation):
    """Going ahead with a plan: the upfront cost leaves savings or becomes a debt, the new rent and bills become
    commitments (paid at their real frequency), people joining the household are added, and a change in pay
    updates the income. Everyday costs are learnt from spending, as for the other checks."""
    notes = []
    up = req.get("upfront") or {}
    if up:
        price = float(up.get("amount"))
        if up.get("pay") == "instalments":
            pay = float(result.get("instalment_per_month_KES") or price / max(1, int(up.get("months", 6))))
            data["debts"].append({"name": label, "balance": round(price), "annual_rate": float(up.get("annual_rate", 0)),
                                  "monthly_payment": round(pay)})
            notes.append(f"Added {label} as a debt: KES {round(pay):,} a month until it is paid off.")
        else:
            if (profile.savings_balance or 0) < price:
                raise InputError("your savings are less than the upfront amount")
            profile.savings_balance = (profile.savings_balance or 0) - price
            s.add(profile)
            notes.append(f"Paid KES {round(price):,} from savings. Your savings are now KES {round(profile.savings_balance):,}.")
    if req.get("new_rent") not in (None, ""):
        data["obligations"] = [o for o in data["obligations"] if o.get("category") != "housing"]
        obligation("Rent", "housing", float(req["new_rent"]))
    freq = {"month": "monthly", "term": "termly", "semester": "semester", "year": "yearly"}
    everyday = []
    for item in _plan_costs(req):
        cat, name = item["category"], item["label"] or label
        if cat in ("housing", "school_fees", "mobile_money_transfers", "loan_repayment"):
            data["obligations"].append({"name": name, "category": cat if cat in ("housing", "school_fees")
                                        else "other_commitments", "amount": round(item["amount"]),
                                        "frequency": freq[item["per"]]})
            notes.append(f"Added {name} (KES {round(item['amount']):,} a {item['per']}) to your commitments.")
        else:
            everyday.append(name)
    if everyday:
        notes.append(", ".join(everyday) + " is everyday spending: record it under Spending and your budget and "
                     "forecast learn it.")
    extra = int(_num(req.get("add_dependants", 0) or 0, "add_dependants"))
    if extra:
        profile.household_size += extra
        profile.dependants += extra
        s.add(profile)
        notes.append(f"Your household is now {profile.household_size} people, {profile.dependants} dependant(s).")
    income = float(req.get("income") or 0)
    if income and not req.get("months"):
        if income > 0:
            s.add(IncomeSource(user_id=user_id, name=label, amount=round(income), frequency="monthly"))
            notes.append(f"Added KES {round(income):,} a month to your income.")
        else:
            notes.append("Lower your income under Your household when the new pay starts.")
    if req.get("months"):
        notes.append(f"It lasts {int(req['months'])} month(s): remove the commitments when it ends.")
    return notes


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
    elif kind == "plan":
        notes += _apply_plan(s, user_id, req, result, data, profile, label, obligation)
    elif kind == "savings_goal":
        months = int(req.get("months", 6))
        data["goals"].append({"name": label, "target": round(float(req["target"])), "saved": 0, "months_left": months})
        notes.append(f"Added the goal {label}: KES {round(float(req['target']) / months):,} a month is set aside in your budget.")
    elif kind == "income_change":
        delta = float(req["amount"])
        if not req.get("months"):                 # for good: the new income applies from this month on
            before = sum(i.amount * FREQUENCIES[i.frequency] / 12
                         for i in s.scalars(select(IncomeSource).where(IncomeSource.user_id == user_id)))
            _record_income(s, user_id, before, max(0.0, before + delta))
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
        cm.evaluate(data, _today())
    except cm.CommitmentsInputError as exc:
        raise InputError(str(exc))
    c.data = _stamp_goals(data, c.data)
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


# ---------------- M-PESA statements ----------------

MAX_STATEMENT_BYTES = 10 * 1024 * 1024


def _row_ref(r):
    """A transfer and its charge share a receipt number, so the receipt alone is not unique."""
    return f"{r['receipt']}:{round(abs(float(r['amount'])))}:{'c' if r.get('mpesa_type') == 'charges' else 't'}"


def _goal_matches(goals, amount, label):
    """Open goals that look like this purchase: the name appears in the payee, or the target is within 15%."""
    out = []
    for gl in goals or []:
        if gl.get("done"):
            continue
        target = float(gl.get("target") or 0)
        name = str(gl.get("name", ""))
        if (target and abs(target - amount) <= 0.15 * target) or (name and name.lower() in (label or "").lower()):
            out.append({"name": name, "target": round(target), "saved": round(float(gl.get("saved") or 0))})
    return out


def _hints(payee, goals, recent_checks):
    """Clues for a payee the user may not remember: a goal or an earlier 'Can I afford it?' check of about the
    same amount, shortly before the payment."""
    out = []
    for p in payee.get("recent", [])[:3]:
        amount, day = p["amount"], date.fromisoformat(p["date"])
        for gl in goals or []:
            target = float(gl.get("target") or 0)
            if not gl.get("done") and target and abs(target - amount) <= 0.15 * target:
                out.append(f"KES {amount:,} on {day:%d %b} is close to your goal \"{gl.get('name')}\" (KES {target:,.0f}).")
        for when, req, title in recent_checks:
            price = float(req.get("price") or req.get("amount") or 0)
            if price and abs(price - amount) <= 0.15 * price and 0 <= (day - when).days <= 60:
                out.append(f"KES {amount:,} on {day:%d %b}: you checked \"{title}\" on {when:%d %b}.")
    return list(dict.fromkeys(out))[:3]


def _partial_months(period, today):
    """Months the statement only partly covers (a half month looks cheap). The current month is kept: the app
    already treats it as 'so far'."""
    if not period:
        return set()
    start, end = (datetime.strptime(p, "%d %b %Y").date() for p in period)
    out = set()
    if start.day != 1:
        out.add(f"{start.year}-{start.month:02d}")
    last = calendar.monthrange(end.year, end.month)[1]
    if end.day != last and (end.year, end.month) != (today.year, today.month):
        out.add(f"{end.year}-{end.month:02d}")
    return out


def _rules(s, user_id):
    return {r.key: r.choice for r in s.scalars(select(StatementRule).where(StatementRule.user_id == user_id))}


@bp.post("/me/statements/preview")
@login_required
def statement_preview():
    """Read an uploaded M-PESA statement and return what would be imported. Nothing is saved; the PDF and the
    password are only held in memory for this request."""
    import mpesa
    with session() as s:
        blocked = _needs_consent(s)
    if blocked:
        return blocked
    f = request.files.get("file")
    if f is None:
        raise InputError("choose your M-PESA statement (PDF) to upload")
    data = f.read(MAX_STATEMENT_BYTES + 1)
    if len(data) > MAX_STATEMENT_BYTES:
        raise InputError("that file is too big for a statement (10 MB at most)")
    with session() as s:
        remembered = _rules(s, g.user_id)
    try:
        info = mpesa.read_statement(data, request.form.get("password") or None, remembered)
    except mpesa.StatementError as exc:
        raise InputError(str(exc))
    return _preview_answer(info, _partial_months(info["period"], _today()))


@bp.post("/me/messages/preview")
@login_required
def messages_preview():
    """Pasted M-PESA SMS confirmations, read like a statement (6 Nov): keeps the picture current after a
    statement ends. Body: {"text": "TK12AB3CD4 Confirmed. Ksh1,240.00 paid to ..."}. Nothing is saved; the
    rows go to /me/statements/import with "origin": "messages" (hand-entered records are then kept)."""
    import mpesa
    with session() as s:
        blocked = _needs_consent(s)
    if blocked:
        return blocked
    text = str(_body().get("text") or "")
    if len(text) > 200_000:
        raise InputError("that is too much text at once; paste fewer messages")
    with session() as s:
        remembered = _rules(s, g.user_id)
    try:
        info = mpesa.read_messages(text, remembered)
    except mpesa.StatementError as exc:
        raise InputError(str(exc))
    return _preview_answer(info, set(), messages=True)


def _preview_answer(info, skip, messages=False):
    """The review screen's answer for a statement or pasted messages: every row signed for this user."""
    with session() as s:
        remembered = _rules(s, g.user_id)
        seen = set(s.scalars(select(Transaction.ref).where(Transaction.user_id == g.user_id, Transaction.ref.is_not(None))))
        seen |= set(s.scalars(select(MoneyIn.ref).where(MoneyIn.user_id == g.user_id, MoneyIn.ref.is_not(None))))
        c = s.get(Commitments, g.user_id)
        goals = (c.data or {}).get("goals", []) if c else []
        checks = [(sc.created_at.date(), sc.request or {}, (sc.result or {}).get("title", ""))
                  for sc in s.scalars(select(Scenario).where(Scenario.user_id == g.user_id))]
    statement_months = {r["time"][:7] for r in info["rows"] if r["kind"] == "spend"} - skip
    with session() as s:
        # Messages cover a few days, not whole months: hand-entered records are kept, so nothing to replace.
        manual = [] if messages else [
            t for t in s.scalars(select(Transaction).where(Transaction.user_id == g.user_id,
                                                           Transaction.source == "manual"))
            if f"{t.day.year}-{t.day.month:02d}" in statement_months]
    rows = []
    for r in info["rows"]:
        if r["kind"] == "ignore":
            continue
        ref = _row_ref(r)
        rows.append({"n": r["n"], "ref": ref, "date": r["time"][:10], "amount": round(abs(r["amount"]), 2),
                     "direction": "in" if r["amount"] > 0 else "out", "kind": r["kind"], "type": r["mpesa_type"],
                     "category": r["category"], "auto_category": r["auto_category"], "label": r["label"],
                     "payee": r["payee"], "payee_key": r["payee_key"], "source": r["source"],
                     "details": r["details"][:200], "auto_kind": r.get("auto_kind"),
                     "one_off": bool(r.get("suggest_one_off")), "duplicate": ref in seen,
                     "goals": _goal_matches(goals, abs(r["amount"]), r["label"]) if r.get("suggest_one_off") else []})
        rows[-1]["sig"] = _row_sig(g.user_id, rows[-1])
    for p in info["payees"]:
        p["hints"] = _hints(p, goals, checks)
    return jsonify(period=info["period"], checks=info["checks"], months=info["months"], flows=info["flows"],
                   coverage=info["coverage"], payees=info["payees"], usual_monthly_spending=info["usual_monthly_spending"],
                   transactions=rows, new=sum(1 for r in rows if r["kind"] == "spend" and not r["duplicate"]),
                   left_out_months=sorted(skip),
                   manual_overlap={"count": len(manual),
                                   "months": sorted({f"{t.day.year}-{t.day.month:02d}" for t in manual})},
                   origin="messages" if messages else "statement", not_read=info.get("skipped", [])), 200


def _save_rule(s, user_id, key, tag, was):
    rule = s.scalar(select(StatementRule).where(StatementRule.user_id == user_id, StatementRule.key == key))
    if rule is None:
        s.add(StatementRule(user_id=user_id, key=str(key)[:160], choice=tag, was=was))
    else:
        rule.choice = tag


@bp.post("/me/statements/import")
@login_required
def statement_import():
    """Save a reviewed statement. Body: the preview's transactions (with any one-off changes), tags for payees
    {payee_key: category | 'own_account' | 'unsorted'}, the period, and goals a purchase completed."""
    import mpesa
    with session() as s:
        blocked = _needs_consent(s)
    if blocked:
        return blocked
    b = _body()
    rows, tags = b.get("transactions"), b.get("tags") or {}
    if not isinstance(rows, list) or not isinstance(tags, dict):
        raise InputError("send the transactions and tags from the preview")
    if any(v not in mpesa.ALL_TAGS for v in tags.values()):
        raise InputError("one of your choices was not recognised; read the statement again and retry")
    if len(rows) > MAX_STATEMENT_ROWS:
        raise InputError(f"a statement can have at most {MAX_STATEMENT_ROWS:,} records")
    period = b.get("period")
    try:
        skip = _partial_months(period, _today())
    except (TypeError, ValueError, AttributeError):
        raise InputError("the statement period was not recognised; upload the statement again")
    spend, net, was, money_in = [], defaultdict(float), {}, []
    messages = b.get("origin") == "messages"
    sms_saved, covered = [], set()
    for r in rows:
        if not isinstance(r, dict):
            raise InputError("each transaction must be an object")
        if not hmac.compare_digest(str(r.get("sig") or ""), _row_sig(g.user_id, r)):
            raise InputError("these records do not match the statement you uploaded; upload it again")
        try:
            day = date.fromisoformat(str(r.get("date")))
            amount = float(r.get("amount"))
        except (TypeError, ValueError):
            raise InputError("each transaction needs a date (YYYY-MM-DD) and an amount")
        if not limits.is_real(amount) or amount <= 0:
            continue                         # a zero line on a statement moves no money
        row = {"amount": amount if r.get("direction") == "in" else -amount, "kind": r.get("kind"),
               "category": r.get("category"), "source": r.get("source")}
        key = r.get("payee_key")
        if key and key in tags:
            was.setdefault(key, r.get("auto_category"))
            mpesa.apply_tag(row, tags[key])
        month = f"{day.year}-{day.month:02d}"
        if month in skip:
            continue
        covered.add(month)
        if r.get("duplicate"):
            continue
        if row["kind"] == "spend":
            cat = row["category"]
            if cat not in SPENDING_CATEGORIES + OUTSIDE:
                raise InputError(f"category must be one of {', '.join(SPENDING_CATEGORIES + OUTSIDE)}")
            spend.append(dict(day=day, amount=amount, category=cat, label=str(r.get("label") or "")[:60],
                              details=str(r.get("details") or r.get("label") or "")[:200],
                              one_off=bool(r.get("one_off")), ref=str(r.get("ref") or "")[:60] or None,
                              mpesa_type=str(r.get("type") or "")[:20] or None, payee=(r.get("payee") or None),
                              payee_key=key, auto=r.get("auto_category")))
        if messages and row["kind"] == "own_out":
            # Each deposit on its own (pasting the same message twice must not count it twice); a statement
            # for the month later replaces these with its exact monthly figure.
            sms_saved.append(dict(day=day, amount=amount, ref=f"sms-savings:{str(r.get('ref') or '')[:40]}"))
        elif messages and row["kind"] == "own_in":
            pass                                     # a withdrawal: the statement's monthly figure will net it
        elif row["kind"] == "own_out":
            net[month] += amount
        elif row["kind"] == "own_in" and r.get("type") != "loan":
            # Fuliza lends into M-PESA: borrowed money, not money taken out of savings (found 6 Nov).
            net[month] -= amount
        if r.get("direction") == "in" and r.get("type") == "money_in":
            money_in.append(dict(day=day, amount=amount, kind="own_account" if row["kind"] == "own_in" else row["kind"],
                                 auto=r.get("auto_kind"), payee=(r.get("payee") or "")[:120] or None, payee_key=key,
                                 label=str(r.get("label") or "")[:60], details=str(r.get("details") or "")[:200],
                                 ref=str(r.get("ref") or "")[:60] or None))
    done = [str(n) for n in (b.get("completed_goals") or [])]
    months_in = {f"{x['day'].year}-{x['day'].month:02d}" for x in spend}
    notes = []
    with session() as s:
        replaced = 0
        # Pasted messages cover days, not whole months: never replace hand-entered records for them.
        if b.get("replace_manual", True) and b.get("origin") != "messages" and months_in:
            # Hand-entered records in the statement's months would be counted twice (found 4 Nov).
            for t in s.scalars(select(Transaction).where(Transaction.user_id == g.user_id, Transaction.source == "manual")):
                if f"{t.day.year}-{t.day.month:02d}" in months_in:
                    s.delete(t)
                    replaced += 1
        seen = set(s.scalars(select(Transaction.ref).where(Transaction.user_id == g.user_id, Transaction.ref.is_not(None))))
        added = 0
        for x in spend:
            if x["ref"] and x["ref"] in seen:
                continue
            s.add(Transaction(user_id=g.user_id, day=x["day"], amount=x["amount"], category=x["category"],
                              description=x["details"], source="mpesa", one_off=x["one_off"], ref=x["ref"],
                              mpesa_type=x["mpesa_type"], payee=(x["payee"] or "")[:120] or None,
                              payee_key=(x["payee_key"] or "")[:160] or None, label=x["label"],
                              auto_category=x["auto"]))
            seen.add(x["ref"])
            added += 1
        seen_in = set(s.scalars(select(MoneyIn.ref).where(MoneyIn.user_id == g.user_id, MoneyIn.ref.is_not(None))))
        for x in money_in:
            if x["ref"] and x["ref"] in seen_in:
                continue
            s.add(MoneyIn(user_id=g.user_id, day=x["day"], amount=x["amount"], kind=x["kind"],
                          auto_kind="own_account" if x["auto"] == "own_in" else x["auto"], payee=x["payee"],
                          payee_key=(x["payee_key"] or "")[:160] or None, label=x["label"], description=x["details"],
                          ref=x["ref"]))
            seen_in.add(x["ref"])
        if not messages:                        # a statement is exact for its months: it replaces message savings
            for t in s.scalars(select(Transaction).where(Transaction.user_id == g.user_id,
                                                         Transaction.ref.like("sms-savings:%"))):
                if f"{t.day.year}-{t.day.month:02d}" in covered:
                    s.delete(t)
        for x in sms_saved:
            if x["ref"] not in seen:
                s.add(Transaction(user_id=g.user_id, day=x["day"], amount=round(x["amount"], 2), category="savings",
                                  description="Saved (from an M-PESA message)", source="mpesa", ref=x["ref"],
                                  mpesa_type="savings", label="Savings & investments"))
                seen.add(x["ref"])
                added += 1
        for month, kes in net.items():          # saving = more moved into your own accounts than taken out
            ref = f"net-savings:{month}"
            if kes > 0 and ref not in seen:
                y, m = map(int, month.split("-"))
                s.add(Transaction(user_id=g.user_id, day=date(y, m, calendar.monthrange(y, m)[1]), amount=round(kes, 2),
                                  category="savings", description="Saved to your bank or fund (from statement)",
                                  source="mpesa", ref=ref, mpesa_type="savings", label="Savings & investments"))
                added += 1
        if b.get("remember", True):
            for key, tag in tags.items():
                _save_rule(s, g.user_id, key, tag, was.get(key))
        if done:
            notes += _complete_goals(s, g.user_id, done)
        s.commit()
    if replaced:
        notes.append(f"Replaced {replaced} hand-entered record(s) in the same months, so nothing is counted twice.")
    if skip:
        notes.append("Left out part-months at the edge of the statement (" + ", ".join(sorted(skip)) +
                     "): a half month would make your usual spending look too low.")
    return jsonify(imported=added, notes=notes), 200


@bp.delete("/me/statements")
@login_required
def statement_undo():
    """Remove everything imported from statements (to re-import cleanly). Payee tags are kept."""
    with session() as s:
        n = s.execute(delete(Transaction).where(Transaction.user_id == g.user_id, Transaction.source == "mpesa")).rowcount
        n += s.execute(delete(MoneyIn).where(MoneyIn.user_id == g.user_id)).rowcount
        s.commit()
    return jsonify(removed=n), 200


def _complete_goals(s, user_id, names):
    """Tick off goals a purchase completed: mark them done (the budget stops setting money aside) and take what
    was saved for them out of the savings balance (it has been spent)."""
    c = s.get(Commitments, user_id)
    if not (c and c.data):
        return []
    data = copy.deepcopy(c.data)
    profile = s.get(Profile, user_id)
    notes = []
    for goal in data.get("goals", []):
        if goal.get("name") in names and not goal.get("done"):
            goal["done"], goal["done_on"] = True, _today().isoformat()
            saved = float(goal.get("saved") or 0)
            if profile is not None and saved:
                profile.savings_balance = max(0.0, (profile.savings_balance or 0) - saved)
                s.add(profile)
            notes.append(f"Goal reached: {goal['name']}. The budget stops setting money aside for it.")
    c.data = data
    s.add(c)
    return notes


# ---------------- who you pay, and corrections ----------------

def _retag(s, user_id, key, tag):
    """Apply a tag to every payment to this payee that the user has not corrected one by one."""
    n = 0
    for t in s.scalars(select(Transaction).where(Transaction.user_id == user_id, Transaction.payee_key == key)):
        if t.pinned or t.mpesa_type == "charges":
            continue
        t.category = (t.auto_category or t.category) if tag is None else tag
        n += 1
    return n


def _commitment_offer(s, user_id, key, tag):
    """Tagging a payee as rent or school fees: offer to add it to commitments, so the budget sets it aside."""
    if tag not in ("housing", "school_fees") or not key:
        return None
    txs = s.scalars(select(Transaction).where(Transaction.user_id == user_id, Transaction.payee_key == key,
                                              Transaction.one_off.is_(False))).all()
    if not txs:
        return None
    by_month = defaultdict(float)
    for t in txs:
        by_month[(t.day.year, t.day.month)] += t.amount
    per_month = statistics.median(by_month.values())
    termly = tag == "school_fees" and len(by_month) <= 4
    amount = round(statistics.median([t.amount for t in txs]) if termly else per_month)
    name = txs[0].payee or ("Rent" if tag == "housing" else "School fees")
    what = "rent" if tag == "housing" else "school fees"
    return {"category": tag, "name": name, "amount": amount, "frequency": "termly" if termly else "monthly",
            "text": f"Add {what} of KES {amount:,} {'a term' if termly else 'a month'} ({name}) to your commitments? "
                    "Your budget will set it aside first."}


@bp.patch("/me/transactions/<int:tx_id>")
@login_required
def correct_transaction(tx_id):
    """Change a payment. category: just this one (scope 'one'), or always for this payee (scope 'payee').
    one_off: for any payment. amount, date, description: only for entries typed in by hand; a statement's
    payments keep the statement's exact figures and text (they were checked against its totals)."""
    b = _body()
    tag, scope = b.get("category"), b.get("scope", "one")
    edits = {k: b[k] for k in ("amount", "date", "description", "one_off") if k in b}
    if tag is None and not edits:
        raise InputError("nothing to change")
    if tag is not None and tag not in SPENDING_CATEGORIES + OUTSIDE + [OWN_ACCOUNT]:
        raise InputError(f"category must be one of {', '.join(SPENDING_CATEGORIES + OUTSIDE + [OWN_ACCOUNT])}")
    if scope not in ("one", "payee"):
        raise InputError("scope must be one or payee")
    with session() as s:
        t = s.get(Transaction, tx_id)
        if t is None or t.user_id != g.user_id:
            return jsonify(error="no such payment"), 404
        if t.source == "mpesa" and set(edits) - {"one_off"}:
            raise InputError("a payment from a statement keeps the statement's amount, date and text; you can "
                             "change what it is, or mark it as a one-off")
        if "amount" in edits:
            amount = _num(edits["amount"], "amount")
            if amount <= 0:
                raise InputError("amount must be more than 0")
            t.amount = amount
        if "date" in edits:
            t.day = _spend_day(edits["date"])
        if "description" in edits:
            t.description = str(edits["description"] or "")[:200]
        if "one_off" in edits:
            t.one_off = bool(edits["one_off"])
        if tag is None:
            s.commit()
            return jsonify(updated=1, offer=None, transaction=_tx_json(t)), 200
        if scope == "payee":
            if not t.payee_key:
                raise InputError("this payment has no payee to remember; change just this one")
            _save_rule(s, g.user_id, t.payee_key, tag, t.auto_category or t.category)
            n = _retag(s, g.user_id, t.payee_key, tag)
        else:
            t.category, t.pinned, n = tag, True, 1
        s.flush()
        offer = _commitment_offer(s, g.user_id, t.payee_key, tag) if scope == "payee" else None
        s.commit()
    return jsonify(updated=n, offer=offer), 200


@bp.get("/me/payees")
@login_required
def list_payees():
    """Everyone the user pays, from imported statements: payments, total, current category, their tag, and a
    suggestion from Kenyan payment patterns (never applied without the user)."""
    import mpesa
    with session() as s:
        rules = _rules(s, g.user_id)
        txs = s.scalars(select(Transaction).where(Transaction.user_id == g.user_id, Transaction.payee_key.is_not(None))).all()
    groups = defaultdict(list)
    for t in txs:
        groups[t.payee_key].append(t)
    out = []
    for key, ts in groups.items():
        cats = defaultdict(float)
        for t in ts:
            cats[t.category] += t.amount
        pays = [(t.day.isoformat(), t.amount) for t in ts if not t.one_off]
        out.append({"key": key, "payee": ts[0].payee, "type": ts[0].mpesa_type,
                    "type_label": mpesa.TYPES.get(ts[0].mpesa_type or "other", ""), "label": ts[0].label,
                    "count": len(ts), "total": round(sum(t.amount for t in ts)),
                    "last": max(t.day for t in ts).isoformat(), "category": max(cats, key=cats.get),
                    "tag": rules.get(key), "auto_category": ts[0].auto_category,
                    "suggestion": None if key in rules else mpesa.suggest(pays, ts[0].mpesa_type)})
    for p in out:
        p["direction"] = "out"
    spend_total = sum(p["total"] for p in out) or 1
    sorted_money = sum(p["total"] for p in out if p["category"] != UNSORTED)
    with session() as s:
        ins = s.scalars(select(MoneyIn).where(MoneyIn.user_id == g.user_id, MoneyIn.payee_key.is_not(None))).all()
    groups_in = defaultdict(list)
    for x in ins:
        groups_in[x.payee_key].append(x)
    for key, xs in groups_in.items():
        out.append({"key": key, "payee": xs[0].payee, "type": "money_in", "direction": "in", "type_label": "Money in",
                    "label": xs[0].label, "count": len(xs), "total": round(sum(x.amount for x in xs)),
                    "last": max(x.day for x in xs).isoformat(), "category": xs[0].kind, "tag": rules.get(key),
                    "auto_category": xs[0].auto_kind, "suggestion": None})
    out.sort(key=lambda p: (p["direction"] == "in", -p["total"]))      # who you pay first, then who pays you
    return jsonify(payees=out[:250], sorted_share=round(sorted_money / spend_total, 3)), 200


@bp.put("/me/payees")
@login_required
def tag_payee():
    """Always treat this payee as a category (or the user's own account). Updates past payments too."""
    import mpesa
    b = _body()
    key, tag = b.get("key"), b.get("tag")
    if not key or tag not in mpesa.ALL_TAGS:
        raise InputError("choose what this payee is")
    if key.startswith("in:"):                         # money coming in: pay or allowance, own account, received
        if tag not in mpesa.IN_TAGS:
            raise InputError("money coming in can be your pay or allowance, a mix, your own money, paid back or a "
                             "gift, or a bonus or one-off")
        with session() as s:
            xs = s.scalars(select(MoneyIn).where(MoneyIn.user_id == g.user_id, MoneyIn.payee_key == key)).all()
            _save_rule(s, g.user_id, key, tag, xs[0].auto_kind if xs else None)
            for x in xs:
                if not x.pinned:                      # a payment changed on its own keeps its own answer
                    x.kind = tag
            s.commit()
        return jsonify(updated=len(xs), offer=None), 200
    with session() as s:
        first = s.scalar(select(Transaction).where(Transaction.user_id == g.user_id, Transaction.payee_key == key))
        _save_rule(s, g.user_id, key, tag, first.auto_category if first else None)
        n = _retag(s, g.user_id, key, tag)
        s.flush()
        offer = _commitment_offer(s, g.user_id, key, tag)
        s.commit()
    return jsonify(updated=n, offer=offer), 200


@bp.delete("/me/payees")
@login_required
def untag_payee():
    """Undo a payee tag: payments go back to how the statement reader sorted them (except one-by-one fixes)."""
    key = request.args.get("key")
    if not key:
        raise InputError("send the payee key")
    with session() as s:
        s.execute(delete(StatementRule).where(StatementRule.user_id == g.user_id, StatementRule.key == key))
        n = _retag(s, g.user_id, key, None)
        for x in s.scalars(select(MoneyIn).where(MoneyIn.user_id == g.user_id, MoneyIn.payee_key == key)):
            if not x.pinned:
                x.kind = x.auto_kind or x.kind
                n += 1
        s.commit()
    return jsonify(updated=n), 200


@bp.get("/me/money-in")
@login_required
def list_money_in():
    """The payments from one source of money coming in (?key=), newest first, so one can be changed on its own
    (NCBA paying a salary and the user moving their own money from NCBA look the same on a statement)."""
    key = request.args.get("key")
    if not key:
        raise InputError("send the source key")
    with session() as s:
        xs = s.scalars(select(MoneyIn).where(MoneyIn.user_id == g.user_id, MoneyIn.payee_key == key)
                       .order_by(MoneyIn.day.desc())).all()
        return jsonify(payments=[{"id": x.id, "date": x.day.isoformat(), "amount": x.amount, "kind": x.kind,
                                  "pinned": bool(x.pinned)} for x in xs]), 200


@bp.patch("/me/money-in/<int:mid>")
@login_required
def change_money_in(mid):
    """This payment only: what one payment coming in was (pay, own money, a bonus...). The source's tag leaves
    it alone from now on."""
    import mpesa
    kind = _body().get("kind")
    if kind not in mpesa.IN_TAGS:
        raise InputError("money coming in can be your pay or allowance, a mix, your own money, paid back or a "
                         "gift, or a bonus or one-off")
    with session() as s:
        x = s.get(MoneyIn, mid)
        if x is None or x.user_id != g.user_id:
            return jsonify(error="not found"), 404
        x.kind, x.pinned = kind, True
        s.commit()
    return jsonify(changed=True), 200


@bp.post("/me/payees/commitment")
@login_required
def payee_commitment():
    """Accept the offer: add rent or school fees for this payee to commitments (rent replaces the old rent)."""
    import commitments as cm
    b = _body()
    cat, name = b.get("category"), str(b.get("name") or "")[:60]
    if cat not in ("housing", "school_fees"):
        raise InputError("category must be housing or school_fees")
    amount = _num(b.get("amount"), "amount", 1)
    freq = b.get("frequency", "monthly")
    with session() as s:
        c = s.get(Commitments, g.user_id) or Commitments(user_id=g.user_id, data={})
        data = copy.deepcopy({"obligations": [], "debts": [], "goals": [], **(c.data or {})})
        if cat == "housing":
            data["obligations"] = [o for o in data["obligations"] if o.get("category") != "housing"]
        data["obligations"].append({"name": name or ("Rent" if cat == "housing" else "School fees"), "category": cat,
                                    "amount": round(amount), "frequency": freq})
        try:
            cm.evaluate(data, _today())
        except cm.CommitmentsInputError as exc:
            raise InputError(str(exc))
        c.data = data
        s.add(c)
        s.commit()
    return jsonify(saved=True), 200


# ---------------- admin (service health, model register, users) ----------------

def _admin_emails():
    """Admin accounts are named in the ADMIN_EMAILS environment variable (comma-separated), never in code."""
    return {e.strip().lower() for e in os.environ.get("ADMIN_EMAILS", "").split(",") if e.strip()}


def _is_admin(s, user_id):
    u = s.get(User, user_id)
    return u is not None and u.email.lower() in _admin_emails()


SERVICE_STATUS = {"check": lambda: {}}    # app.py fills this in (the forecast service's data status)

def _mask(email):
    name, _, domain = email.partition("@")
    return f"{name[:1]}***@{domain}"


@bp.get("/me/role")
@login_required
def my_role():
    with session() as s:
        admin = _is_admin(s, g.user_id)
        return jsonify(admin=admin, role="admin" if admin else "user"), 200


@bp.get("/admin/overview")
@login_required
def admin_overview():
    """Service health, model register and users, for admin accounts only. Users appear with masked emails and
    record counts; no one's spending, income or payees are shown."""
    models_dir = Path(__file__).resolve().parent / "models"
    with session() as s:
        if not _is_admin(s, g.user_id):
            return jsonify(error="admins only"), 403
        users = s.scalars(select(User).order_by(User.created_at.desc())).all()
        profiles = set(s.scalars(select(Profile.user_id)))
        counts, statement_users = defaultdict(int), set()
        for uid, src in s.execute(select(Transaction.user_id, Transaction.source)):
            counts[uid] += 1
            if src == "mpesa":
                statement_users.add(uid)
        checks = defaultdict(int)
        for (uid,) in s.execute(select(Scenario.user_id)):
            checks[uid] += 1
        n_tx = sum(counts.values())
        n_checks = sum(checks.values())
        fair = s.scalars(select(ForecastSnapshot).where(ForecastSnapshot.actual.is_not(None),
                                                        ForecastSnapshot.made_before.is_(True),
                                                        ForecastSnapshot.basis == "records")).all()
    now = _now()
    joined = [u.created_at if u.created_at.tzinfo else u.created_at.replace(tzinfo=timezone.utc) for u in users]
    register = []
    for m in MODEL_REGISTER:
        f = models_dir / m["file"]
        register.append({**m, "present": f.exists(),
                         "size_mb": round(f.stat().st_size / 1e6, 1) if f.exists() else None,
                         "updated": datetime.fromtimestamp(f.stat().st_mtime, timezone.utc).date().isoformat()
                         if f.exists() else None})
    return jsonify(
        service={"status": "ok", "database": _DB["engine"].dialect.name, "email": mailer.configured(),
                 **SERVICE_STATUS["check"]()},
        # Where rate limits read the caller's address (audit A-04); "CF-Connecting-IP" is the safe answer.
        client_ip_source=_client_ip_source()[1],
        users={"total": len(users), "with_household": len(profiles), "with_statement": len(statement_users),
               "agreed_privacy": sum(1 for u in users if u.consent_version),
               "joined_7_days": sum(1 for j in joined if (now - j).days < 7),
               "records": n_tx, "affordability_checks": n_checks},
        models=register,
        # The forecast on real users' months, made before each month began (for Chapter 5): no user's figures,
        # only the pooled error.
        forecast_on_real_months=None if not fair else {
            "months": len(fair), "users": len({f.user_id for f in fair}),
            "mae_KES": round(statistics.mean(abs(f.actual - f.spending) for f in fair)),
            "wape": round(sum(abs(f.actual - f.spending) for f in fair) / (sum(f.actual for f in fair) or 1), 3),
            "inside_range": round(sum(1 for f in fair if f.low is not None and f.low <= f.actual <= f.high)
                                  / len(fair), 3)},
        recent_users=[{"id": u.id, "email": _mask(u.email), "joined": u.created_at.date().isoformat(),
                       "household": u.id in profiles, "records": counts.get(u.id, 0),
                       "statement": u.id in statement_users, "checks": checks.get(u.id, 0),
                       "blocked": u.blocked_at is not None,
                       "admin": u.email.lower() in _admin_emails()} for u in users[:50]]), 200


@bp.get("/admin/reports")
@login_required
def admin_reports():
    """The examiner pages of the admin console: each model (what the proposal said, what was built, its result
    against the baseline) and each dataset. Figures come from model_register.py, which copies them from
    docs/experiments.md, so nothing is typed into the app."""
    models_dir = Path(__file__).resolve().parent / "models"
    with session() as s:
        if not _is_admin(s, g.user_id):
            return jsonify(error="admins only"), 403
    models = []
    for m in MODEL_REGISTER:
        f = models_dir / m["file"]
        models.append({**m, "present": f.exists(),
                       "size_mb": round(f.stat().st_size / 1e6, 1) if f.exists() else None,
                       "updated": datetime.fromtimestamp(f.stat().st_mtime, timezone.utc).date().isoformat()
                       if f.exists() else None})
    return jsonify(models=models, datasets=DATASETS), 200


@bp.get("/me/export")
@login_required
def export_my_data():
    """Everything the app keeps about the user, in one JSON file (Data Protection Act 2019: the right to a copy
    of one's data). Statement files were never kept, so they are not in it."""
    def rows(s, model, order):
        return list(s.scalars(select(model).where(model.user_id == g.user_id).order_by(order)))
    with session() as s:
        user, profile, c = s.get(User, g.user_id), s.get(Profile, g.user_id), s.get(Commitments, g.user_id)
        data = {
            "exported_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "about": "Everything Tosha keeps about you. Uploaded statement files and passwords are "
                     "never kept, so they are not here.",
            "account": {"email": user.email, "created_at": user.created_at.isoformat() if user.created_at else None,
                        "privacy_notice_agreed": user.consent_version,
                        "agreed_at": user.consent_at.isoformat() if user.consent_at else None},
            "household": None if profile is None else {
                "household_size": profile.household_size, "dependants": profile.dependants,
                "urban_rural": profile.urban_rural, "formal_job": profile.formal_job,
                "pays_own_fees": profile.pays_own_fees, "savings_balance": profile.savings_balance,
                "usual_month_estimates": profile.estimates, "low_month_income": profile.income_low,
                "name": profile.name, "income_types": profile.income_types, "studying": profile.studying,
                "children_in_school": profile.children_in_school},
            "income_history": [{"from_year": r.year, "from_month": r.month, "monthly": r.monthly}
                               for r in rows(s, IncomeHistory, IncomeHistory.id)],
            "income_sources": [{"name": i.name, "amount": i.amount, "frequency": i.frequency}
                               for i in rows(s, IncomeSource, IncomeSource.id)],
            "spending": [_tx_json(t) for t in rows(s, Transaction, Transaction.day)],
            "money_in": [{"date": m.day.isoformat(), "amount": m.amount, "kind": m.kind, "payee": m.payee,
                          "label": m.label, "description": m.description} for m in rows(s, MoneyIn, MoneyIn.day)],
            "commitments": c.data if c else None,
            "budgets": [{"year": b.year, "month": b.month, "budget": b.data} for b in rows(s, Budget, Budget.id)],
            "affordability_checks": [{"created_at": sc.created_at.isoformat(), "asked": sc.request, "answer": sc.result}
                                     for sc in rows(s, Scenario, Scenario.id)],
            "payee_tags": [{"payee": r.key, "tag": r.choice} for r in rows(s, StatementRule, StatementRule.id)],
            "ratings": [{"at": r.created_at.isoformat(), "where": r.place, "score": r.score}
                        for r in rows(s, Rating, Rating.id)],
            "forecasts_kept": [{"year": f.year, "month": f.month, "expected_spending": f.spending,
                                "made_on": f.made_on.isoformat(), "actual": f.actual}
                               for f in rows(s, ForecastSnapshot, ForecastSnapshot.id)],
        }
    return jsonify(data), 200


def _delete_user(s, user_id):
    """Remove a user and everything kept about them (used by the user themselves and by an admin)."""
    for table in (MoneyIn, StatementRule, Scenario, Budget, Commitments, Transaction, IncomeSource, Profile,
                  RevokedToken, ForecastSnapshot, IncomeHistory, Rating, PasswordReset, MonthIncome):
        s.execute(delete(table).where(table.user_id == user_id))
    s.execute(delete(User).where(User.id == user_id))
    s.commit()


@bp.delete("/me")
@login_required
def delete_account():
    """Privacy: a user (or a tester after the study) can remove everything about them."""
    with session() as s:
        _delete_user(s, g.user_id)
    return jsonify(deleted=True), 200


@bp.delete("/admin/users/<int:uid>")
@login_required
def admin_delete_user(uid):
    """Manage user accounts (proposal 3.4.1): an admin can remove an account and all its data, for example a
    volunteer's after the study. Admin accounts cannot be removed here, including one's own."""
    with session() as s:
        if not _is_admin(s, g.user_id):
            return jsonify(error="admins only"), 403
        user = s.get(User, uid)
        if user is None:
            return jsonify(error="no such account"), 404
        if user.email.lower() in _admin_emails():
            return jsonify(error="admin accounts are removed by changing ADMIN_EMAILS, not here"), 400
        _delete_user(s, uid)
        s.add(AdminAction(admin_id=g.user_id, action="delete", target_id=uid))
        s.commit()
    monitor.log_event("account", "Account deleted by an admin")
    return jsonify(deleted=True), 200


@bp.post("/admin/users/<int:uid>/block")
@login_required
def admin_block_user(uid):
    """Manage user accounts: pause an account ({"blocked": true}) or let it back in ({"blocked": false}). A paused
    account cannot log in or use the app; its data is kept. Admin accounts cannot be paused."""
    b = _body()
    blocked = b.get("blocked")
    if not isinstance(blocked, bool):
        raise InputError("blocked must be true or false")
    with session() as s:
        if not _is_admin(s, g.user_id):
            return jsonify(error="admins only"), 403
        user = s.get(User, uid)
        if user is None:
            return jsonify(error="no such account"), 404
        if user.email.lower() in _admin_emails():
            return jsonify(error="admin accounts cannot be paused"), 400
        user.blocked_at = _now() if blocked else None
        s.add(AdminAction(admin_id=g.user_id, action="block" if blocked else "unblock", target_id=uid))
        s.commit()
    monitor.log_event("account", "Account paused by an admin" if blocked else "Account let back in by an admin")
    return jsonify(blocked=blocked), 200


@bp.get("/admin/validation")
@login_required
def admin_validation():
    """Evidence from real use, pooled with no names or amounts per person: how users rate the outputs, how
    often the statement reader's sorting was kept or corrected, which features are used, and admin actions."""
    with session() as s:
        if not _is_admin(s, g.user_id):
            return jsonify(error="admins only"), 403
        ratings = s.scalars(select(Rating)).all()
        txs = s.execute(select(Transaction.category, Transaction.auto_category, Transaction.amount,
                               Transaction.user_id).where(Transaction.source == "mpesa")).all()
        sources = Counter(src for (src,) in s.execute(select(Transaction.source)))
        scen = s.execute(select(Scenario.request, Scenario.result, Scenario.user_id)).all()
        actions = s.scalars(select(AdminAction).order_by(AdminAction.at.desc(), AdminAction.id.desc()).limit(50)).all()
        # Budget lines kept in past months, pooled over everyone (no names, no amounts per person).
        today = _today()
        b_kept = b_lines = b_months = 0
        for uid in set(s.scalars(select(Budget.user_id))):
            months = {(m["year"], m["month"]): m for m in _user_months(s, uid)[0]}
            for b in s.scalars(select(Budget).where(Budget.user_id == uid)):
                if (b.year, b.month) >= (today.year, today.month) or (b.year, b.month) not in months:
                    continue
                r = _budget_review(b.data, months[(b.year, b.month)])
                b_kept, b_lines, b_months = b_kept + r["kept"], b_lines + r["everyday_lines"], b_months + 1
        statement_users = {u for *_, u in txs}

    def rated(where):
        xs = [r.score for r in ratings if r.place == where]
        return {"count": len(xs), "people": len({r.user_id for r in ratings if r.place == where}),
                "mean": round(statistics.mean(xs), 2) if xs else None,
                "spread": {str(k): xs.count(k) for k in range(1, 6)}}

    auto = [t for t in txs if t.auto_category and t.auto_category != UNSORTED]
    kept = [t for t in auto if t.category == t.auto_category]
    later = [t for t in txs if (t.auto_category in (None, UNSORTED)) and t.category != UNSORTED]
    money = sum(t.amount for t in txs) or 1
    presets = Counter((r or {}).get("preset", "other") for r, _, _ in scen)
    applied = sum(1 for _, res, _ in scen if (res or {}).get("applied"))
    return jsonify(
        ratings={"overview": rated("overview"), "afford": rated("afford")},
        sorting=None if not txs else {
            "payments": len(txs), "people": len(statement_users),
            "auto_sorted": len(auto), "kept": len(kept), "corrected": len(auto) - len(kept),
            "precision": round(len(kept) / len(auto), 3) if auto else None,
            "precision_by_money": round(sum(t.amount for t in kept) / (sum(t.amount for t in auto) or 1), 3)
            if auto else None,
            "auto_share_by_money": round(sum(t.amount for t in auto) / money, 3),
            "sorted_by_user": len(later),
            "still_unsorted": sum(1 for t in txs if t.category == UNSORTED)},
        usage={"checks": len(scen), "people_checking": len({u for *_, u in scen}), "applied": applied,
               "by_preset": dict(presets.most_common()), "records_by_source": dict(sources),
               "ratings": len(ratings)},
        budgets={"months": b_months, "lines": b_lines, "kept": b_kept,
                 "share_kept": round(b_kept / b_lines, 3) if b_lines else None},
        admin_actions=[{"at": a.at.isoformat(timespec="minutes"), "action": a.action, "account": a.target_id}
                       for a in actions]), 200


@bp.get("/admin/performance")
@login_required
def admin_performance():
    """Monitor system performance and view system logs (proposal 3.3 and 3.4.1): response times, database time
    and queries per screen, error rates and recent events since the server started. No personal data."""
    with session() as s:
        if not _is_admin(s, g.user_id):
            return jsonify(error="admins only"), 403
    return jsonify(**monitor.summary(), db_round_trip_ms=monitor.db_round_trip_ms(_DB["engine"])), 200
