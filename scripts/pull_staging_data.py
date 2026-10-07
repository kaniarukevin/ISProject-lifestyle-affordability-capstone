import json, os, sys, urllib.request
from pathlib import Path

BASE = "https://api-wasaa-lifestyle.webmasterskenya.com/api/v1"
OUT = Path("data/staging")
OUT.mkdir(parents=True, exist_ok=True)

def call(url, data=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers)
    return urllib.request.urlopen(req, timeout=60).read()

def find(obj, key):
    if isinstance(obj, dict):
        if key in obj:
            return obj[key]
        for v in obj.values():
            r = find(v, key)
            if r:
                return r
    if isinstance(obj, list):
        for v in obj:
            r = find(v, key)
            if r:
                return r

body = json.dumps({"email": os.environ["WASAA_EMAIL"], "password": os.environ["WASAA_PASSWORD"]}).encode()
token = find(json.loads(call(f"{BASE}/auth/login", body)), "accessToken")
if not token:
    sys.exit("no accessToken in login response")

for name in ["spending_records", "budget_categories", "households", "dependants"]:
    (OUT / f"{name}.csv").write_bytes(call(f"{BASE}/sandbox/dataset/{name}.csv", token=token))
    print("saved", name)