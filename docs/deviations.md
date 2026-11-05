# Deviations from the proposal and requirements traceability

Project: Personalised Household Lifestyle Affordability and Budget Recommendation System
Student: Kevin Kaniaru (164806). Supervisor: Eunice Manyasi.
Proposal: `KevinKaniaru_164806_EuniceManyasi.docx`. Evidence: `docs/experiments.md` (dated entries), `tests/`, `CHANGELOG.md`.
Status as of 5 Nov 2026. Defence: 23 Nov 2026.

The supervisor allowed deviations from the proposal (13 Oct) provided the system works and every change is
documented. This document lists each change, the reason for it and the evidence. Every decision to replace a
proposed method was made by comparing it with the alternative on held-out data, and the numbers are in the
experiment log.

Status key used below:

- **Built**: built as the proposal describes.
- **Changed**: built, but in a different way from the proposal. A deviation, explained in Part A.
- **Partly built**: some of the promise is in the system.
- **Not built**: not in the system, with the reason given.
- **Planned**: scheduled before the defence.

---

## Part A: Deviations

### D1. Financial state detection: Hidden Markov Model replaced by a Random Forest classifier

- **Proposal (3.2.3, 3.5):** a Gaussian HMM (hmmlearn, Baum-Welch/Viterbi) detects Stable, Strained or Critical each month.
- **Built:** the HMM was built and evaluated (`data_generation/08_train_hmm.py`, `tests/test_hmm.py`,
  `notebooks/05_state_detection.ipynb`). The deployed state detector is a Random Forest classifier
  (300 trees, minimum leaf 5) trained on the same engineered features.
- **Why:** on 60 held-out households (720 household-months) the HMM reached 0.531 exact accuracy, no better than
  a fitted threshold rule (0.532). The Random Forest reached 0.799, and its Stable/Critical mix-ups fell from 0.064
  to 0.007 (experiments, 22 Oct). An unsupervised HMM finds clusters that do not have to match the meaning of the
  three states. A supervised model learns the meaning directly.
- **Added:** a second "statement-safe" Random Forest (0.750 accuracy) uses only figures that an M-PESA statement
  gives exactly. It is used when more than 10% of a household's spending is unsorted. When 30% of everyday money
  was deliberately mis-sorted, the main model changed state for 27 of 60 households and the safe model for 0 of 60
  (experiments, 4 Nov).
- **Limitation:** the states are labelled by the synthetic generator's rules, so 0.799 shows the model recovers
  those definitions. It does not prove accuracy on real households. Volunteer testing (D15) is the check for that.

### D2. Expenditure forecasting: LSTM replaced by a gradient-boosted tree and a budget blend

- **Proposal (3.2.3):** an LSTM (TensorFlow/Keras, MSE, Adam) forecasts each category one to three months ahead,
  trained on 9 months and tested on 3.
- **Built:** an LSTM was built and compared. PyTorch was used instead of Keras; the choice of library does not
  change the result. Two forecasters are deployed:
  - **App users:** a gradient-boosted tree that predicts next month's spending as a ratio of the household's own
    median, with school-fee-month and December flags, a fee-month floor and a personal 80% range. On held-out
    KIHBS-informed households its test MAE was KES 9,967, against KES 10,719 for the median
    (experiments, 4 Nov, parts 1–4).
  - **Web Masters (U-CS 37) service:** 0.75 × budget + 0.25 × 12-month median, with the category split by a
    boosted tree.
- **Why:** in the rolling backtest the LSTM was the weakest method. Its total MAE was KES 9,974, against 7,635 for
  the blend and 8,155–8,567 for the boosted trees. On the final test months it scored 10,586 against 7,931 for the
  blend. Adding it to an ensemble made both totals and categories worse (experiments, 22 Oct). With 6 to 12 months
  per household there are too few sequences for an LSTM to learn from.
- **One to three months (5 Nov):** the same model forecasts this month and the next two, with wider ranges further
  out. It beats the median at every step on held-out households: 1 month 9,967 vs 10,719, 2 months 10,354 vs 11,738,
  3 months 11,000 vs 11,791 (KES). Its 80% ranges hold 83–85% of months. Separate per-horizon models were tried and
  were no better (experiments, 5 Nov). Forecasts are for total spending; the category split comes from the
  household's own shares, not one forecast per category as the proposal described.

### D3. Affordability score: Random Forest replaced by monotonic gradient boosting. Budget allocation stays Random Forest

- **Proposal (3.2.3):** one Random Forest produces the budget allocation, a 0–100 affordability score and the
  scenario score.
- **Built:**
  - **Score:** score = 100 × (P(Stable) + 0.5 × P(Strained)) from two monotonic gradient-boosting models.
  - **Budget allocation:** a Random Forest, as proposed, blended half and half with the average split of Stable
    households, then with the user's own spending shares.
- **Why the score changed:** the Random Forest used spending shares. Raising one category lowers every other
  share, so a more expensive scenario could look healthier. In 40% of held-out households a bigger cost never
  raised the Random Forest score, which means 60% of households could see a costlier choice score better. The
  monotonic model makes "more cost never raises the score" hold for 100% of households, at the price of lower state
  accuracy (0.654). This is the same choice of consistency over accuracy that credit scoring makes
  (experiments, 22 Oct).
- **Why the budget stayed Random Forest:** the half-and-half split had the lowest held-out error,
  KES 7,021 per household, against 7,155 for the Random Forest alone and 7,295 for one size for all
  (experiments, 28 Oct).
- **Pipeline order:**
  - The state feeds the budget, as proposed: Strained and Critical households move 25% and 50% of entertainment
    money into savings.
  - The score is computed from the household's recent months and does not take the forecast as an input. The
    forecast is shown beside the score.

### D4. Verdict labels and the safety rule

- **Proposal (3.4.3):** Affordable, Marginally Affordable, Not Affordable.
- **Built:**
  - Verdicts are Affordable (score of 56 or more), Stretch (33 to 55) and Not affordable (below 33). Each cut-off
    lies halfway between the mean scores of neighbouring states.
  - A safety rule overrides the score: if the monthly shortfall is larger than the household's savings, the
    verdict is Not affordable.
- **Why:** "Stretch" is shorter and plainer on a phone screen than "Marginally Affordable". The cut-offs come
  from the data and were not chosen by hand.

### D5. Data ingestion: M-PESA PDF statements and manual entry; no CSV upload and no sandbox connection for users

- **Proposal (3.4.4):** PDF and CSV statements from major Kenyan banks and M-PESA (pdfplumber), CSV import, a
  sandbox API connection and manual entry.
- **Built:**
  - M-PESA PDF statements, including password-protected ones (`backend/mpesa.py`).
  - Manual entry.
  - Rough monthly estimates at setup, so the app works on the first day.
  - A live sandbox API connection exists in the Web Masters service. When it has no local copy, it logs in to the
    Wasaa staging API and downloads the sandbox dataset (`backend/app.py`, `_read_csv`).
- **Why:**
  - **Library:** pypdf replaced pdfplumber. pdfplumber took about 12 s per statement against 1.3–1.7 s for pypdf,
    and the hosting platform cuts requests at 30 s.
  - **M-PESA first:** most Kenyan household money moves through M-PESA, and each bank uses its own statement
    layout. Effort went into reading one format exactly. The reader:
    - checks every import against the statement's own totals and running balance, and refuses the import if they
      do not match;
    - avoids double counting by skipping repeated receipt numbers.
  - **Bank PDFs and CSV:** these were cut for time. The import endpoint accepts transactions in a format that a
    CSV reader could feed later.
- **Not built:** bank PDF statements, CSV upload, and a sandbox connection for household users.

### D6. Transaction categorisation: Kenyan directory and remembered user tags instead of a trained text classifier

- **Proposal (3.2.2):** keyword rules, plus a trained text classifier for ambiguous cases.
- **Built:**
  - **Kenyan business directory** (`backend/kenya_directory.py`): brands, plus descriptive words that Kenyan
    business names carry, such as BUTCHERY, CHEMIST and SALON.
  - **M-PESA's own transaction type:** sent, Pochi, Buy Goods, Paybill, airtime, charges, loan, savings, money in.
  - **Remembered payee tags:** a user tags a payee once and every payment to that payee follows. Single payments
    can also be corrected.
  - **Suggestions for unknown payees:** suggestions only, never automatic, for example "same amount early each
    month, rent?".
  - **Unsorted:** anything the system is not sure of stays "unsorted" and is spread in the household's own
    proportions.
- **Why:**
  - There is no labelled set of Kenyan M-PESA payee names to train a classifier on.
  - Most M-PESA lines are a person's name ("JOHN MWANGI"), which carries no information about the purpose. No
    classifier can tell rent from family support from the name alone, so only the user can.
  - A wrong guess is worse than "unsorted" because it moves the state (D1).
- **Measured on the developer's own statement:**
  - Before any tagging, 41–43% of money is sorted with certainty: by M-PESA's own type (charges, airtime, loans,
    savings) or by the directory.
  - After tagging the top 10 payees, 89% is sorted.
  - Three directory entries that came from this statement were removed, so the result is not tuned to one user.
- **Limitation:** sorting accuracy has not been measured against a hand-labelled set. This is planned with
  volunteer statements (D15).

### D7. Preprocessing: complete months instead of imputation

- **Proposal (3.2.2):** median imputation for missing numbers and mode imputation for missing categories.
- **Built:**
  - Only complete months are used.
  - Part-months at the edges of a statement are left out.
  - A category with no records counts as zero, not a missing value.
  - Months with no records fall back to the user's setup estimates.
- **Why:** in transaction data a missing category almost always means nothing was spent. Imputing a median would
  invent spending.

### D8. Security

| Proposal (3.4.1) | Built |
|---|---|
| bcrypt password hashes | Salted Werkzeug password hashes (scrypt, Werkzeug's default), a standard and comparable choice |
| JSON Web Tokens | Signed, timed tokens (itsdangerous, 30 days), checked on every request. They play the same role and have no signing-algorithm choice to misconfigure |
| Rate limiting | Built: registration limited per IP address; logins limited per IP address and failed logins per email |
| Input validation | Built: every endpoint validates input and returns plain 400 messages |
| Role-based access | Built for two roles. Admin accounts are named in an environment variable (`ADMIN_EMAILS`) and never in code |
| TLS | Provided by the hosting platforms (HTTPS on Render and Netlify) |
| Encryption at rest | The database host's storage encryption. There is no field-level encryption in the application |
| Account recovery | **Not built.** Planned as Google sign-in (R2) |

- **Added for privacy (Kenya Data Protection Act 2019):**
  - Uploaded statements are read in memory and never stored. The PDF and its password are discarded after
    reading.
  - A privacy notice (who, what, why, where, rights, how long) is shown at sign-up, and the user's consent is
    recorded with the notice version and time. Older accounts are asked once. Statements cannot be read without it.
  - Users can delete their whole account and all their data from Your household (`DELETE /me`).
  - The admin view masks users' emails and shows counts only.

### D9. Database design

- **Proposal (Table 3.x):** 10 tables, including `categories`, `financial_statements`, `ml_outputs`,
  `budget_recommendations`, and separate `obligations`, `debts` and `goals` tables.
- **Built:**
  - Tables: `users`, `profiles`, `income_sources`, `transactions`, `commitments`, `budgets`, `scenarios`,
    `money_in` and `statement_rules`.
  - `commitments` holds obligations, debts and goals as JSON.
  - `budgets` holds each month's budget.
  - `scenarios` holds each affordability check and its result.
- **Why:**
  - **No `financial_statements`:** statements are not stored (D8), so there is nothing to track.
  - **No `ml_outputs`:** results are computed on each request. The models answer in well under a second, so the
    screens always show figures that match the latest data.
  - **No `categories` table:** categories are a fixed list in code that the models were trained on.
  - **Commitments as JSON:** a user's obligations, debts and goals are always read and saved together, so one
    document is simpler.

### D10. Obligations, debts and goals

| Proposal (3.4.5) | Built |
|---|---|
| Obligations with frequency | Built: weekly, monthly, termly, semester and yearly, converted to monthly amounts |
| Debt payoff timeline, cost to the score | Built, and extended: an avalanche or snowball plan, the debt-free date, total interest, savings from extra payments, and a warning when a payment does not cover the interest |
| Goals with a required monthly amount | Built |
| Goal progress tracked automatically from transactions | **Partly built.** The user enters the amount saved. A statement purchase that matches a goal marks the goal done and takes the money out of savings |
| Alerts when a goal is at risk | **Not built** |
| Payment status per month, reminders before due dates | **Not built**. These need push notifications, which were cut for time |

### D11. Administrator

- **Proposal (3.4.2):** manage users, monitor performance, manage the synthetic dataset, trigger retraining, view
  logs.
- **Built:** a read-only admin screen showing:
  - service health;
  - a model register listing each deployed model, its metric and its data;
  - a masked user list;
  - counts.
- **Why:**
  - **Retraining and the dataset:** models are retrained by versioned scripts (`scripts/`, `data_generation/`)
    with a held-out check. They are then committed, so every deployed model can be reproduced. A retrain button on
    a free hosting instance would risk timeouts and putting an untested model live.
  - **Logs:** the hosting dashboard keeps them.
- **Not built:** user management (suspend or reset) from the app.

### D12. Feedback loop

- **Proposal (3.1):** user corrections continuously enrich the dataset and improve the shared models.
- **Built:**
  - Corrections are remembered per user (`statement_rules`), and that user's figures change immediately.
  - Corrections are not pooled to retrain the shared models.
- **Why:** pooling would mean using people's financial data for training without separate consent, and there are
  too few users for the pooled data to be worth it.

### D13. SHAP explanations

- **Proposal (3.5.7):** SHAP on the Random Forest score, shown to users.
- **Built:** exact Shapley values of the deployed score (D3), grouped into six parts a user can read (income,
  the latest month, the last 3 to 6 months, saving, loan repayments, household). "Why this score?" on the dashboard
  and on every "Can I afford it?" answer shows how many points each part adds or takes away against a typical
  household, and what a choice moves.
- **Changes from the proposal:**
  - The values explain the monotonic score model, because that model now produces the score (D3).
  - They are computed exactly over the six groups (64 combinations) instead of with the shap library, so the server
    needs no extra package.
- **Checks:** with every feature on its own, the values match the shap library's exact explainer to 3e-13 points,
  and the parts add up to the score exactly (experiments, 5 Nov).
- **What it found:**
  - The score looks only at the last 3 to 6 months: 9 overspent months followed by 3 calm ones score 100, the same
    as a calm year.
  - The synthetic labels have the same blind spot, so retraining cannot fix it (accuracy 0.728 → 0.735 with
    12-month features).
  - The app now shows a 12-month track record next to the score. A fragile year (3 or more months spending above
    income) turns "Affordable" into "Stretch".

### D14. Platforms

- **Proposal:** Flutter on Android and iOS.
- **Built:** one Flutter code base, so far run in the browser (Chrome) against a local backend.
- **Planned:** an Android build, an iOS build (on the developer's Mac with Xcode), and the hosted web version
  (Netlify), all against the hosted backend (Render).

### D15. Validation

| Proposal (3.2.4) | Built or planned |
|---|---|
| HMM accuracy, precision, recall and F1 against hand-labelled states | Accuracy, within-one accuracy and Stable/Critical mix-ups against the generator's states for the HMM, a fitted threshold rule and the Random Forest. **Planned:** add per-class precision, recall and F1 to the report |
| LSTM: train on 9 months, test on 3, RMSE and MAE | Rolling backtest, choosing on validation months and confirming on held-out months. MAE and WAPE, overall and per category |
| Random Forest: precision, recall and F1, plus ratings of relevance | State accuracy and score consistency (D3). The budget's held-out error per category (D3) |
| Volunteers' real statements under informed consent | One real statement so far, the developer's own (experiments, 4 Nov). **Planned:** 3–5 volunteers with written consent, a consent screen in the app, and a short rating questionnaire |

### D16. The hypothesis

- **Proposal (1.1):** the integrated system "can produce more accurate and actionable lifestyle affordability
  assessments than any existing personal finance application".
- **Problem:** this cannot be tested as written. The study has no access to other applications' outputs on the
  same households.
- **Tested instead:**
  1. Each model is compared with a simple baseline on held-out data: Random Forest against HMM and a threshold
     rule; forecast against the median; budget against one size for all.
  2. Volunteers rate whether the outputs match their real finances.

  The chapter on results reports both, with their limits.

### D17. Additions not in the proposal

- **Web Masters (U-CS 37) budget-forecast service:** the same backend also serves another group's application.
- **Savings balance:** savings are used in the safety rule and to say "your savings would cover the gap for N
  months".
- **One-off payments:** big rare payments, such as a plot or a phone, are kept out of usual spending.
- **Scenario presets:** moving house, a new baby, a purchase in instalments, a loan, a savings goal, an income
  change. "Apply" turns a checked scenario into a real commitment.
- **What to cut:** cuts that would break even or make a scenario comfortable.
- **Money in from statements:** who pays you, with income, mixed and own-account tags, so moving your own money is
  not counted as income.
- **Month-by-month timeline:** the financial state per month, scored only with data up to that month.

### D18. Process

The proposal planned eight fixed sprints. Work was instead tracked as GitHub issues and pull requests (#1–#86),
each merged after tests passed. `CHANGELOG.md` records them. It is the same iterative approach with smaller
increments.

---

## Part B: Requirements traceability

| ID | Requirement (proposal section) | Status | Where in the system | Evidence |
|---|---|---|---|---|
| R1 | Register and log in (3.4.1) | Built | `/auth/register`, `/auth/login`, `auth_screen.dart` | `tests/test_store.py` |
| R2 | Account recovery (3.4.1) | Planned | Google sign-in | — |
| R3 | Password hashing, session tokens, rate limiting, validation (3.4.1) | Changed (D8) | `backend/store.py` | `tests/test_store.py` |
| R4 | Upload PDF statements (3.4.4) | Changed (D5): M-PESA only | `/me/statements/preview`, `/import`, `statement_screen.dart` | `tests/test_mpesa.py`, `tests/test_store.py`; experiments, 4 Nov |
| R5 | Upload CSV statements (3.4.4) | Not built (D5) | — | — |
| R6 | Sandbox API connection (3.4.4) | Partly built (D5) | Web Masters service, `_read_csv` | — |
| R7 | Manual entry for cash (3.4.4) | Built | `/me/transactions`, `spending_screen.dart` | `tests/test_store.py` |
| R8 | Cleaning: duplicates and malformed fields (3.2.2) | Built | Receipt numbers skip repeats; checks against statement totals and balances | `tests/test_mpesa.py` |
| R9 | Categorisation, rules plus classifier (3.2.2) | Changed (D6) | `kenya_directory.py`, payee tags, `/me/payees` | Experiments, 4 Nov (41–43% → 89%) |
| R10 | Feature engineering (3.2.2) | Built | `affordability.build_features`, matches `07_feature_engineering.py` to 5.8e-11 | Experiments, 22 Oct |
| R11 | Financial state detection (3.2.3) | Changed (D1): Random Forest | `affordability._state` | 0.799 against HMM 0.531; experiments, 22 Oct |
| R12 | Expenditure forecast 1–3 months (3.2.3) | Changed (D2): boosted tree, 3 months with ranges | `outlook_for_user`, dashboard | Beats the median at 1, 2 and 3 months; experiments, 4–5 Nov |
| R13 | Personalised budget allocation (3.2.3) | Built (Random Forest, half and half) | `backend/budget.py`, `/me/budget-plan`, `budget_screen.dart` | KES 7,021 against 7,295; experiments, 28 Oct |
| R14 | 0–100 affordability score (3.2.3) | Changed (D3): monotonic gradient boosting | `affordability.assess` | 100% consistent; experiments, 22 Oct |
| R15 | Scenario simulation with verdict (3.4.6) | Built; labels changed (D4) | `/me/afford`, `/me/scenarios`, `afford_screen.dart` | `tests/test_affordability.py` |
| R16 | SHAP explanations (3.5.7) | Changed (D13): exact grouped Shapley values | `affordability.explain`, `/me/explain`, `why_score_sheet.dart` | Matches shap to 3e-13; experiments, 5 Nov |
| R17 | Obligations with frequency (3.4.5) | Built | `commitments.py`, `commitments_screen.dart` | `tests/test_commitments.py` |
| R18 | Debts with a payoff timeline (3.4.5) | Built, extended | `commitments.simulate_debts` | `tests/test_commitments.py` |
| R19 | Goals with the monthly amount needed (3.4.5) | Built | `commitments.evaluate` | `tests/test_commitments.py` |
| R20 | Automatic goal progress and at-risk alerts (3.4.5) | Partly built (D10) | `_complete_goals` | `tests/test_store.py` |
| R21 | Obligation payment status and reminders (3.4.5) | Not built (D10) | — | — |
| R22 | Lifestyle tracking over time (3.4.6) | Partly built | Month-by-month state timeline, spending by month, debt share of income in reasons | `tests/test_store.py` |
| R23 | Dashboard (3.4.3) | Built | `/me/overview`, `dashboard_screen.dart` | — |
| R24 | Profile and household settings (3.4.3) | Built; notification settings not built | `/me/profile`, `profile_screen.dart` | `tests/test_store.py` |
| R25 | Admin: monitor performance (3.4.2) | Built | `/admin/overview`, `admin_screen.dart` | `tests/test_store.py` |
| R26 | Admin: manage users, dataset, retraining, logs (3.4.2) | Changed (D11) | Retraining by scripts; logs on the hosting dashboard | — |
| R27 | Feedback loop (3.1) | Changed (D12): per user | `statement_rules` | — |
| R28 | Synthetic dataset for a cold start (1.5) | Built | KIHBS-informed, 300 households × 12 months, 2025 KES; plus setup estimates | Experiments E2–E4 |
| R29 | Android and iOS app (3.4) | Planned (D14) | Flutter | — |
| R30 | Cloud backend and PostgreSQL (3.3.6) | Built (Neon); hosting update planned | Render, Neon | — |
| R31 | Real-user validation with consent (3.2.4) | Partly built: 1 statement; volunteers planned (D15) | — | Experiments, 4 Nov |
| R32 | Plain-language outputs (3.3.1) | Built | Reasons, notes and info dialogs on every screen | — |
| R33 | Handles malformed input without failure (3.3.1) | Built | Plain 400 errors; a statement that fails the checks is refused | `tests/` |

Counts, for the report's summary table: 33 requirements, of which:

- **Built:** 16 (including R18, built and extended).
- **Changed:** 9.
- **Partly built:** 4.
- **Not built:** 2.
- **Planned:** 2.

R15 (labels changed) carries a note in its status.

---

## Part C: Before the defence (23 Nov)

1. ~~SHAP on the score model (R16) and a review of how generous the score is~~ (done 5 Nov, D13).
2. ~~A three-month forecast with ranges (R12)~~ (done 5 Nov).
3. ~~A consent screen and a delete-my-account button (R31, D8)~~ (done 5 Nov).
4. Google sign-in (R2).
5. Deployment to Render and Netlify, then Android and iOS builds (R29, R30).
6. 3–5 volunteers: consent form, statements, a categorisation-accuracy count, and a rating questionnaire (R31, D6).
7. Add per-class precision, recall and F1 for the state models to the report (D15).
