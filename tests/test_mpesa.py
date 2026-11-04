"""Tests for the M-PESA statement reader and the Kenyan business directory, on a made-up statement in Safaricom's
text layout (no real data). The reader was also run on a real 52-page statement: 1,739 rows, totals equal to the
cent, 0 balance breaks, 1.7 s (docs/experiments.md, 4 Nov)."""
import io
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import kenya_directory as kd  # noqa: E402
import mpesa  # noqa: E402

# Newest first, like a real statement; balances run correctly; a transfer and its charge share a receipt.
# John Mwangi is paid 8,000 by send money early every month (a landlord); Mary is a Pochi la Biashara.
SAMPLE = """Page 1 of 2
M-PESA STATEMENT
Customer Name: TEST USER
Statement Period: 01 Aug 2026 - 31 Oct 2026
SUMMARY
TRANSACTION TYPE PAID IN PAID OUT
TOTAL: 106,000.00 45,110.00
DETAILED STATEMENT
Receipt No. Completion Time Details Transaction Status Paid In Withdrawn Balance
TJ00000016 2026-10-28 18:00:00 Pay Bill Online to 247247 -
Equity Paybill Account Acc.
000123457157
Completed -15,000.00 72,890.00
TJ00000015 2026-10-21 13:00:00 Merchant Payment Online to
998877 - FRANCY ENTERPRISES
Completed -250.00 87,890.00
TJ00000014 2026-10-20 12:00:00 Merchant Payment Online to
7526468 - Quick Mart Banana
Road
Completed -1,200.00 88,140.00
TJ00000013 2026-10-15 09:00:00 Business Payment from 329299 -
STANDARD CHARTERED BANK
via API. Original conversation ID
is 2547-KE-IBNK-X.
Completed 15,000.00 89,340.00
TJ00000012 2026-10-08 12:00:00 Customer Payment to Small
Business to - 0712***345 MARY W
Completed -300.00 74,340.00
TJ00000011 2026-10-05 08:00:00 Unit Trust Invest To 4145555 -
ZIIDI MMF by M-PESA\\UnitTrust
Completed -2,000.00 74,640.00
TJ00000010 2026-10-02 10:00:00 Customer Transfer of Funds
Charge
Completed -100.00 76,640.00
TJ00000010 2026-10-02 10:00:00 Customer Transfer to -
0711***111 JOHN MWANGI
Completed -8,000.00 76,640.00
TJ00000009 2026-10-01 08:00:00 Salary Payment from 111111 -
NCBA BANK
Completed 30,000.00 84,740.00
Page 2 of 2
TJ00000008 2026-09-25 07:30:00 Pay Bill Online to 555555 -
MOJA EXPRESSWAY CO. LTD Acc. KDA
Completed -560.00 54,740.00
TJ00000007 2026-09-20 15:00:00 Customer Bundle Purchase
Completed -500.00 55,300.00
TJ00000006 2026-09-10 11:00:00 Funds received from -
0722***222 B PERSON
Completed 1,000.00 55,800.00
TJ00000005 2026-09-02 10:00:00 Customer Transfer of Funds
Charge
Completed -100.00 54,800.00
TJ00000005 2026-09-02 10:00:00 Customer Transfer to -
254711***111 JOHN MWANGI
Completed -8,000.00 54,800.00
TJ00000004 2026-09-01 08:00:00 Salary Payment from 111111 -
NCBA BANK
Completed 30,000.00 62,900.00
TJ00000003 2026-08-02 10:00:00 Customer Transfer of Funds
Charge
Completed -100.00 32,900.00
TJ00000003 2026-08-02 10:00:00 Customer Transfer to -
0711***111 JOHN MWANGI
Completed -8,000.00 32,900.00
TJ00000002 2026-08-01 08:00:00 Salary Payment from 111111 -
NCBA BANK
Completed 30,000.00 41,000.00
TJ00000001 2026-08-01 07:00:00 Customer Withdrawal At Agent Till
12345 - SHOP AGENT
Completed -1,000.00 11,000.00
Statement Verification Code
"""
JOHN = "person:0711***111:JOHN MWANGI"
EQUITY = "paybill:247247:000123457157"


def rows():
    return mpesa.understand(mpesa.parse_text(SAMPLE)["rows"])


def by_receipt(rs, receipt, charge=False):
    return next(r for r in rs if r["receipt"] == receipt and (r["mpesa_type"] == "charges") == charge)


def test_every_row_is_read_and_checked_against_the_statement():
    info = mpesa.parse_text(SAMPLE)
    assert info["checks"]["rows"] == 19
    assert info["checks"]["totals_match"] and info["checks"]["balance_breaks"] == 0 and info["checks"]["ok"]
    assert info["rows"][0]["receipt"] == "TJ00000001"                     # oldest first


def test_a_misread_statement_is_refused_not_imported():
    broken = SAMPLE.replace("Completed -1,200.00 88,140.00", "Completed -1,250.00 88,140.00")
    assert not mpesa.parse_text(broken)["checks"]["ok"]


def test_mpesa_types_are_exact_and_nothing_is_guessed():
    rs = rows()
    assert by_receipt(rs, "TJ00000014")["category"] == "food_groceries"            # directory: Quick Mart
    assert by_receipt(rs, "TJ00000014")["source"] == "directory"
    assert by_receipt(rs, "TJ00000008")["category"] == "transport"                 # directory: Moja Expressway
    assert by_receipt(rs, "TJ00000007")["category"] == "airtime_data"
    sent = by_receipt(rs, "TJ00000003")
    assert sent["mpesa_type"] == "sent" and sent["category"] == "mobile_money_transfers" and sent["payee_key"] == JOHN
    assert by_receipt(rs, "TJ00000005")["payee_key"] == JOHN                       # 254711 and 0711: same person
    charge = by_receipt(rs, "TJ00000003", charge=True)
    assert charge["mpesa_type"] == "charges" and charge["category"] == "charges"      # never "money sent"
    assert by_receipt(rs, "TJ00000012")["category"] == "unsorted"                  # Pochi: not guessed
    assert by_receipt(rs, "TJ00000015")["category"] == "unsorted"                  # unknown till: not guessed
    eq = by_receipt(rs, "TJ00000016")
    assert eq["kind"] == "spend" and eq["category"] == "unsorted" and eq["payee_key"] == EQUITY
    assert by_receipt(rs, "TJ00000001")["category"] == "unsorted"                  # cash
    assert by_receipt(rs, "TJ00000013")["kind"] == "own_in"                        # from the user's own bank
    assert by_receipt(rs, "TJ00000011")["kind"] == "own_out"                       # into a money market fund
    assert by_receipt(rs, "TJ00000002")["kind"] == "income"
    assert by_receipt(rs, "TJ00000006")["kind"] == "received"


def test_who_you_pay_suggests_rent_for_a_regular_landlord_and_remembers_tags():
    info = mpesa.summarise(rows())
    keys = [p["key"] for p in info["payees"]]
    john = next(p for p in info["payees"] if p["key"] == JOHN)
    assert keys[0] == JOHN and john["count"] == 3 and john["suggestion"]["tag"] == "housing"
    assert EQUITY in keys and "cash" in keys
    assert info["months"]["2026-10"]["savings"] == 0          # 15,000 in from the bank, 2,000 into the fund
    tagged = mpesa.understand(mpesa.parse_text(SAMPLE)["rows"], remembered={JOHN: "housing", EQUITY: "own_account"})
    assert by_receipt(tagged, "TJ00000003")["category"] == "housing"
    assert by_receipt(tagged, "TJ00000003", charge=True)["category"] == "charges"   # a charge stays a charge
    assert by_receipt(tagged, "TJ00000016")["kind"] == "own_out"
    assert JOHN not in [p["key"] for p in mpesa.summarise(tagged)["payees"]]


def test_big_payments_are_suggested_as_one_offs():
    rs = rows()
    mpesa.summarise(rs)
    assert by_receipt(rs, "TJ00000016").get("suggest_one_off")
    assert not by_receipt(rs, "TJ00000003").get("suggest_one_off")


@pytest.mark.parametrize("name,kind,label", [
    ("Naivas Limited-Ruaka", "buy_goods", "Food & groceries"),
    ("QUICK MART LTD RUAKA", "buy_goods", "Food & groceries"),
    ("KENYA POWER PREPAID", "pay_bill", "Electricity, water & gas"),
    ("BETIKA LTD", "pay_bill", "Betting"),
    ("GOODLIFE PHARMACY SARIT", "buy_goods", "Health"),
    ("MAMA OLIVE BUTCHERY", "buy_goods", "Food & groceries"),
    ("SHELLY BEAUTY SALON", "buy_goods", "Personal care"),
    ("STRATHMORE UNIVERSITY CATERING DEPARTMENT", "buy_goods", "Food & groceries"),   # catering, not fees
    ("Chipoz Africa- Two Rivers Mall", "buy_goods", "Eating out"),                     # a shop in a mall
    ("WESTGATE SHOPPING MALL LTD", "pay_bill", "Parking"),                             # the mall's own paybill
])
def test_directory_sorts_known_kenyan_businesses(name, kind, label):
    assert kd.lookup(name, kind=kind)[0] == label


@pytest.mark.parametrize("name", ["JOHN KAMAU ENTERPRISES", "Equity Paybill Account", "TOTAL BUILDING MATERIALS",
                                  "SBM Bank Kenya Limited.", "BEST DEALS LTD"])
def test_directory_never_guesses(name):
    assert kd.lookup(name, kind="buy_goods") is None


def test_health_and_shopping_get_their_own_names_not_a_forced_model_category():
    assert kd.lookup("GOODLIFE PHARMACY", kind="buy_goods")[1] == "health"
    assert kd.LABELS["Shopping"] == "shopping" and "shopping" in mpesa.OUTSIDE


def test_suggestions_are_hints_and_never_override_the_directory():
    regular_sends = [("2026-07-09", 1900), ("2026-08-19", 900), ("2026-09-04", 400), ("2026-10-27", 1000)]
    assert mpesa.suggest(regular_sends, "sent") is None              # a seller paid by send money: no "family?"
    small_till = [(f"2026-{m:02d}-1{m % 9}", 500) for m in range(3, 11)]
    assert mpesa.suggest(small_till, "buy_goods")["tag"] == "food_groceries"     # an unknown till: a hint
    rent = [("2026-08-02", 8000), ("2026-09-01", 8000), ("2026-10-03", 8000)]
    assert mpesa.suggest(rent, "sent")["tag"] == "housing"
    barber = [{"kind": "spend", "payee_key": "till:1", "source": "pattern", "category": "personal_care",
               "mpesa_type": "buy_goods", "amount": -500, "time": f"2026-{m:02d}-10 10:00:00", "payee": "X GROOMERS",
               "label": "Personal care"} for m in range(3, 11)]
    assert mpesa.payees(barber) == []                                 # already labelled: not even a card


def test_not_a_statement_and_wrong_passwords_are_explained():
    with pytest.raises(mpesa.StatementError, match="does not look like"):
        mpesa.parse_text("Hello, this is a letter.")
    from pypdf import PdfWriter
    w = PdfWriter()
    w.add_blank_page(width=200, height=200)
    w.encrypt("1234", algorithm="AES-256")
    buf = io.BytesIO()
    w.write(buf)
    with pytest.raises(mpesa.StatementError, match="locked"):
        mpesa.read_pdf(buf.getvalue())
    with pytest.raises(mpesa.StatementError, match="did not open"):
        mpesa.read_pdf(buf.getvalue(), "0000")
    assert mpesa.read_pdf(buf.getvalue(), "1234") == ""        # opens with the right password


def test_money_in_is_taggable_and_bank_money_is_not_income_until_the_user_says():
    rs = rows()
    bank = by_receipt(rs, "TJ00000013")
    assert bank["kind"] == "own_in" and bank["payee_key"] == "in:standard chartered bank"
    info = mpesa.summarise(rs)
    ins = [p for p in info["payees"] if p["direction"] == "in"]
    outs = [p for p in info["payees"] if p["direction"] == "out"]
    assert ins and outs and info["payees"].index(ins[0]) > info["payees"].index(outs[-1])     # pay first, then in
    tagged = mpesa.understand(mpesa.parse_text(SAMPLE)["rows"], remembered={"in:standard chartered bank": "income"})
    assert by_receipt(tagged, "TJ00000013")["kind"] == "income"
