"""Kenyan business directory for sorting M-PESA payments (capstone).

Two kinds of entries, checked in order:
1. Well-known brands and organisations (supermarkets, fuel, utilities, betting, funds, universities...).
2. Descriptive words that Kenyan business names often carry (BUTCHERY, CHEMIST, SALON, CATERERS...).

Each match gives a label the user sees and one of the app's 10 categories (the categories the models were trained
on). Spending with no place in those 10 (Health, Shopping, Personal care, Government) gets its own category the
user sees; the models treat it like unsorted money (spread over everyday categories), so it cannot distort them. Entries are deliberately conservative: a wrong sort is
worse than none, because "unsorted" is honest and the user can always tag a payee.
Brands are well-known chains and organisations only; no entry was added for a business seen only on the developer's
own statement, so coverage measured on that statement is not inflated (removed three such entries, 4 Nov).
"""
import re

UNSORTED = "unsorted"

LABELS = {                      # label shown to the user -> category the models use
    "Rent": "housing",
    "Food & groceries": "food_groceries",
    "Eating out": "entertainment",
    "Transport": "transport",
    "Fuel": "transport",
    "Parking": "transport",
    "Electricity, water & gas": "utilities",
    "Internet & home": "utilities",
    "TV & streaming": "entertainment",
    "Airtime & data": "airtime_data",
    "School fees": "school_fees",
    "Loan repayment": "loan_repayment",
    "Betting": "entertainment",
    "Fun": "entertainment",
    "Giving": "mobile_money_transfers",
    "Chama & groups": "mobile_money_transfers",
    "Health": "health",
    "Shopping": "shopping",
    "Personal care": "personal_care",
    "Government & fees": "other",
}
SAVINGS = "Savings & investments"     # money into the user's own fund: not spending (handled by the reader)

_B = r"(?<![a-z0-9])"                 # word start
_E = r"(?![a-z0-9])"                  # word end


def _w(*words):
    return re.compile("|".join(_B + w + _E for w in words))


# 1. Brands and organisations. Order matters: the first match wins.
BRANDS = [
    (SAVINGS, _w(r"ziidi", r"etica", r"nabo capital", r"cytonn", r"sanlam", r"britam", r"cic asset", r"old mutual",
                 r"icea lion", r"madison", r"zimele", r"lofty[- ]?corban", r"kuza", r"gulfcap", r"standard investment bank",
                 r"money market", r"mmf", r"unit trust", r"asset management", r"investment bank")),
    ("Loan repayment", _w(r"helb", r"fuliza", r"m-?pesa overdraw", r"overdraw", r"m-?shwari loan", r"kcb m-?pesa loan",
                          r"tala", r"branch international", r"branch microfinance", r"zenka", r"okash", r"hustler fund",
                          r"timiza", r"zash", r"opesa", r"lpesa", r"mkopo\w*", r"loans?")),
    ("Electricity, water & gas", _w(r"kplc", r"kenya power", r"prepaid tokens?", r"nairobi (?:city )?water",
                                    r"water (?:and|&) sewerage", r"water company", r"water services", r"k-?gas",
                                    r"pro ?gas", r"afrigas", r"hashi gas", r"total gas")),
    ("Internet & home", _w(r"safaricom home", r"home fibre", r"faiba", r"jtl", r"zuku", r"wananchi", r"poa internet",
                           r"starlink", r"airtel home", r"telkom", r"internet", r"wi-?fi")),
    ("TV & streaming", _w(r"dstv", r"multichoice", r"gotv", r"showmax", r"netflix", r"startimes", r"spotify",
                          r"youtube", r"apple\.com", r"google play")),
    ("Airtime & data", _w(r"safaricom offers", r"bundles?", r"airtime", r"data plan", r"airtel money", r"airtel kenya")),
    ("Betting", _w(r"sportpesa", r"betika", r"odibets", r"mozzart", r"betway", r"shabiki", r"sportybet", r"22bet",
                   r"betin", r"bangbet", r"helabet", r"kwikbet", r"bet ?lion", r"betting", r"bet")),
    ("Food & groceries", _w(r"naivas", r"quick ?mart", r"carrefour", r"majid al futtaim", r"chandarana", r"magunas",
                            r"cleanshelf", r"eastmatt", r"mulleys", r"jazaribu", r"khetia'?s?", r"tumaini",
                            r"powerstar", r"uchumi", r"tuskys", r"kassmatt", r"foodplus")),
    ("Eating out", _w(r"kfc", r"java house", r"java", r"artcaffe", r"art caffe", r"pizza inn", r"chicken inn",
                      r"galito'?s", r"chipo?z", r"burger king", r"domino'?s", r"subway", r"kenchic", r"big square", r"pizza hut",
                      r"simbisa", r"debonairs", r"cafe deli")),
    ("Fuel", _w(r"totalenergies", r"total energies", r"total kenya", r"total service station", r"rubis", r"shell",
                r"vivo energy", r"ola energy", r"hass petroleum", r"gulf energy", r"lake oil", r"hashi energy",
                r"national oil", r"nock", r"astrol")),
    ("Transport", _w(r"uber", r"bolt", r"little cab", r"little ride", r"faras", r"yego", r"moja expressway",
                     r"expressway", r"kenya railways", r"madaraka express", r"sgr", r"easy coach", r"mash poa",
                     r"modern coast", r"dreamline", r"super metro", r"embassava", r"citi hoppa", r"metro trans",
                     r"2nk", r"kenya bus", r"ntsa", r"kenya airways", r"jambojet", r"skyward", r"safarilink")),
    ("Health", _w(r"goodlife", r"haltons", r"pharmaplus", r"aga khan", r"nairobi hospital", r"m\.?p\.? shah",
                  r"gertrude'?s", r"mater", r"karen hospital", r"avenue healthcare", r"nhif", r"sha",
                  r"social health")),
    ("Shopping", _w(r"bata", r"lc waikiki", r"mr ?price", r"woolworths", r"deacons", r"jumia", r"kilimall",
                    r"hotpoint", r"avechi", r"phone place", r"sports house", r"text ?book cent(?:re|er)", r"game stores")),
    ("Government & fees", _w(r"ecitizen", r"e-citizen", r"kra", r"kenya revenue", r"immigration", r"huduma", r"nssf",
                             r"land registry", r"business registration")),
    ("Giving", _w(r"church", r"chapel", r"cathedral", r"parish", r"ministr(?:y|ies)", r"mosque", r"masjid", r"temple",
                  r"offering", r"tithe", r"harambee", r"fellowship", r"pcea", r"aipca", r"sda", r"catholic",
                  r"anglican", r"deliverance", r"citam", r"mavuno")),
]

# 2. Descriptive words in business names. Only words that mean one thing in Kenyan business names.
WORDS = [
    ("Food & groceries", _w(r"supermarkets?", r"super market", r"hypermarket", r"mini ?marts?", r"butcher(?:y|ies)?",
                            r"grocer(?:s|y|ies)?", r"greengrocers?", r"mama mboga", r"fruits?", r"vegetables?",
                            r"dairy", r"milk bar", r"bakery", r"bakers", r"cereals?", r"posho mill", r"caterers?",
                            r"catering", r"canteen", r"cafeteria", r"wholesalers?", r"wholesale", r"provision stores?",
                            r"fish", r"poultry", r"eggs")),
    ("Eating out", _w(r"restaurants?", r"eatery", r"grill", r"bistro", r"cafe", r"café", r"coffee", r"lounge",
                      r"pub", r"bar", r"nyama choma", r"food house", r"fast ?foods?", r"hotels?", r"kitchen",
                      r"pizza", r"chips", r"burgers?", r"wines?", r"spirits", r"liquor", r"club")),
    ("Fuel", _w(r"petrol(?:eum)?", r"fuel", r"service station", r"filling station", r"petrol station")),
    ("Parking", _w(r"parking", r"mall", r"car park", r"EVOPAY")),
    ("Transport", _w(r"travel(?:l?ers)?", r"shuttles?", r"bus service", r"coach", r"auto ?spares", r"garage",
                     r"car wash", r"tyres?", r"motors")),
    ("Health", _w(r"pharmac(?:y|ies)", r"chemists?", r"pharma", r"hospitals?", r"clinics?", r"medical", r"health",
                  r"dental", r"optic(?:al|ians)?", r"laborator(?:y|ies)", r"nursing home", r"maternity")),
    ("Personal care", _w(r"salon", r"barber(?:shop|s)?", r"groomers?", r"kinyozi", r"spa", r"beauty", r"cosmetics?",
                         r"nails?")),
    ("Shopping", _w(r"boutique", r"fashions?", r"clothing", r"clothes", r"shoes?", r"hardware", r"furniture",
                    r"electronics?", r"bookshop", r"books", r"stationer(?:s|y)", r"phones?", r"mobile accessories",
                    r"jewel(?:le)?ry", r"cosmetics shop", r"gift shop")),
    ("School fees", _w(r"universit(?:y|ies)", r"college", r"school", r"academy", r"institute", r"polytechnic",
                       r"tvet", r"day care", r"daycare", r"kindergarten")),
    ("Rent", _w(r"rent", r"apartments?", r"propert(?:y|ies)", r"realtors?", r"lettings?", r"estate agents?",
                r"housing")),
    ("Chama & groups", _w(r"chama", r"self help group", r"welfare", r"investment group", r"merry ?go ?round")),
    ("Electricity, water & gas", _w(r"water", r"gas", r"tokens?")),
]

BANKS = _w(r"bank", r"equity", r"co-? ?operative", r"coop", r"kcb", r"absa", r"ncba", r"stanbic", r"dtb",
           r"diamond trust", r"i ?& ?m", r"im bank", r"family bank", r"sidian", r"loop", r"sbm", r"prime bank",
           r"gulf african", r"credit bank", r"kingdom bank", r"faulu", r"kwft", r"postbank", r"pesapal", r"paystack",
           r"lipa na kcb", r"jenga", r"cellulant", r"dpo", r"ipay", r"evopay", r"pesalink")


def lookup(name, account=None, kind="pay_bill"):
    """('Food & groceries', 'food_groceries', 'directory') for a payee name, or None when not certain.
    kind: 'pay_bill' or 'buy_goods'. A mall's own paybill is usually parking; a till with 'mall' in its name is a
    shop inside the mall (found on a real statement: a chips outlet at Two Rivers Mall was called parking)."""
    text = f"{name} {account or ''}".lower()
    for label, pattern in BRANDS:
        if pattern.search(text):
            return label, LABELS.get(label), "directory"
    if BANKS.search(name.lower()):
        return None                    # a bank or payment gateway: could be anyone; the user decides
    for label, pattern in WORDS:
        if label == "Parking" and kind == "buy_goods" and "parking" not in text:
            continue
        if pattern.search(text):
            return label, LABELS.get(label), "pattern"
    return None


def size():
    return {"brand_groups": len(BRANDS), "word_groups": len(WORDS),
            "patterns": sum(p.pattern.count("|") + 1 for _, p in BRANDS + WORDS)}
