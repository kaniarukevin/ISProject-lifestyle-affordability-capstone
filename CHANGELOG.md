# Changelog

Format follows Keep a Changelog. Dataset tags: `v0.1-data` onward.

## [Unreleased]
### Added
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
- Why this score (SHAP): exact Shapley values over six plain-language parts, on the dashboard and in "Can I afford it?"; 12-month track record note and a cautious Stretch rule for a fragile year.
- Deviations from the proposal and requirements traceability (`docs/deviations.md`).
- Privacy notice and recorded consent (Data Protection Act 2019): shown at sign-up, asked once of older accounts, required before reading statements; "Delete my account" in Your household.
- Spending screen loads a month summary and fetches a month's records only when opened (`/me/transactions/summary`, `?month=`).
- Production safety: the hosted server refuses to start without a real `SECRET_KEY`; every error is plain JSON; uploads over 11 MB are refused before reading.

### Fixed
- M-PESA reversals: the reversed payment (and its charge) is now left out of spending as well as the refund; previously the refund was counted as money received and the payment stayed as spending. A reversal of a charge is no longer counted as a charge.
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
