"""M-PESA statement reader (capstone). Three layers, so a bank-statement reader can be added later:

1. read     PDF -> rows (receipt, time, details, amount, balance), checked against the statement's own totals
            and running balance. Text is read with pypdf: 1.3 s for a 52-page statement, against 12 s for table
            extraction (too slow for the free server's 30 s limit; measured 4 Nov).
2. understand  each row -> M-PESA type (exact) and, only when certain, an app category, income, money received from people,
            money moving to or from the user's own bank or fund accounts, or a charge. Rules, not a model: no
            labelled Kenyan transactions exist to train one. Anything not certain stays "unsorted" (never guessed).
3. summarise  rows -> months in the app's 10 categories, ready for review and import.

The PDF is read in memory and never stored; only the reviewed transactions are saved.
"""
import io
import re
from collections import defaultdict
from datetime import datetime

CATEGORIES = ["housing", "food_groceries", "transport", "utilities", "airtime_data",
              "mobile_money_transfers", "loan_repayment", "school_fees", "entertainment", "savings"]


class StatementError(ValueError):
    """The file is not a readable M-PESA statement, the password is wrong, or the numbers do not add up."""


# ---------------------------------------------------------------- 1. read

HEAD = re.compile(r"^([A-Z0-9]{10}) (20\d\d-\d\d-\d\d \d\d:\d\d:\d\d) ?(.*)$")
TAIL = re.compile(r"^(.*?)\s*(Completed|Failed|Pending|Reversed|Cancelled)\s+(-?[\d,]+\.\d\d)\s+(-?[\d,]+\.\d\d)\s*$")
NOISE = re.compile(r"^(Page \d+ of \d+|Receipt No\. Completion Time.*|Statement Verification Code.*|prompts to enter.*|"
                   r"For self-help dial.*|conditions apply.*|DETAILED STATEMENT.*|Disclaimer.*)$")


def _money(s):
    return float(s.replace(",", ""))


def read_pdf(data, password=None):
    """PDF bytes -> plain text. Raises StatementError for a locked file with a missing or wrong password."""
    from pypdf import PdfReader
    from pypdf.errors import PdfReadError
    try:
        reader = PdfReader(io.BytesIO(data))
        if reader.is_encrypted:
            if not password or not reader.decrypt(password):
                raise StatementError("This statement is locked. Enter the password from the Safaricom SMS."
                                     if not password else "That password did not open the statement. "
                                     "Check the SMS from Safaricom.")
        return "\n".join(page.extract_text() or "" for page in reader.pages)
    except StatementError:
        raise
    except (PdfReadError, ValueError, KeyError) as exc:
        raise StatementError("This file could not be read as a PDF. Choose the M-PESA statement PDF that "
                             "Safaricom emailed you.") from exc


def parse_text(text):
    """Statement text -> header facts and rows, oldest first, with checks."""
    if "M-PESA STATEMENT" not in text.upper() or "Receipt No." not in text:
        raise StatementError("This does not look like an M-PESA statement from Safaricom, so nothing was read. "
                             "Get the full statement from the M-PESA app (Statements, then Request full statement) "
                             "or by dialling *334#; Safaricom emails it as a PDF. Bank statements and photos or "
                             "scans of a statement cannot be read.")
    period = re.search(r"Statement Period:\s*(\d\d \w{3} \d{4})\s*-\s*(\d\d \w{3} \d{4})", text)
    total = re.search(r"TOTAL:\s*([\d,]+\.\d\d)\s+([\d,]+\.\d\d)", text)
    rows, cur = [], None
    for line in text.splitlines():
        line = line.strip()
        if not line or NOISE.match(line):
            continue
        m = HEAD.match(line)
        if m:
            cur = {"receipt": m.group(1), "time": m.group(2), "parts": [m.group(3)]}
            line = m.group(3)
            t = TAIL.match(line)
            if not t:
                continue
        elif cur is None:
            continue
        else:
            t = TAIL.match(line)
            if not t:
                cur["parts"].append(line)
                continue
            cur["parts"].append(t.group(1))
        if m and t:
            cur["parts"] = [t.group(1)]
        details = " ".join(p for p in cur["parts"] if p).strip()
        if t.group(2) == "Completed":
            rows.append({"receipt": cur["receipt"], "time": cur["time"], "details": re.sub(r"\s+", " ", details),
                         "amount": _money(t.group(3)), "balance": _money(t.group(4))})
        cur = None
    if not rows:
        raise StatementError("No transactions were found in this statement.")
    rows.reverse()                                   # statements list newest first
    rows = _same_second_order(rows)
    for i, r in enumerate(rows):
        r["n"] = i
    info = {"period": [period.group(1), period.group(2)] if period else None, "rows": rows,
            "checks": _checks(rows, total)}
    return info


def _same_second_order(rows):
    """Transactions in the same second can be listed in either order (found on a real statement: 6 places in
    1,739 rows). Put them in the order their balances follow, so the running-balance check is fair."""
    out, i = [], 0
    while i < len(rows):
        j = i
        while j + 1 < len(rows) and rows[j + 1]["time"] == rows[i]["time"]:
            j += 1
        block = rows[i:j + 1]
        if len(block) > 1 and out:
            prev, ordered, left = out[-1]["balance"], [], block[:]
            while left:
                nxt = next((r for r in left if round(prev + r["amount"], 2) == round(r["balance"], 2)), None)
                if nxt is None:                       # charges sharing a balance: keep the listed order
                    ordered += left
                    break
                ordered.append(nxt)
                left.remove(nxt)
                prev = nxt["balance"]
            block = ordered
        out += block
        i = j + 1
    return out


def _checks(rows, total):
    """Did we read every shilling? Totals against the statement's summary, and the running balance."""
    paid_in = round(sum(r["amount"] for r in rows if r["amount"] > 0), 2)
    paid_out = round(-sum(r["amount"] for r in rows if r["amount"] < 0), 2)
    out = {"rows": len(rows), "paid_in": paid_in, "paid_out": paid_out}
    if total:
        out["statement_paid_in"], out["statement_paid_out"] = _money(total.group(1)), _money(total.group(2))
        out["totals_match"] = (abs(paid_in - out["statement_paid_in"]) < 0.01 and
                               abs(paid_out - out["statement_paid_out"]) < 0.01)
    # Running balance: rows sharing a receipt (a transfer and its charge) can show one balance for both.
    groups, breaks = [], 0
    for r in rows:
        if groups and groups[-1][0]["receipt"] == r["receipt"]:
            groups[-1].append(r)
        else:
            groups.append([r])
    prev = None
    for g in groups:
        bal = {round(x["balance"], 2) for x in g}
        if prev is not None and round(prev + sum(x["amount"] for x in g), 2) not in bal and \
                not any(round(prev + x["amount"], 2) in bal for x in g):
            breaks += 1
        prev = round(prev + sum(x["amount"] for x in g), 2) if prev is not None and \
            round(prev + sum(x["amount"] for x in g), 2) in bal else g[-1]["balance"]
    out["balance_breaks"] = breaks
    out["ok"] = out.get("totals_match", True) and breaks == 0
    return out


# ---------------------------------------------------------------- 2. understand

import kenya_directory as kd

UNSORTED = kd.UNSORTED
TYPES = {                 # M-PESA's own transaction types: always right, because Safaricom writes them
    "sent": "Sent to people", "pochi": "Pochi la Biashara", "buy_goods": "Buy goods (till)",
    "pay_bill": "Pay bill", "cash": "Cash withdrawal", "airtime": "Airtime & bundles", "charges": "M-PESA charges",
    "loan": "Loan repayment", "savings": "Savings & investments", "money_in": "Money in", "other": "Other",
}
# What a user can tag a payee as: the app's 10 categories, or "my own account" (not spending), or leave unsorted.
# Spending outside the models' 10 categories: shown by its real name, treated like unsorted money by the models.
OUTSIDE = [UNSORTED, "shopping", "health", "personal_care", "other", "charges"]
# Money coming in can be tagged too: the user's pay or allowance, their own money moving, or someone paying them.
# Money coming in: pay or allowance, pay mixed with own money, own money, paid back or a gift, and a bonus or
# other one-off (counted that month only as extra, never as usual income).
IN_TAGS = ["income", "mixed", "own_account", "received", "one_off"]
TAGS = ["housing", "food_groceries", "transport", "utilities", "airtime_data", "mobile_money_transfers",
        "loan_repayment", "school_fees", "entertainment", "savings", "shopping", "health", "personal_care",
        "other", "own_account", UNSORTED]
ALL_TAGS = TAGS + ["income", "mixed", "received", "one_off"]


def _phone(raw):
    """'254713***181' and '0713***181' are the same masked number."""
    raw = raw.strip()
    return "0" + raw[3:] if raw.startswith("254") else raw


def _payee(details):
    """'Pay Bill Online to 532900 - Karura Community Chapel Acc. YM OFFERING' -> ('532900', 'Karura ...', 'YM ...')"""
    m = re.search(r"(?:to|To|from|From)\s+(\d+)\s*-\s*(.*?)(?:\s+Acc\.\s*(.*))?$", details)
    if not m:
        return None, details, None
    name = re.sub(r"\s+via API.*$", "", m.group(2)).strip()
    return m.group(1), name, (m.group(3) or "").strip() or None


def _person(details):
    """'Customer Transfer to - 0711***111 JANE MWANGI' -> ('0711***111', 'JANE MWANGI')"""
    m = re.search(r"-\s*((?:254|0)\d{2,3}\*+\d{2,4})\s+(.+)$", details)
    if m:
        return _phone(m.group(1)), m.group(2).strip().upper()
    m = re.search(r"-\s*(.+)$", details)
    return None, (m.group(1).strip().upper() if m else details.upper())


def _set(r, kind, mtype, category=None, label=None, source=None, payee=None, key=None):
    r.update(kind=kind, mpesa_type=mtype, category=category, label=label or TYPES.get(mtype, ""),
             source=source, payee=payee, payee_key=key)


def understand(rows, remembered=None):
    """Label every row with what it certainly is. remembered: the user's tags {payee_key: tag}.
    kind: spend | income | received | own_in | own_out | ignore.  category: one of the 10, or 'unsorted'.
    source: 'type' (from M-PESA's own type), 'directory' / 'pattern' (Kenyan business directory), 'you' (a tag)."""
    remembered = remembered or {}
    by_receipt = defaultdict(list)
    for r in rows:
        by_receipt[r["receipt"]].append(r)
    for r in rows:
        d, low, amt = r["details"], r["details"].lower(), r["amount"]
        number, name, account = _payee(d)
        if "charge" in low and amt < 0 and abs(amt) < 1000 and (len(by_receipt[r["receipt"]]) > 1 or low.endswith("charge")):
            _set(r, "spend", "charges", "charges", "M-PESA charges", "type")   # its own line, never "money sent"
        elif low.startswith(("unit trust invest", "ziidi trader", "m-shwari deposit", "mshwari deposit",
                             "lock savings", "kcb m-pesa deposit")):
            _set(r, "own_out", "savings", None, f"Into {name}" if number else "Into savings", "type")
        elif low.startswith(("unit trust withdraw", "m-shwari withdraw", "mshwari withdraw", "kcb m-pesa withdraw")):
            _set(r, "own_in", "savings", None, "Out of savings", "type")
        elif low.startswith(("od loan repayment", "m-shwari loan repayment", "kcb m-pesa loan repayment",
                             "loan repayment")):
            _set(r, "spend", "loan", "loan_repayment", "Loan repayment" + (f" ({name})" if number else ""), "type",
                 payee=name if number else None)
        elif amt > 0 and low.startswith(("overdraft of credit", "od loan")):
            _set(r, "own_in", "loan", None, "Fuliza (borrowed)", "type")
        elif low.startswith("salary payment"):
            _set(r, "income", "money_in", None, f"Salary ({name})", "type", payee=name, key=f"in:{name.lower()}")
        elif amt > 0 and low.startswith("business payment"):
            # From a bank: the user's own money, or someone paying them from their bank (an allowance, pay).
            # The statement cannot tell which, so it is the user's own money until they tag it (safe side for
            # income: never count money as earned without being told).
            if kd.lookup(name) and kd.lookup(name)[0] == kd.SAVINGS or kd.BANKS.search(name.lower()):
                _set(r, "own_in", "money_in", None, f"From {name}", "type", payee=name, key=f"in:{name.lower()}")
            else:
                _set(r, "income", "money_in", None, f"Payment from {name}", "type", payee=name,
                     key=f"in:{name.lower()}")
        elif amt > 0 and low.startswith(("deposit of funds", "agent deposit")):
            _set(r, "own_in", "money_in", None, "Cash deposit", "type")
        elif amt > 0 and low.startswith("funds received"):
            phone, person = _person(d)
            _set(r, "received", "money_in", None, f"From {person.title()}", "type", payee=person.title(),
                 key=f"in:person:{phone}:{person}")
        elif amt > 0 and "reversal" in low:
            _set(r, "ignore", "other", None, "Reversal", "type")         # paired with its payment below
        elif amt > 0:
            _set(r, "received", "money_in", None, "Money received", "type")
        elif low.startswith(("customer bundle purchase", "airtime purchase", "buy bundles", "buy airtime")):
            _set(r, "spend", "airtime", "airtime_data", "Airtime & bundles", "type", key="airtime")
        elif low.startswith(("customer withdrawal", "withdrawal at agent", "atm withdrawal", "agent withdrawal")):
            _set(r, "spend", "cash", UNSORTED, "Cash withdrawal", "type", payee="Cash", key="cash")
        elif low.startswith(("customer transfer to", "send money", "customer send money")):
            phone, person = _person(d)
            # Money sent to a person is exactly the app's "money sent" category; tag the person to change it
            # (for example a landlord or a mama mboga).
            _set(r, "spend", "sent", "mobile_money_transfers", f"Sent to {person.title()}", "type",
                 payee=person.title(), key=f"person:{phone}:{person}")
        elif low.startswith("customer payment to small business"):
            phone, person = _person(d)
            _set(r, "spend", "pochi", UNSORTED, f"Pochi: {person.title()}", "type", payee=person.title(),
                 key=f"pochi:{phone}:{person}")
        elif low.startswith(("pay bill", "paybill")):
            hit = kd.lookup(name, account)
            if hit and hit[0] == kd.SAVINGS:
                _set(r, "own_out", "savings", None, f"Into {name}", hit[2], payee=name, key=f"paybill:{number}")
            elif hit:
                _set(r, "spend", "pay_bill", hit[1], hit[0], hit[2], payee=name, key=f"paybill:{number}")
            else:
                # A bank or unknown paybill: a payment to someone, or the user's own account. Counted as spending
                # (the safe side) until the user says; the account number tells payees apart.
                acc = (account or "").lower()
                _set(r, "spend", "pay_bill", UNSORTED,
                     f"Pay bill: {name}" + (f" (Acc. ••••{account[-4:]})" if account and len(account) >= 4 else ""),
                     None, payee=name, key=f"paybill:{number}:{acc}")
        elif low.startswith(("merchant payment", "buy goods", "pay merchant")):
            hit = kd.lookup(name, kind="buy_goods")
            if hit and hit[0] != kd.SAVINGS:
                _set(r, "spend", "buy_goods", hit[1], hit[0], hit[2], payee=name, key=f"till:{number}")
            else:
                _set(r, "spend", "buy_goods", UNSORTED, f"Shop: {name}", None, payee=name, key=f"till:{number}")
        elif "reversal" in low:
            # Money taken back (a payment to the user reversed): not spending, and the money it takes back was
            # never counted as income unless tagged, so it is left out.
            _set(r, "ignore", "other", None, "Reversal (money taken back)", "type")
        else:
            _set(r, "spend", "other", UNSORTED, d[:60], None)
        r["auto_category"], r["auto_kind"] = r["category"], r["kind"]
        if r["payee_key"] and r["payee_key"] in remembered:
            apply_tag(r, remembered[r["payee_key"]])
    _pair_reversals(rows)
    return rows


REVERSAL_DAYS = 7


def _pair_reversals(rows):
    """A reversal is money given back for a payment that did not go through. Leaving out only the reversal would
    still count the original as spending, so both are left out. The original is the payment whose receipt the
    reversal names, else the closest earlier payment of the same amount (alone, or with its charge) within
    REVERSAL_DAYS days. If none is found the reversal is kept as money received, so totals stay honest."""
    receipts = defaultdict(list)
    for r in rows:
        receipts[r["receipt"]].append(r)
    day = lambda r: datetime.strptime(r["time"][:10], "%Y-%m-%d")
    for rev in rows:
        if rev.get("label") != "Reversal" or rev["amount"] <= 0:
            continue
        named = [c for c in re.findall(r"\b[A-Z0-9]{10}\b", rev["details"]) if c in receipts and c != rev["receipt"]]
        match = None
        if named:
            match = [x for x in receipts[named[0]] if x["amount"] < 0 and not x.get("reversed")]
        else:
            for code, group in receipts.items():
                out = [x for x in group if x["amount"] < 0 and not x.get("reversed") and x["kind"] != "ignore"]
                if code == rev["receipt"] or not out or out[0]["n"] > rev["n"]:
                    continue
                if not 0 <= (day(rev) - day(out[0])).days <= REVERSAL_DAYS:
                    continue
                whole = abs(-sum(x["amount"] for x in out) - rev["amount"]) < 0.005
                single = [x for x in out if abs(-x["amount"] - rev["amount"]) < 0.005]
                found = out if whole else single[:1]
                if found and (match is None or found[0]["n"] > match[0]["n"]):
                    match = found                       # the closest earlier payment wins
        if not match:
            _set(rev, "received", "money_in", None, "Reversal (payment not found)", "type")
            rev["auto_category"], rev["auto_kind"] = rev["category"], rev["kind"]
            continue
        for x in match:
            x.update(kind="ignore", reversed=True, label=f"Reversed: {x.get('label') or x['details'][:40]}")
            x["auto_kind"] = "ignore"
        rev["label"] = f"Reversal of {match[0]['receipt']}"


def apply_tag(r, tag):
    """The user's answer for this payee: a category, 'own_account' (not spending), or for money coming in
    'income' (pay, allowance) or 'received' (someone paying them back, a gift)."""
    if r["amount"] > 0:                              # money in
        if tag in IN_TAGS:
            r["kind"] = "own_in" if tag == "own_account" else tag
            r["source"] = "you"
        return
    if tag not in TAGS:
        return
    if tag == "own_account":
        r["kind"] = "own_in" if r["amount"] > 0 else "own_out"
        r["category"] = None
    else:
        r["kind"] = "spend" if r["amount"] < 0 else r["kind"]
        r["category"] = tag
    r["source"] = "you"


# ---------------------------------------------------------------- 3. summarise

def suggest(payments, mtype):
    """A suggestion for a payee from a strong Kenyan payment pattern, shown for the user to confirm, never applied.
    Rent: the same large amount early in the month, three months running. Food: many small payments at one shop
    or Pochi. Never for a payee the business directory already labelled (a barber was once suggested "food"), and
    no "family?" hint for regular sends: that is already their category, shown highlighted (a phone-accessories
    seller paid by send money showed why a hint there misleads; 4 Nov).
    payments: [(date 'YYYY-MM-DD', amount)]."""
    if not payments:
        return None
    amounts = sorted(a for _, a in payments)
    med = amounts[len(amounts) // 2]
    months = {d[:7] for d, _ in payments}
    days = [int(d[8:10]) for d, _ in payments]
    spread = (sum((a - med) ** 2 for a in amounts) / len(amounts)) ** 0.5 / med if med else 1
    early = sum(1 for x in days if x <= 10 or x >= 25) / len(days)
    if mtype in ("sent", "pochi", "pay_bill") and len(months) >= 3 and len(payments) <= len(months) + 1 \
            and spread <= 0.25 and med >= 2000 and early >= 0.6:
        return {"tag": "housing", "why": f"About KES {med:,.0f} around the start of the month, {len(months)} months "
                                         "running. Is this your rent?"}
    if mtype in ("pochi", "buy_goods") and len(payments) >= 4 and med <= 1500:
        return {"tag": "food_groceries", "why": f"{len(payments)} small payments, usually KES {med:,.0f}. Many people "
                                                "pay for food like this. Is it food?"}
    return None


def payees(rows, limit=25, limit_in=8):
    """'Who you pay', and who pays you: people and businesses the reader could not sort for certain (plus regular
    money in from banks and people), biggest money first."""
    groups = defaultdict(list)
    for r in rows:
        if r["kind"] == "spend" and r.get("payee_key") and r["source"] != "you" and \
                (r["category"] == UNSORTED or r["mpesa_type"] in ("sent", "pochi")):
            groups[r["payee_key"]].append(r)
        elif r["amount"] > 0 and r.get("payee_key") and r["source"] != "you":
            groups[r["payee_key"]].append(r)
    out = []
    for key, members in groups.items():
        total = round(sum(abs(m["amount"]) for m in members))
        if total < 500 and key != "cash":
            continue
        pays = [(m["time"][:10], abs(m["amount"])) for m in members]
        if members[0]["amount"] > 0:                          # money in
            out.append({"key": key, "payee": members[0]["payee"], "type": "money_in", "direction": "in",
                        "type_label": "Money in", "label": members[0]["label"], "kind": members[0]["kind"],
                        "category": "own_account" if members[0]["kind"] == "own_in" else members[0]["kind"], "count": len(members), "total": total,
                        "last": max(d for d, _ in pays),
                        "recent": [{"date": d, "amount": round(a)} for d, a in sorted(pays, reverse=True)[:4]],
                        "suggestion": None})
            continue
        labelled = members[0]["source"] in ("directory", "pattern")      # the directory already knows: no guess
        out.append({"key": key, "payee": members[0]["payee"], "type": members[0]["mpesa_type"], "direction": "out",
                    "type_label": TYPES[members[0]["mpesa_type"]], "label": members[0]["label"],
                    "category": members[0]["category"], "count": len(members), "total": total,
                    "last": max(d for d, _ in pays),
                    "recent": [{"date": d, "amount": round(a)} for d, a in sorted(pays, reverse=True)[:4]],
                    "suggestion": None if labelled else suggest(pays, members[0]["mpesa_type"])})
    outs = sorted((p for p in out if p["direction"] == "out"), key=lambda p: -p["total"])[:limit]
    ins = sorted((p for p in out if p["direction"] == "in"), key=lambda p: -p["total"])[:limit_in]
    return outs + ins                                                   # who you pay first, then who pays you


def summarise(rows, big=None):
    """Months by category (with 'unsorted' kept apart), coverage, payees to ask about, suggested one-offs."""
    months = defaultdict(lambda: {c: 0.0 for c in CATEGORIES + OUTSIDE})
    flows = defaultdict(lambda: {"income": 0.0, "received": 0.0, "own_in": 0.0, "own_out": 0.0})
    by_source = defaultdict(float)
    for r in rows:
        key = r["time"][:7]
        if r["kind"] == "spend":
            months[key][r["category"]] += -r["amount"]
            by_source["unsorted" if r["category"] == UNSORTED else (r["source"] or "type")] += -r["amount"]
        elif r["kind"] in flows[key]:
            flows[key][r["kind"]] += abs(r["amount"])
    for key, f in flows.items():                      # saving = more into your own funds than taken out
        months[key]["savings"] = max(0.0, f["own_out"] - f["own_in"])
    totals = sorted(sum(v for c, v in m.items() if c != "savings") for m in months.values())
    usual = totals[len(totals) // 2] if totals else 0.0
    threshold = big or max(10000.0, 0.5 * usual)
    for r in rows:
        if r["kind"] == "spend" and -r["amount"] >= threshold and r["category"] != "housing":
            r["suggest_one_off"] = True
    spent = sum(by_source.values()) or 1.0
    return {"months": {k: {c: round(v, 2) for c, v in m.items()} for k, m in sorted(months.items())},
            "flows": {k: {n: round(v, 2) for n, v in f.items()} for k, f in sorted(flows.items())},
            "coverage": {k: round(v / spent, 3) for k, v in by_source.items()},
            "payees": payees(rows), "usual_monthly_spending": round(usual),
            "one_offs": [r["n"] for r in rows if r.get("suggest_one_off")]}


def read_statement(data, password=None, remembered=None):
    """Everything the review screen needs. Nothing is saved here."""
    info = parse_text(read_pdf(data, password))
    if not info["checks"]["ok"]:
        c = info["checks"]
        raise StatementError("The statement could not be read completely, so nothing was imported "
                             f"(read KES {c['paid_out']:,.2f} out against KES {c.get('statement_paid_out', 0):,.2f} "
                             f"on the statement; {c['balance_breaks']} balance mismatches).")
    rows = understand(info["rows"], remembered)
    info.update(summarise(rows))
    return info


# ---------------------------------------------------------------- 3. pasted M-PESA messages (6 Nov)
# After a statement ends, the household keeps spending. Every M-PESA payment sends an SMS confirmation; pasting
# them in keeps the picture current until the next statement. Each message becomes a row shaped like a
# statement row, so the same reading (M-PESA types, Kenyan directory, payee tags, reversals) applies. The receipt
# number is the same as on the statement, so a later statement skips these rows as duplicates.
# Formats follow Safaricom's confirmation messages. A message that does not match is listed back, never guessed.

SMS_START = re.compile(r"\b([A-Z0-9]{10})\s+[Cc]onfirmed\b")
SMS_WHEN = re.compile(r"\bon\s+(\d{1,2})/(\d{1,2})/(\d{2,4})\s+at\s+(\d{1,2}):(\d{2})\s*([AP]M)", re.I)
SMS_KSH = r"Ksh\s?([\d,]+\.\d\d)"
SMS_COST = re.compile(r"Transaction cost,?\s*" + SMS_KSH, re.I)
SMS_BAL = re.compile(r"(?:New )?M-PESA balance is\s*" + SMS_KSH, re.I)
SMS_PHONE = re.compile(r"\s(?:\+?254|0)(\d{9})\b")
SMS_FORMS = [
    # (kind, pattern); the groups are amount, then a name or details where there is one
    ("paybill", re.compile(SMS_KSH + r"\s+sent to\s+(.+?)\s+for account\s+(\S+?)\.?\s+on\s", re.I)),
    ("sent", re.compile(SMS_KSH + r"\s+sent to\s+(.+?)\s+on\s+\d", re.I)),
    ("buy_goods", re.compile(SMS_KSH + r"\s+paid to\s+(.+?)\.?\s+on\s+\d", re.I)),
    ("received", re.compile(r"You have received\s+" + SMS_KSH + r"\s+from\s+(.+?)\s+on\s+\d", re.I)),
    ("airtime", re.compile(r"You bought\s+" + SMS_KSH + r"\s+of airtime", re.I)),
    ("withdraw", re.compile(r"Withdraw\s+" + SMS_KSH + r"\s+from\s+(.+?)\s+New M-PESA", re.I)),
    ("deposit", re.compile(r"Give\s+" + SMS_KSH + r"\s+cash to\s+(.+?)\s+New M-PESA", re.I)),
    ("mshwari_in", re.compile(SMS_KSH + r"\s+transferred to M-?Shwari", re.I)),
    ("mshwari_out", re.compile(SMS_KSH + r"\s+transferred from M-?Shwari", re.I)),
    ("fuliza_repay", re.compile(r"Ksh\s?([\d,]+\.\d\d)\s+from your M-PESA has been used to (?:fully |partially )?pay "
                                r"your outstanding Fuliza", re.I)),
    ("fuliza", re.compile(r"Fuliza M-PESA amount is\s*" + SMS_KSH, re.I)),
]


def _sms_number(name):
    """SMS confirmations name the till or paybill but not its number. A stable 9-digit stand-in per name (real
    numbers have at most 7 digits) keeps payees apart, so tagging one shop never tags another."""
    import zlib
    return "9" + str(zlib.crc32(name.strip().lower().encode()) % 10 ** 8).zfill(8)


def _sms_masked(digits9):
    """0712345678 -> '0712***678', the statement's masking, so a person is the same payee in both."""
    full = "0" + digits9
    return f"{full[:4]}***{full[-3:]}"


def _sms_row(msg):
    m = SMS_START.search(msg)
    when = SMS_WHEN.search(msg)
    if not m:
        return None, "no receipt number"
    receipt = m.group(1)
    for kind, pat in SMS_FORMS:
        f = pat.search(msg)
        if not f:
            continue
        amount = _money(f.group(1))
        if kind == "fuliza":
            details, amount = "Overdraft of Credit Party", amount                     # borrowed into M-PESA
        elif kind == "fuliza_repay":
            details, amount = "OD Loan Repayment to 232323 - M-PESA Overdraw", -amount
        elif kind == "paybill":
            name, acc = f.group(2).strip(), f.group(3).strip()
            details, amount = f"Pay Bill Online to {_sms_number(name)} - {name} Acc. {acc}", -amount
        elif kind == "sent":
            who = f.group(2).strip()
            ph = SMS_PHONE.search(" " + who)
            if ph:
                name = SMS_PHONE.sub("", " " + who).strip()
                details = f"Customer Transfer to - {_sms_masked(ph.group(1))} {name.upper()}"
            else:                                   # no phone number: a Pochi la Biashara payment
                details = f"Customer Payment to Small Business to - {who.upper()}"
            amount = -amount
        elif kind == "buy_goods":
            name = f.group(2).strip()
            details, amount = f"Merchant Payment Online to {_sms_number(name)} - {name}", -amount
        elif kind == "received":
            who = f.group(2).strip()
            ph = SMS_PHONE.search(" " + who)
            if ph:
                name = SMS_PHONE.sub("", " " + who).strip()
                details = f"Funds received from - {_sms_masked(ph.group(1))} {name.upper()}"
            else:                                   # a bank or a business paying you
                details = f"Business Payment from {_sms_number(who)} - {who}"
        elif kind == "airtime":
            details, amount = "Airtime Purchase", -amount
        elif kind == "withdraw":
            details, amount = f"Customer Withdrawal At Agent Till {f.group(2).strip()}", -amount
        elif kind == "deposit":
            details = f"Deposit of Funds at Agent Till {f.group(2).strip()}"
        elif kind == "mshwari_in":
            details, amount = "M-Shwari Deposit", -amount
        else:                                       # mshwari_out
            details = "M-Shwari Withdraw"
        if not when:
            return None, "no date"
        d, mo, y, hh, mm, ap = when.groups()
        y = int(y) + (2000 if len(y) == 2 else 0)
        hour = int(hh) % 12 + (12 if ap.upper() == "PM" else 0)
        try:
            time = datetime(y, int(mo), int(d), hour, int(mm)).strftime("%Y-%m-%d %H:%M:%S")
        except ValueError:
            return None, "the date is not a real date"
        bal = SMS_BAL.search(msg)
        row = {"receipt": receipt, "time": time, "details": details, "amount": amount,
               "balance": _money(bal.group(1)) if bal else None}
        rows = [row]
        cost = SMS_COST.search(msg)
        if cost and _money(cost.group(1)) > 0:
            rows.append({"receipt": receipt, "time": time, "details": "Transaction Charge",
                         "amount": -_money(cost.group(1)), "balance": row["balance"]})
        return rows, None
    return None, "not a payment message this app reads"


def parse_messages(text, limit=500):
    """Pasted M-PESA messages -> rows like a statement's, oldest first, plus the messages that were not read."""
    text = re.sub(r"\s+", " ", text or "").strip()
    starts = [m.start() for m in SMS_START.finditer(text)]
    if not starts:
        raise StatementError("No M-PESA messages were found. Paste messages that start with a code like "
                             "TK12AB3CD4 Confirmed.")
    if len(starts) > limit:
        raise StatementError(f"Paste at most {limit} messages at a time.")
    rows, skipped, seen = [], [], set()
    for a, b in zip(starts, starts[1:] + [len(text)]):
        msg = text[a:b].strip()
        got, why = _sms_row(msg)
        if got is None:
            skipped.append({"message": msg[:80], "reason": why})
            continue
        if got[0]["receipt"] in seen:                # the same message pasted twice
            continue
        seen.add(got[0]["receipt"])
        rows += got
    if not rows:
        raise StatementError("None of these messages could be read. " +
                             (skipped[0]["reason"].capitalize() + "." if skipped else ""))
    rows.sort(key=lambda r: r["time"])
    for i, r in enumerate(rows):
        r["n"] = i
    return {"period": None, "rows": rows, "skipped": skipped,
            "checks": {"ok": True, "rows": len(rows), "from": "messages"}}


def read_messages(text, remembered=None):
    """Everything the review screen needs from pasted messages. Nothing is saved here."""
    info = parse_messages(text)
    rows = understand(info["rows"], remembered)
    info.update(summarise(rows))
    return info
