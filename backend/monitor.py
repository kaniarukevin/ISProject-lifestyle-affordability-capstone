"""Post-deployment monitoring (proposal 3.3: "API response times, error rates, and database query performance").

Every request is timed, with the time spent in the database and the number of queries, and kept in memory: the
last 1,000 requests and 200 events. Only the route pattern is kept (for example "/me/scenarios/<int:sid>/apply"),
never a user, an email, an amount or a request body, so nothing personal is stored. The figures reset when the
server restarts. Render runs one worker (backend/README.md), so one process sees every request.
"""
import statistics
import time
from collections import deque
from datetime import datetime, timezone

from flask import g, has_request_context, request
from sqlalchemy import event, text
from sqlalchemy.engine import Engine

REQUESTS = deque(maxlen=1000)
EVENTS = deque(maxlen=200)
STARTED = datetime.now(timezone.utc)

# What a request means for the events log, by (method, route, status class). Plain words, no personal data.
_EVENT = {
    ("POST", "/auth/register", 2): ("account", "New account created"),
    ("POST", "/auth/login", 4): ("security", "Failed log-in"),
    ("POST", "/me/statements/import", 2): ("data", "Statement imported"),
    ("POST", "/me/messages/preview", 2): ("data", "M-PESA messages read"),
    ("DELETE", "/me", 2): ("account", "Account deleted by its owner"),
}


def _now():
    return datetime.now(timezone.utc)


def log_event(kind, what):
    EVENTS.append({"at": _now().isoformat(timespec="seconds"), "kind": kind, "text": what})


@event.listens_for(Engine, "before_cursor_execute")
def _q_start(conn, cursor, statement, params, context, executemany):
    if has_request_context():
        g._mon_q0 = time.perf_counter()


@event.listens_for(Engine, "after_cursor_execute")
def _q_end(conn, cursor, statement, params, context, executemany):
    if has_request_context() and getattr(g, "_mon_q0", None) is not None:
        g._mon_db = getattr(g, "_mon_db", 0.0) + time.perf_counter() - g._mon_q0
        g._mon_n = getattr(g, "_mon_n", 0) + 1
        g._mon_q0 = None


def install(app):
    """Call before any other before_request hook, so refused requests are timed too."""
    @app.before_request
    def _start():
        g._mon_t0, g._mon_db, g._mon_n = time.perf_counter(), 0.0, 0

    @app.after_request
    def _finish(resp):
        t0 = getattr(g, "_mon_t0", None)
        if t0 is None or request.method == "OPTIONS":
            return resp
        route = request.url_rule.rule if request.url_rule else "(unknown address)"
        ms = (time.perf_counter() - t0) * 1000
        REQUESTS.append({"route": route, "method": request.method, "status": resp.status_code,
                         "ms": round(ms, 1), "db_ms": round(g._mon_db * 1000, 1), "queries": g._mon_n,
                         "at": _now().isoformat(timespec="seconds")})
        hit = _EVENT.get((request.method, route, resp.status_code // 100))
        if hit:
            log_event(*hit)
        if resp.status_code == 429:
            log_event("security", f"Rate limit reached on {route}")
        if resp.status_code >= 500:
            log_event("error", f"Server error on {request.method} {route}"
                            f"{': ' + g._mon_error if getattr(g, '_mon_error', None) else ''}")
        return resp


def _pct(values, p):
    v = sorted(values)
    return v[min(len(v) - 1, int(round(p / 100 * (len(v) - 1))))] if v else None


def db_round_trip_ms(engine, tries=3):
    """How far the database is from this server: the median time of a trivial query."""
    times = []
    with engine.connect() as c:
        c.execute(text("select 1"))              # the first may open a connection; don't count it
        for _ in range(tries):
            t = time.perf_counter()
            c.execute(text("select 1"))
            times.append((time.perf_counter() - t) * 1000)
    return round(statistics.median(times), 1)


def summary():
    reqs = [r for r in REQUESTS if not r["route"].startswith("/admin")]   # the console's own calls aside
    routes = {}
    for r in reqs:
        routes.setdefault((r["method"], r["route"]), []).append(r)
    rows = []
    for (method, route), rs in routes.items():
        ms = [r["ms"] for r in rs]
        rows.append({"method": method, "route": route, "count": len(rs),
                     "median_ms": round(statistics.median(ms)), "p95_ms": round(_pct(ms, 95)),
                     "median_db_ms": round(statistics.median(r["db_ms"] for r in rs)),
                     "median_queries": round(statistics.median(r["queries"] for r in rs)),
                     "errors": sum(1 for r in rs if r["status"] >= 500),
                     "refused": sum(1 for r in rs if 400 <= r["status"] < 500)})
    rows.sort(key=lambda x: -x["median_ms"])
    ms = [r["ms"] for r in reqs]
    return {
        "since": STARTED.isoformat(timespec="seconds"),
        "requests": len(reqs),
        "median_ms": round(statistics.median(ms)) if ms else None,
        "p95_ms": round(_pct(ms, 95)) if ms else None,
        "db_share": round(sum(r["db_ms"] for r in reqs) / (sum(ms) or 1), 2) if ms else None,
        "error_rate": round(sum(1 for r in reqs if r["status"] >= 500) / len(reqs), 4) if reqs else None,
        "routes": rows,
        "events": list(reversed(EVENTS)),
    }
