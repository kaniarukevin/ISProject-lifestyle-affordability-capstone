# Changelog

Format follows Keep a Changelog. Dataset tags: `v0.1-data` onward.

## [Unreleased]
### Fixed
- Screens load faster: Overview needs 15 database queries instead of 36, the budget forecast 12 instead of 21; the last figures show at once while fresh ones load, and are removed at log out.
- A statement month where the tagged pay did not arrive but money came in from your own accounts or from people is no longer scored as no income; it counts up to your usual income.
- Past months keep the income they were lived on: raising your income no longer turns earlier months Stable. Saving a new income asks whether it changed or a mistake is being corrected.

### Added
- Privacy notice redesigned: one card per section, "What we never keep" highlighted, Download my data and Delete my account inside Your rights; "I agree" stays at the bottom of the consent screen. Notice version 2026-11-07 (asks once to agree again).
- Money coming in: "Bonus or one-off" (never counted as usual income) and "Change one payment" for a source that sends more than one kind of money (a salary and your own savings from the same bank).
- Search your records (payee, category or amount); Records one tap from Overview, Forecast and You.
- Profile: first name, how money comes in (pick all that apply), studying, children in school; the email is returned with the profile.

### Fixed
- The forecast no longer raises January, May and September for people who pay no school fees; the fee months now follow the user's own fees (held-out error in those months 10,833 to 10,490).

### Added
- "Plan a change": one check for a whole decision, with an upfront cost (savings or instalments), monthly, termly or yearly costs, money it brings in and a duration; checked while paying instalments and after; can be applied.
- Low-month check: when income varies, every check and the budget forecast are repeated on a low month (from pay that arrived, or the setup answer `incomeLow`).
- Borrowing warning: Fuliza uses and mobile-lender repayments over the last 3 months, by a stated rule; shown beside the score, never in it.
- Goals tracked from savings: money saved since each goal was set counts towards it after one confirmation (`/me/goals/track`), earliest deadline first.
- Paste M-PESA messages (`/me/messages/preview`, then the usual import with `"origin": "messages"`); "up to date until" (`records_until`) on the dashboard.
- Forecast check: each month's forecast is kept before the month begins and compared with what was spent; pooled real-month accuracy in the admin view.
- Budget forecast (`/me/budget-forecast`): the next three months against the budget at the usual pace, the savings path, the first short month with an amount to put aside before it, the lines likely to run over and goals at risk; works on setup estimates on day one.
- "Can I afford it?" shows the recommended budget now and after the change, side by side (proposal 3.4.6).
- Log out really logs out: the token is revoked at once, and "log out everywhere" ends every session; tokens last 14 days instead of 30 (audit A-08).
- Continuous testing: a GitHub Actions workflow runs every test on each push and pull request; `backend/requirements-dev.txt`; the HMM baseline tests skip cleanly on a fresh clone (audit A-17, A-18). Root README.
- Unit tests for HMM state detection (`tests/test_hmm.py`).
- Experiment log (`docs/experiments.md`).
- Financial state detection: Random Forest (held-out accuracy 0.799) replaces the HMM (0.531) (#46).
- Affordability engine: monotonic score, savings safety rule, purchases, savings goals, what-to-cut, advice (#50, #53, #55).
- Web Masters U-CS 37 forecast service with a deployable ensemble (#57).
- Dynamic budget (#59) and obligations, debts and goals (#61).
- Flutter app (#63), PostgreSQL storage with accounts (#65), spending (#73), dashboard (#75), budget (#77) and "Can I afford it?" (#78) screens.
- One shared household picture, savings balance, duration-aware purchases and month-by-month cash flow (#79).
- "I'm doing this": a checked scenario becomes a debt, commitment, goal or profile change (#80).
- Personal budget from the user's own spending; no unused lines; auto-saved; safe to spend per day; saving shown apart from spending (#81).
- Rough monthly estimates at setup, so the app works on day one (#82).
- ML forecast for app users (boosted tree with fee-month and December flags, personal 80% range, fee-month floor) (#83).
- M-PESA statement upload: verified reading, M-PESA types, Kenyan business directory, nothing guessed, Who you pay tags and corrections, money-in tags, statement-safe state model, dashboard timeline (#84).
- Admin dashboard: service health, model register, masked user list; admins named in `ADMIN_EMAILS` (#85).
- Why this score (SHAP): exact Shapley values over six plain-language parts, on the dashboard and in "Can I afford it?"; 12-month track record note; in a fragile year, "Can I afford it?" lowers Affordable to Stretch only when the cost does not fit the year's average month with a 10% margin (otherwise it adds a caution), and the answer card says when the verdict was lowered.
- Deviations from the proposal and requirements traceability (`docs/deviations.md`).
- Privacy notice and recorded consent (Data Protection Act 2019): shown at sign-up, asked once of older accounts, required before reading statements; "Delete my account" in Your household.
- Spending screen loads a month summary and fetches a month's records only when opened (`/me/transactions/summary`, `?month=`).
- Budget check: lines over budget, or 80%+ used well ahead of the calendar, with the month-end total at this pace (dashboard and budget screen).
- Download my data: everything the app keeps about the user in one JSON file (Your household → Your account).
- Dashboard about 5x faster: the month-by-month timeline is scored in one pass (511 ms to 100 ms on a year of records), with identical results.
- Bills can have a next due date: "Coming up" on the dashboard (overdue, or due within 7 days) and a Paid button that moves the date on by the bill's frequency.
- Goals at risk: flagged when the usual put-aside money cannot reach them in time, with a realistic time; goals now store a deadline month and count down.
- "Your lifestyle" card: rent, loans and saving as shares of income against stated rules of thumb, plus food, transport, money sent and betting.
- Three-month outlook on the dashboard (this month and the next two, with ranges that widen further ahead) and a note when a coming month should cost more than income; same model, checked at each horizon (`scripts/forecast_horizons.py`).
- Change password (current password required; other devices are logged out), a show/hide eye on every password box, and editing of incomes, bills, debts, goals and typed-in spending (statement payments: category and one-off only).
- Production safety: the hosted server refuses to start without a real `SECRET_KEY`; every error is plain JSON; uploads over 11 MB are refused before reading.

### Fixed
- A Fuliza draw was counted as money taken out of savings, lowering that month's saving.
- Rate limits read the caller's address from Cloudflare's `CF-Connecting-IP`, which cannot be faked; the admin overview shows which source is used (audit A-04). Wrong passwords are counted per account and address, so a stranger cannot lock someone out (A-05).
- The engine endpoints `/affordability`, `/budget` and `/commitments` need a login and allow 60 calls a minute; `/forecast` and `/health` for Web Masters are unchanged (A-06).
- Bad input can no longer break an account (audit P0, 6 Nov): NaN, Infinity and amounts above KES 100 million are refused everywhere (A-01); saved budgets are checked, and old bad ones are ignored (A-02); a statement import only accepts rows the preview read and signed for that user (A-03); spending dates must be within the last 5 years and not in the future, at most 2,000 records per request (A-07).
- M-PESA reversals: the reversed payment (and its charge) is now left out of spending as well as the refund; previously the refund was counted as money received and the payment stayed as spending. A reversal of a charge is no longer counted as a charge.
- Reached goals no longer come back: the app dropped the goal's `done` flag when saving Commitments, and matched goals to the server's figures by position (wrong once a goal was reached).
- A log-in token kept being accepted after its account was deleted; tokens now carry a password fingerprint and are checked against the account on every request.
- App name in the browser tab, home screen and phone launchers (was "lifestyle_affordability" / "A new Flutter project").

### Changed
- M-PESA charges are now their own category ("M-PESA charges"), no longer folded into `mobile_money_transfers` (#84).

## [v0.1.1] - 2026-10-01 - Categories aligned with the proposal (PR #22)
### Changed
- Spending categories now match the proposal's ten: `investment_vehicle` folded into `savings`, M-Pesa fees folded into `mobile_money_transfers`.
- Synthetic dataset and HMM regenerated. Held-out HMM accuracy 0.531 (majority baseline 0.378), Strained recall 0.441.

## [v0.1-data] - 2026-10-01 - Synthetic dataset v2
### Fixed
- **Wage income never loaded.** Member IDs were float strings (`916.0_7`) while the household file used `140_1`, so no rows joined and wage income was zero for every household. `total_income` was only pension, rent and investment income (about 5% of households).
- **Swapped urban labels.** KIHBS `eatype` code 2 holds all Nairobi and Mombasa households and is core urban, not peri-urban.
- **Business flag** was always False (category compared with 1).
- **Households were sampled with replacement**, producing duplicates.
- **HMM evaluation order** mismatch and wrong-household state labels (E1).
- **Normalisation leakage:** features were normalised with test-set statistics; now train households only, with one shared split (`household_split.csv`).
- **Ratio feature:** was expenditure/income with a 5.0 placeholder for zero-income months. Now income/expenditure, bounded, with `zero_income_flag`.
- **Debt-service ratio** used a household constant; now uses each month's actual repayments.

### Changed
- Incomes in 2025 KES (KNBS CPI), tiers from employer type, NSSF/NHIF and contract (`formal_salaried`, `informal_irregular`).
- 300 households (was 150), stratified 50/50 core-urban / peri-urban, 42 counties.
- Spending built bottom-up: rent, school fees, utilities and loan repayments are fixed and match the obligations and debt tables.
- M-Pesa fees use the 2025 Safaricom send-money and withdrawal tariffs.
- Debt prevalence anchored on FinAccess 2024 (64% of adults use credit); non-mortgage loans in 43% of households.
- Dependants and school-age children from KIHBS member ages.
- HMM: unsupervised KMeans initialisation, five features, state names assigned by spending ratio (not by matching true labels).

### Known limitations and items to verify
- KIHBS has no profit measure for self-employed households, so they are excluded.
- Hidden-state transitions, spending ranges, loan terms and school-fee levels are assumptions.
- 2017-2020 CPI inflation rates in `04` are from memory and need checking (issue open).
- KIHBS `has_electricity` is broken (about 1% yes) and unused.
