"""U-CS 37 budget-forecast service (stub: trailing-median baseline).

POST /forecast  { userId, month, year } -> { estimatedTotal, breakdown, confidence, riskFlag, ... }
GET  /health    -> 200
"""
import io
import json
import os
import threading
import time
import urllib.request
from pathlib import Path

import pandas as pd
from flask import Flask, jsonify, request

from affordability import AffordabilityInputError, evaluate

ROOT = Path(__file__).resolve().parent.parent
LOCAL_DIR = Path(os.environ.get("STAGING_DIR", ROOT / "data" / "staging"))
BUNDLED_DIR = Path(__file__).resolve().parent / "data"  # compact copy shipped with the service
API_BASE = os.environ.get("WASAA_API_BASE", "https://api-wasaa-lifestyle.webmasterskenya.com/api/v1")
WINDOW = 12  # months of history used by the trailing median

app = Flask(__name__)
STORE = {"ready": threading.Event(), "error": None}


def _http(url, data=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request_ = urllib.request.Request(url, data=data, headers=headers)
    return urllib.request.urlopen(request_, timeout=60).read()


def _find(obj, key):
    if isinstance(obj, dict):
        if key in obj:
            return obj[key]
        for value in obj.values():
            found = _find(value, key)
            if found:
                return found
    if isinstance(obj, list):
        for value in obj:
            found = _find(value, key)
            if found:
                return found
    return None


def _read_csv(name, session):
    """Load a table: local CSV (development), else the bundled copy, else download from the staging API."""
    local = LOCAL_DIR / f"{name}.csv"
    if local.exists():
        print(f"[load] {name}: using local CSV {local}", flush=True)
        return pd.read_csv(local)
    bundled = BUNDLED_DIR / f"{name}.csv.gz"
    if bundled.exists():
        print(f"[load] {name}: using bundled copy {bundled}", flush=True)
        return pd.read_csv(bundled)
    print(f"[load] {name}: no local or bundled copy, downloading from the API (slow)", flush=True)
    if "token" not in session:
        body = json.dumps({"email": os.environ["WASAA_EMAIL"],
                           "password": os.environ["WASAA_PASSWORD"]}).encode()
        session["token"] = _find(json.loads(_http(f"{API_BASE}/auth/login", body)), "accessToken")
    return pd.read_csv(io.BytesIO(_http(f"{API_BASE}/sandbox/dataset/{name}.csv", token=session["token"])))


def _timed_read(name, session):
    """Read one table and log how many rows it had and how long it took."""
    start = time.time()
    df = _read_csv(name, session)
    print(f"[load] {name}: {len(df)} rows in {time.time() - start:.1f}s", flush=True)
    return df


def _load():
    try:
        print(f"[boot] bundled dir {BUNDLED_DIR} exists={BUNDLED_DIR.exists()} "
              f"files={sorted(p.name for p in BUNDLED_DIR.glob('*')) if BUNDLED_DIR.exists() else []}", flush=True)
        session = {}
        budget = _timed_read("budget_categories", session)
        households = _timed_read("households", session)
        budget["t"] = budget["year"] * 12 + budget["month"]
        STORE["categories"] = sorted(budget["category"].unique())
        STORE["by_user"] = {uid: g for uid, g in budget.groupby("user_profile_id")}
        STORE["alias"] = dict(zip(households["user_id"], households["user_profile_id"]))
        STORE["ready"].set()
        print("[load] ready: data loaded, service can answer /forecast", flush=True)
    except Exception as exc:  # keep the service up; /forecast reports 503
        STORE["error"] = str(exc)
        print("data load failed:", exc, flush=True)


_LOADER = {"pid": None}
_LOADER_LOCK = threading.Lock()


def ensure_loading():
    """Start loading the data in THIS process, once.

    gunicorn can import this file in its master process and then fork the worker. A thread
    started before the fork does not exist in the worker, so the worker would wait forever
    with dataLoaded=false. Each process (identified by its pid) therefore starts its own
    loader, with fresh state instead of a copy made at fork time.
    """
    with _LOADER_LOCK:
        if _LOADER["pid"] == os.getpid():
            return
        _LOADER["pid"] = os.getpid()
        STORE["ready"] = threading.Event()
        STORE["error"] = None
        threading.Thread(target=_load, daemon=True).start()


ensure_loading()


def allocation_by_category(rows):
    """Latest monthly budget per category from the rows we have, or None."""
    if rows.empty:
        return None
    latest = rows["t"].max()
    current = rows[rows["t"] == latest]
    return current.groupby("category")["allocated_kes"].sum().reindex(STORE["categories"]).fillna(0)


def peer_breakdown():
    """Median monthly spend per category across all households (computed once, then cached)."""
    if "peer" not in STORE:
        everyone = pd.concat(STORE["by_user"], names=["uid"]).reset_index(level=0)
        per_month = everyone.pivot_table(index=["uid", "t"], columns="category",
                                         values="actual_kes", aggfunc="sum")
        med = per_month.reindex(columns=STORE["categories"]).fillna(0).median(axis=0)
        STORE["peer"] = {c: round(float(med[c]), 2) for c in STORE["categories"]}
    return STORE["peer"]


def risk_label(total, reference):
    """LOW / MODERATE / HIGH from forecast versus budget (thresholds are in the README)."""
    if reference <= 0:
        return "MODERATE"
    ratio = total / reference
    if ratio > 1.20:
        return "HIGH"
    if ratio > 1.00:
        return "MODERATE"
    return "LOW"


def make_forecast(user_key, month, year):
    cats = STORE["categories"]
    uid = STORE["alias"].get(user_key, user_key)  # accept user_id or user_profile_id
    g = STORE["by_user"].get(uid)
    target = year * 12 + month

    # Known household with no rows at all: peer median.
    if g is None:
        known = user_key in STORE["alias"] or user_key in set(STORE["alias"].values())
        if not known:
            return None, ("unknown userId", 404)
        breakdown = peer_breakdown()
        return {"estimatedTotal": round(sum(breakdown.values()), 2), "breakdown": breakdown,
                "confidence": 0.1, "riskFlag": "MODERATE",
                "note": "New household with no history. Using the median of all households.",
                "method": "peer_median", "monthsOfHistory": 0}, None

    budgets = g[g["t"] <= target]
    alloc = allocation_by_category(budgets)
    allocated_total = float(alloc.sum()) if alloc is not None else 0.0

    hist = g[(g["t"] < target) & (g["t"] >= target - WINDOW)]
    months = sorted(hist["t"].unique())

    # Rows exist but no history before this month: use the budget, else the peer median.
    if not months:
        if allocated_total > 0:
            breakdown = {c: round(float(alloc[c]), 2) for c in cats}
            return {"estimatedTotal": round(sum(breakdown.values()), 2), "breakdown": breakdown,
                    "confidence": 0.1, "riskFlag": "LOW",
                    "note": "No spending history before this month. Forecast equals the household's budget.",
                    "method": "budget_allocation", "monthsOfHistory": 0}, None
        breakdown = peer_breakdown()
        return {"estimatedTotal": round(sum(breakdown.values()), 2), "breakdown": breakdown,
                "confidence": 0.1, "riskFlag": "MODERATE",
                "note": "No history or budget for this household. Using the median of all households.",
                "method": "peer_median", "monthsOfHistory": 0}, None

    matrix = (hist.pivot_table(index="t", columns="category", values="actual_kes", aggfunc="sum")
                  .reindex(index=months, columns=cats).fillna(0))
    medians = matrix.median(axis=0)
    breakdown = {c: round(float(medians[c]), 2) for c in cats}
    total = round(sum(breakdown.values()), 2)

    totals = matrix.sum(axis=1)
    cv = float(totals.std(ddof=0) / totals.mean()) if totals.mean() > 0 else 1.0
    confidence = round(max(0.05, min(0.95, 1 - cv)) * min(1.0, len(months) / WINDOW), 2)

    note = None
    if allocated_total > 0:
        reference = allocated_total
    else:
        reference = float(totals.iloc[-1])
        note = "No budget found. Risk compared with last month's actual spending."
    if len(months) < 6:
        short = f"Only {len(months)} months of history, so treat this as a rough estimate."
        note = f"{note} {short}" if note else short

    return {"estimatedTotal": total, "breakdown": breakdown, "confidence": confidence,
            "riskFlag": risk_label(total, reference), "note": note,
            "method": "trailing_median_12m", "monthsOfHistory": len(months)}, None


@app.get("/health")
def health():
    ensure_loading()
    return jsonify(status="ok", dataLoaded=STORE["ready"].is_set()), 200


@app.post("/forecast")
def forecast():
    body = request.get_json(silent=True) or {}
    user_id = body.get("userId")
    if not isinstance(user_id, str) or not user_id:
        return jsonify(error="userId is required"), 400
    try:
        month, year = int(body.get("month")), int(body.get("year"))
    except (TypeError, ValueError):
        return jsonify(error="month and year must be integers"), 400
    if not 1 <= month <= 12 or not 2000 <= year <= 2100:
        return jsonify(error="month must be 1-12 and year a four-digit year"), 400

    ensure_loading()
    if STORE["error"]:
        return jsonify(error="data could not be loaded"), 503
    if not STORE["ready"].wait(timeout=20):
        return jsonify(error="data is still loading, retry shortly"), 503

    result, err = make_forecast(user_id, month, year)
    if err:
        return jsonify(error=err[0]), err[1]
    return jsonify(result), 200



@app.post("/affordability")
def affordability():
    """Capstone endpoint: can this household afford a lifestyle change? Not part of the U-CS 37 contract."""
    try:
        return jsonify(evaluate(request.get_json(silent=True))), 200
    except AffordabilityInputError as exc:
        return jsonify(error=str(exc)), 400

if __name__ == "__main__":
    app.run(port=int(os.environ.get("PORT", 8000)))
