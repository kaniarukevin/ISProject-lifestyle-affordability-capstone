"""Sending email (password reset codes, security notices) through Brevo's web API.

Render's free plan blocks ordinary mail servers (SMTP), so mail goes out over HTTPS instead. Needs two
environment variables, set on Render and in .env.local, never in code: BREVO_API_KEY and MAIL_FROM (a sender
address verified in Brevo, for example a Gmail address). Without them nothing is sent: on a developer's machine
the message is printed to the server console instead, so the reset flow can still be tried locally.
"""
import json
import logging
import os
import urllib.error
import urllib.request

log = logging.getLogger("mailer")
API = "https://api.brevo.com/v3/smtp/email"


def configured():
    return bool(os.environ.get("BREVO_API_KEY") and os.environ.get("MAIL_FROM"))


def send(to, subject, text):
    """Send a plain-text email. Returns True if it was handed to Brevo (or printed locally)."""
    if not configured():
        if os.environ.get("RENDER"):          # deployed without a key: say so in the logs, never print the message
            log.warning("email not configured: BREVO_API_KEY / MAIL_FROM missing")
            return False
        log.warning("email not configured, printing instead.\nTo: %s\nSubject: %s\n\n%s", to, subject, text)
        return True
    body = json.dumps({"sender": {"name": "Tosha", "email": os.environ["MAIL_FROM"]}, "to": [{"email": to}],
                       "subject": subject, "textContent": text}).encode()
    req = urllib.request.Request(API, data=body, method="POST", headers={
        "api-key": os.environ["BREVO_API_KEY"], "content-type": "application/json", "accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return 200 <= r.status < 300
    except urllib.error.HTTPError as exc:      # Brevo said no: its reason (never contains the key) helps fix it
        log.warning("email to Brevo failed: HTTP %s %s", exc.code, exc.read()[:300].decode(errors="replace"))
        return False
    except Exception as exc:                   # a failed email must not break the request that sent it
        log.warning("email to Brevo failed: %s %s", type(exc).__name__, str(exc)[:200])
        return False
