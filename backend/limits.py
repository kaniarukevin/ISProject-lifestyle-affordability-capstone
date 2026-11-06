"""One rule for every number the app accepts (audit A-01, A-07).

NaN and Infinity are valid floats in Python and in PostgreSQL, so without this check one bad value could be
stored and break every calculation that reads it (found in the audit, 5 Nov: one Infinity payment made the
dashboard fail for good). KES 100 million is far above any household figure but stops 1e15 and overflow."""
import json
import math

MAX_AMOUNT = 100_000_000
MAX_ROWS = 2_000            # records in one request (a year of busy M-PESA use is well under this per import)
MAX_YEARS_BACK = 5          # oldest spending date accepted


def is_real(x):
    """True for a finite number no bigger than MAX_AMOUNT either way."""
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x) and abs(x) <= MAX_AMOUNT


def bad_json_number(raw):
    """The first NaN, Infinity or overflowing number in a JSON body (e.g. 1e400), or None. Python's JSON reader
    turns these into float nan/inf silently, so they are found while parsing."""
    found = []

    def constant(token):                   # NaN, Infinity, -Infinity
        found.append(token)
        return 0.0

    def number(token):
        if not math.isfinite(float(token)):
            found.append(token)
        return 0.0
    try:
        json.loads(raw, parse_constant=constant, parse_float=number)
    except ValueError:
        return None                         # not JSON at all: the endpoint's own check answers that
    return found[0] if found else None
