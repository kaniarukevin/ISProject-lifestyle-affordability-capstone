"""U-CS 37 budget-forecast service (stub: trailing-median baseline).

POST /forecast  { userId, month, year } -> { estimatedTotal, breakdown, confidence, riskFlag, ... }
GET  /health    -> 200
"""
import io
import json
import os
import threading
import urllib.request
from pathlib import Path

import pandas as pd
from flask import Flask, jsonify, request

ROOT = Path(__file__).resolve().parent.parent
LOCAL_DIR = Path(os.environ.get("STAGING_DIR", ROOT / "data" / "staging"))
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
    """Use the local CSV if present (development); otherwise download it from the staging API."""
    local = LOCAL_DIR / f"{name}.csv"
    if local.exists():
        return pd.read_csv(local)
    if "token" not in session:
        body = json.dumps({"email": os.environ["WASAA_EMAIL"],
                           "password": os.environ["WASAA_PASSWORD"]}).encode()
        session["token"] = _find(json.loads(_http(f"{API_BASE}/auth/login", body)), "accessToken")
    return pd.read_csv(io.BytesIO(_http(f"{API_BASE}/sandbox/dataset/{name}.csv", token=session["token"])))


def _load():
    try:
        session = {}
        budget = _read_csv("budget_categories", session)
        households = _read_csv("households", session)
        budget["t"] = budget["year"] * 12 + budget["month"]
        STORE["categories"] = sorted(budget["category"].unique())
        STORE["by_user"] = {uid: g for uid, g in budget.groupby("user_profile_id")}
        STORE["alias"] = dict(zip(households["user_id"], households["user_profile_id"]))
        STORE["ready"].set()
    except Exception as exc:  # keep the service up; /forecast reports 503
        STORE["error"] = str(exc)
        print("data load failed:", exc, flush=True)


threading.Thread(target=_load, daemon=True).start()


def make_forecast(user_key, month, year):
    uid = STORE["alias"].get(user_key, user_key)  # accept user_id or user_profile_id
    g = STORE["by_user"].get(uid)
    if g is None:
        return None, ("unknown userId", 404)

    target = year * 12 + month
    hist = g[(g["t"] < target) & (g["t"] >= target - WINDOW)]
    months = sorted(hist["t"].unique())
    if not months:
        return None, ("no spending history before the requested month", 422)

    cats = STORE["categories"]
    matrix = (hist.pivot_table(index="t", columns="category", values="actual_kes", aggfunc="sum")
                  .reindex(index=months, columns=cats).fillna(0))
    medians = matrix.median(axis=0)
    breakdown = {c: round(float(medians[c]), 2) for c in cats}
    total = round(sum(breakdown.values()), 2)

    # Placeholder confidence: steadier history and more months of it means higher confidence.
    totals = matrix.sum(axis=1)
    cv = float(totals.std(ddof=0) / totals.mean()) if totals.mean() > 0 else 1.0
    confidence = round(max(0.05, min(0.95, 1 - cv)) * min(1.0, len(months) / WINDOW), 2)

    # riskFlag: forecast exceeds the household's budget for that month (or its latest budget before it).
    budgets = g[g["t"] <= target]
    latest = budgets["t"].max()
    allocated = float(budgets.loc[budgets["t"] == latest, "allocated_kes"].sum())
    risk_flag = bool(total > allocated)

    return {
        "estimatedTotal": total,
        "breakdown": breakdown,
        "confidence": confidence,
        "riskFlag": risk_flag,
        "method": "trailing_median_12m",
        "monthsOfHistory": len(months),
    }, None


@app.get("/health")
def health():
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

    if STORE["error"]:
        return jsonify(error="data could not be loaded"), 503
    if not STORE["ready"].wait(timeout=20):
        return jsonify(error="data is still loading, retry shortly"), 503

    result, err = make_forecast(user_id, month, year)
    if err:
        return jsonify(error=err[0]), err[1]
    return jsonify(result), 200


if __name__ == "__main__":
    app.run(port=int(os.environ.get("PORT", 8000)))
