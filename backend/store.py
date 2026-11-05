"""Data layer (capstone): PostgreSQL in production (Neon), SQLite on a laptop and in tests.

The engines (forecast, affordability, budget, commitments) stay stateless calculators. This module stores
what each user enters and what they decide, behind sign-up/log-in, so the app works across devices and the
dynamic budget can see last month. Connection string comes from DATABASE_URL (never from code).
"""
import calendar
import copy
import hashlib
import os
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
                        create_engine, delete, inspect, select, text)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker
from sqlalchemy.pool import StaticPool
from werkzeug.security import check_password_hash, generate_password_hash

import affordability as aff

ROOT = Path(__file__).resolve().parent.parent
TOKEN_DAYS = 30
SPENDING_CATEGORIES = aff.CATS
UNSORTED = "unsorted"          # a statement payment whose category is not certain (never guessed)
# Spending that is known but has no place in the models' 10 categories (or is not known at all): shown by its
# real name, spread over everyday categories for the engines like unsorted money.
OUTSIDE = [UNSORTED, "shopping", "health", "personal_care", "other", "charges"]
OWN_ACCOUNT = "own_account"    # tagged by the user as moving money to their own account: not spending
EVERYDAY = ["food_groceries", "transport", "utilities", "airtime_data", "mobile_money_transfers", "entertainment"]
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
    # Which privacy notice the user agreed to, and when (Data Protection Act 2019: consent must be recorded).
    consent_version: Mapped[str | None] = mapped_column(String(20), nullable=True)
    consent_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


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
                        "users": {"consent_version": "VARCHAR(20)", "consent_at": "TIMESTAMP"}}.items():
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


def _stamp(user):
    """A short fingerprint of the password hash, carried in the token: changing the password changes it, so every
    token issued before (a lost phone, a shared laptop) stops working."""
    return hashlib.sha256(user.password_hash.encode()).hexdigest()[:16]


def _token(user):
    return _serializer().dumps({"u": user.id, "p": _stamp(user)})


def login_required(fn):
    @wraps(fn)
    def wrapper(*args, **kwargs):
        header = request.headers.get("Authorization", "")
        token = header[7:] if header.startswith("Bearer ") else ""
        try:
            data = _serializer().loads(token, max_age=TOKEN_DAYS * 86400)
        except SignatureExpired:
            return jsonify(error="your session has expired, log in again"), 401
        except BadSignature:
            return jsonify(error="log in first"), 401
        if not isinstance(data, dict):                 # a token from before 5 Nov: log in once more
            return jsonify(error="please log in again"), 401
        with session() as s:
            user = s.get(User, data.get("u"))
            if user is None or _stamp(user) != data.get("p"):
                return jsonify(error="your password was changed or the account was removed, log in again"), 401
        g.user_id = user.id
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
        if b.get("consent") is True:             # the sign-up screen shows the notice with a tick box
            user.consent_version, user.consent_at = PRIVACY["version"], _now()
        s.add(user)
        s.commit()
        return jsonify(token=_token(user), user_id=user.id), 201


# ---------------- privacy notice and consent (Kenya Data Protection Act 2019) ----------------

PRIVACY = {
    "version": "2026-11-05",
    "title": "How this app uses your data",
    "sections": [
        {"title": "Who runs this app",
         "text": "This app is a final-year project by Kevin Kaniaru, a Computer Science student at Strathmore "
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
                 "account at any time under Your household. Deleting removes all your data immediately and "
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
    if _recent(("login-fail", email), 900) >= 5:
        return jsonify(error="too many wrong passwords for this account, wait 15 minutes"), 429
    with session() as s:
        user = s.scalar(select(User).where(User.email == email))
        if not user or not check_password_hash(user.password_hash, str(b.get("password", ""))):
            _record(("login-fail", email))
            return jsonify(error="wrong email or password"), 401
        return jsonify(token=_token(user), user_id=user.id), 200


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
        return jsonify(token=_token(user), changed=True), 200


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
                       savingsBalance=p.savings_balance or 0.0, estimates=p.estimates or {},
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
    est = b.get("estimates") or {}
    if not isinstance(est, dict) or any(k not in SPENDING_CATEGORIES for k in est):
        raise InputError("estimates must be an object of spending categories and monthly amounts")
    estimates = {k: _num(v or 0, f"estimate for {k}") for k, v in est.items() if v}
    with session() as s:
        p = s.get(Profile, g.user_id) or Profile(user_id=g.user_id)
        p.household_size, p.dependants, p.urban_rural = size, deps, where
        p.formal_job, p.pays_own_fees = bool(b.get("formalJob")), bool(b.get("paysOwnFees"))
        p.savings_balance = _num(b.get("savingsBalance", 0) or 0, "savingsBalance")
        p.estimates = estimates
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


@bp.get("/me/transactions/summary")
@login_required
def transaction_summary():
    """One line per month, newest first: usual spending by category, one-offs apart, the user's own money moving
    left out (same rules as the app's month cards), and how many records the month holds."""
    q = select(Transaction.day, Transaction.amount, Transaction.category, Transaction.one_off, Transaction.source) \
        .where(Transaction.user_id == g.user_id)
    months, statement = {}, False
    with session() as s:
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
    rows = [months[k] for k in sorted(months, reverse=True)]
    return jsonify(months=rows, has_statement=statement), 200


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
    # Income actually received, when the user has tagged a source in a statement as their pay or allowance. For
    # the months a statement covers, that replaces the profile figure (a late or short allowance then shows);
    # other months keep the profile income.
    ins = s.scalars(select(MoneyIn).where(MoneyIn.user_id == user_id)).all()
    actual, mixed, covered = {}, {}, set()
    for x in ins:
        key = (x.day.year, x.day.month)
        covered.add(key)
        if x.kind == "income":
            actual[key] = actual.get(key, 0.0) + x.amount
        elif x.kind == "mixed":                      # pay and the user's own money together
            mixed[key] = mixed.get(key, 0.0) + x.amount
    # Only once the user has tagged a source as their pay or allowance: salary lines alone would ignore an
    # allowance that arrives by bank transfer and make income look far too low.
    tags_in = set(s.scalars(select(StatementRule.choice).where(StatementRule.user_id == user_id,
                                                                StatementRule.key.like("in:%"))))
    use_actual = bool(tags_in & {"income", "mixed"})

    def month_income(key):
        # "A mix": the profile income stays the plan, but a month where less arrived uses the lower amount
        # (a late or short allowance shows; moving one's own savings never inflates income).
        got = actual.get(key, 0.0)
        return min(income, got + mixed.get(key, 0.0)) if "mixed" in tags_in else got
    by_month, outside, one_offs = {}, {}, {}
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
        spread = {c: cats[c] + (un * weights.get(c, 0.0) if c in EVERYDAY else 0.0) for c in SPENDING_CATEGORIES}
        from_statement = use_actual and (y, mo) in covered
        months.append({"year": y, "month": mo, **spread,
                       "income_primary": round(month_income((y, mo)) if from_statement else income, 2),
                       "income_from": "statement" if from_statement else "profile",
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


def _saved_budget(s, user_id, year, month):
    b = s.scalar(select(Budget).where(Budget.user_id == user_id, Budget.year == year, Budget.month == month))
    lines = (b.data or {}).get("budget") if b else None
    return {c: float(lines.get(c, 0)) for c in SPENDING_CATEGORIES} if isinstance(lines, dict) else None


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


def _model_total(hist, totals, profile, target_month):
    """Next month's total from the model: a multiple of the household's median, using only what is known
    before the month starts (past months, income, household, and which calendar month it is)."""
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
         "fee_month": int(target_month in fee_months), "december": int(target_month == 12),
         "fees_seen": max(fees_seen) if fees_seen else 0.0,
         "fees_median": statistics.median([m["school_fees"] for m in hist])}
    import pandas as pd
    row = pd.DataFrame([x])[eng["features"]]
    mid = median * max(float(eng["model"].predict(row)[0]), 0.0)
    if x["fee_month"] and x["fees_seen"] > 0:
        # Safety floor: in a fee month, a fee-paying household spends at least its usual non-fee spending plus
        # last term's fees. Neutral on accuracy (validation 10,923 vs 10,912; test 9,936 vs 9,967) and active in
        # 4% of forecasts, but stops implausible answers (found walking through the app: a family's January,
        # a fee month, came out below a normal month).
        mid = max(mid, statistics.median([tt - m["school_fees"] for tt, m in zip(totals, hist)]) + x["fees_seen"])
    x["range"] = None
    if "low" in eng:            # 80% range: two quantile trees, widened on validation (docs/experiments.md, 4 Nov)
        lo, hi = median * float(eng["low"].predict(row)[0]), median * float(eng["high"].predict(row)[0])
        w = eng.get("widen", 1.0)
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
    c = s.get(Commitments, user_id)
    if not (c and c.data):
        return {}
    fixed = cm.evaluate(c.data)["for_budget"]["fixed"]
    out = {}
    for cat in ("housing", "loan_repayment"):
        if cat in fixed and float(fixed[cat]) > 0:
            diff = float(fixed[cat]) - statistics.median([m[cat] for m in hist])
            if abs(diff) >= 1:
                out[cat] = diff
    return out


def forecast_for_user(s, user_id, months, target_year, target_month):
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
    model = _model_total(hist, totals, s.get(Profile, user_id), target_month)
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
    this_budget = _saved_budget(s, user_id, target_year, target_month)
    last_budget = _saved_budget(s, user_id, py, pm)
    if this_budget:
        split, method = {c: 0.75 * this_budget.get(c, 0) + 0.25 * usual[c] for c in parts}, f"blend_budget_{base}"
    elif last_budget:
        split, method = {c: 0.75 * last_budget.get(c, 0) + 0.25 * usual[c] for c in parts}, f"blend_last_budget_{base}"
    else:
        split, method = usual, ("forecast_model" if base == "model" else "trailing_median")
    breakdown = {c: round(v) for c, v in split.items() if round(v) > 0}
    total = sum(breakdown.values())
    out = {"year": target_year, "month": target_month, "total": total,
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
    spent = sum(sum(mo[c] for c in SPENDING_CATEGORIES if c != "savings") for mo in scored)
    unsorted_share = sum(mo.get("unsorted", 0.0) for mo in scored) / spent if spent else 0.0      # outside the 10
    not_sorted = sum(mo.get("outside", {}).get(UNSORTED, 0.0) for mo in scored) / spent if spent else 0.0
    return {"profile": profile, "income": income, "months": months, "complete": complete, "current": current,
            "estimated": estimated, "unsorted_share": unsorted_share, "not_sorted_share": not_sorted,
            # More than 10% unsorted: use the state model that needs no category split.
            "statement_safe": unsorted_share > 0.10,
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
        if not months and not pic["estimated"]:
            return jsonify(has_data=False, income_monthly=round(income), savings_balance=round(pic["savings_balance"]))
        complete, current = pic["complete"], pic["current"]
        basis = complete or months
        fc = forecast_for_user(s, g.user_id, basis, pic["today"].year, pic["today"].month)
    health = aff.evaluate({"household": {"household_size": profile.household_size,
                                         "num_dependants": profile.dependants},
                           "months": pic["scored"], "statement_safe": pic["statement_safe"]})
    # Month by month: each completed month scored with only the data up to then (how things were at the time).
    timeline = []
    for i in range(len(pic["scored"])):
        mo = pic["scored"][i]
        r = aff.evaluate({"household": {"household_size": profile.household_size, "num_dependants": profile.dependants},
                          "months": pic["scored"][:i + 1], "statement_safe": pic["statement_safe"]})
        timeline.append({"year": mo["year"], "month": mo["month"], "state": r["state_now"], "score": r["score_before"],
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
                   forecast=fc, notes=notes, timeline=timeline, timeline_summary=summary, track_record=record)


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
    prev_month = next((mo for mo in complete if (mo["year"], mo["month"]) == (py, pm)), None)
    if isinstance(prev_limits, dict) and prev_month:
        payload["last_month"] = {"limits": prev_limits,
                                 "spent": {cat: _known(prev_month)[cat] for cat in SPENDING_CATEGORIES if cat in prev_limits}}
    plan = bud.evaluate(payload)
    plan["notes"] = notes + plan["notes"]
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
    everyday = [cat for cat in bud.model()["variable"]]
    limits = saved_now_data["budget"] if saved_now_data else plan["budget"]
    left = sum(float(limits.get(cat, 0)) for cat in everyday) - sum(spent.get(cat, 0) for cat in everyday + OUTSIDE)
    days_left = calendar.monthrange(y, m)[1] - pic["today"].day + 1
    return jsonify(year=y, month=m, plan=plan, spent_so_far=spent, saved=saved_now_data, auto_saved=auto_saved,
                   everyday_left=round(left), days_left=days_left, safe_per_day=round(max(0.0, left) / days_left))


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
        seen = set(s.scalars(select(Transaction.ref).where(Transaction.user_id == g.user_id, Transaction.ref.is_not(None))))
        seen |= set(s.scalars(select(MoneyIn.ref).where(MoneyIn.user_id == g.user_id, MoneyIn.ref.is_not(None))))
        c = s.get(Commitments, g.user_id)
        goals = (c.data or {}).get("goals", []) if c else []
        checks = [(sc.created_at.date(), sc.request or {}, (sc.result or {}).get("title", ""))
                  for sc in s.scalars(select(Scenario).where(Scenario.user_id == g.user_id))]
    try:
        info = mpesa.read_statement(data, request.form.get("password") or None, remembered)
    except mpesa.StatementError as exc:
        raise InputError(str(exc))
    skip = _partial_months(info["period"], _today())
    statement_months = {r["time"][:7] for r in info["rows"] if r["kind"] == "spend"} - skip
    with session() as s:
        manual = [t for t in s.scalars(select(Transaction).where(Transaction.user_id == g.user_id,
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
    for p in info["payees"]:
        p["hints"] = _hints(p, goals, checks)
    return jsonify(period=info["period"], checks=info["checks"], months=info["months"], flows=info["flows"],
                   coverage=info["coverage"], payees=info["payees"], usual_monthly_spending=info["usual_monthly_spending"],
                   transactions=rows, new=sum(1 for r in rows if r["kind"] == "spend" and not r["duplicate"]),
                   left_out_months=sorted(skip),
                   manual_overlap={"count": len(manual),
                                   "months": sorted({f"{t.day.year}-{t.day.month:02d}" for t in manual})}), 200


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
    skip = _partial_months(b.get("period"), _today())
    spend, net, was, money_in = [], defaultdict(float), {}, []
    for r in rows:
        if not isinstance(r, dict):
            raise InputError("each transaction must be an object")
        try:
            day = date.fromisoformat(str(r.get("date")))
            amount = float(r.get("amount"))
        except (TypeError, ValueError):
            raise InputError("each transaction needs a date (YYYY-MM-DD) and an amount")
        row = {"amount": amount if r.get("direction") == "in" else -amount, "kind": r.get("kind"),
               "category": r.get("category"), "source": r.get("source")}
        key = r.get("payee_key")
        if key and key in tags:
            was.setdefault(key, r.get("auto_category"))
            mpesa.apply_tag(row, tags[key])
        month = f"{day.year}-{day.month:02d}"
        if month in skip or r.get("duplicate"):
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
        elif row["kind"] == "own_out":
            net[month] += amount
        elif row["kind"] == "own_in":
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
        if b.get("replace_manual", True) and months_in:
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
            try:
                day = date.fromisoformat(str(edits["date"]))
            except ValueError:
                raise InputError("date must look like 2026-10-29")
            if day > _today():
                raise InputError("the date cannot be in the future")
            t.day = day
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
            raise InputError("money coming in can be your pay or allowance, a mix, your own money, or someone paying you")
        with session() as s:
            xs = s.scalars(select(MoneyIn).where(MoneyIn.user_id == g.user_id, MoneyIn.payee_key == key)).all()
            _save_rule(s, g.user_id, key, tag, xs[0].auto_kind if xs else None)
            for x in xs:
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
            x.kind = x.auto_kind or x.kind
            n += 1
        s.commit()
    return jsonify(updated=n), 200


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
            cm.evaluate(data)
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

# What each model does and how it was chosen (docs/experiments.md). Shown on the admin page.
MODEL_REGISTER = [
    {"name": "Financial state (main)", "file": "affordability_engine.joblib", "kind": "Random Forest classifier",
     "metric": "held-out accuracy 0.799 (HMM: 0.531)", "data": "KIHBS-informed synthetic, 240/60 households"},
    {"name": "Financial state (statement-safe)", "file": "affordability_engine.joblib",
     "kind": "Random Forest on exact figures only", "metric": "accuracy 0.750; state unchanged by mis-sorting (0/60)",
     "data": "same"},
    {"name": "Affordability score", "file": "affordability_engine.joblib", "kind": "Monotonic gradient boosting",
     "metric": "bigger cost never raises the score (100% of households); accuracy 0.654", "data": "same"},
    {"name": "Score explanations (SHAP)", "file": "affordability_engine.joblib",
     "kind": "Exact Shapley values over 6 feature groups, 200-row background",
     "metric": "matches the shap library to 3e-13 points; parts add up to the score exactly",
     "data": "200 training household-months"},
    {"name": "Budget split", "file": "budget_split.joblib", "kind": "Random Forest, half with the average split",
     "metric": "KES 7,021 average error per category vs 7,295 one-size", "data": "974 Stable household-months"},
    {"name": "App forecast", "file": "user_forecast.joblib", "kind": "Boosted tree with fee-month/December flags",
     "metric": "test MAE KES 9,967 vs 10,719 median; 80% range holds 83%", "data": "KIHBS-informed synthetic"},
    {"name": "Web Masters forecast (U-CS 37)", "file": "forecast_tree.joblib",
     "kind": "Budget blend + boosted-tree split", "metric": "test MAE KES 7,931, WAPE 0.106",
     "data": "Web Masters staging, 500 households"},
]


def _mask(email):
    name, _, domain = email.partition("@")
    return f"{name[:1]}***@{domain}"


@bp.get("/me/role")
@login_required
def my_role():
    with session() as s:
        return jsonify(admin=_is_admin(s, g.user_id)), 200


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
        service={"status": "ok", "database": _DB["engine"].dialect.name, **SERVICE_STATUS["check"]()},
        users={"total": len(users), "with_household": len(profiles), "with_statement": len(statement_users),
               "joined_7_days": sum(1 for j in joined if (now - j).days < 7),
               "records": n_tx, "affordability_checks": n_checks},
        models=register,
        recent_users=[{"id": u.id, "email": _mask(u.email), "joined": u.created_at.date().isoformat(),
                       "household": u.id in profiles, "records": counts.get(u.id, 0),
                       "statement": u.id in statement_users, "checks": checks.get(u.id, 0)} for u in users[:50]]), 200


@bp.delete("/me")
@login_required
def delete_account():
    """Privacy: a user (or a tester after the study) can remove everything about them."""
    with session() as s:
        for table in (MoneyIn, StatementRule, Scenario, Budget, Commitments, Transaction, IncomeSource, Profile):
            s.execute(delete(table).where(table.user_id == g.user_id))
        s.execute(delete(User).where(User.id == g.user_id))
        s.commit()
    return jsonify(deleted=True), 200
