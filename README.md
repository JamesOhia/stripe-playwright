# Stripe Payment E2E — Playwright Automation Suite

End-to-end automated tests for a realistic Stripe Sandbox payment processing workflow, built with Playwright + JavaScript, runnable in GitHub Actions on every push or PR, with Allure reports published to GitHub Pages and uploaded as downloadable artifacts.


## What this suite covers t

| Layer | Scope |
|-------|-------|
| **API** | PaymentIntent create / confirm / retrieve / list / cancel, refunds (full + partial), customers, webhook events via `/v1/events` polling. |
| **UI** | Stripe Dashboard login (with persisted storage state), payment list verification, payment detail page (amount, status, refund visibility). |
| **E2E** | Full journey: API creates and confirms a payment → webhook verified → refund issued → dashboard reflects the final state. |

The workflow covers happy paths (success card), card declines (generic, insufficient funds, expired, incorrect CVC), and 3DS-required cards. Webhook delivery is verified by polling Stripe's `/v1/events` — no public URL or Stripe CLI needed in CI.


## Architecture & patterns

```
stripe-payment-e2e/
├── .github/workflows/playwright.yml   # CI pipeline (push/PR), Allure → Pages + artifact
├── .auth/                             # Persisted Stripe Dashboard storage state (gitignored)
├── data/                              # JSON test data — single source of truth
│   ├── test-cards.json
│   ├── test-amounts.json
│   └── test-customers.json
├── src/
│   ├── api/
│   │   ├── StripeApiClient.js         # Thin, typed client over the Stripe REST API
│   │   └── WebhookVerifier.js         # Polls /v1/events as deterministic webhook proxy
│   ├── pages/                         # Page Object Model
│   │   ├── BasePage.js
│   │   ├── LoginPage.js
│   │   ├── DashboardPage.js
│   │   ├── PaymentsPage.js
│   │   └── PaymentDetailPage.js
│   ├── fixtures/playwright-fixtures.js  # Extended `test` with API + Page Object fixtures
│   └── utils/                          # env loader, JSON data loader, logger
├── tests/
│   ├── auth.setup.js                  # One-time dashboard login → storageState
│   ├── api/                           # API-only specs (no browser)
│   ├── ui/                            # UI-only specs (storage state reused)
│   └── e2e/                           # Full journey: API + UI assertions
├── playwright.config.js               # Projects: setup → api → ui → e2e
├── jsconfig.json                      # `checkJs: true`, `strict: true` (JSDoc enforced)
└── package.json
```

**Design principles followed throughout:**

- **Page Object Model.** Tests speak in user verbs (`paymentsPage.openPaymentById(id)`), page classes own the "how". Page classes extend `BasePage` and return either `this` or the next Page Object so method chaining works.
- **BDD-style spec structure.** Every `describe` block reads "Given X, When Y, Then Z" — tests are user stories, not step-by-step click logs.
- **JSON test data.** All amounts, cards, and customers live in `/data/*.json` and are loaded via `data-loader.js`. Nothing is hardcoded inside test actions or page methods.
- **JSDoc + `@ts-check` for strict typing in pure JavaScript.** Every public method has typed parameters and return types; `jsconfig.json` enforces `strict: true` and `checkJs: true`. VS Code surfaces type errors inline as if it were TypeScript.
- **User-first locators only.** `getByRole`, `getByLabel`, `getByPlaceholder`, `getByText`. No brittle CSS selectors, no XPath.
- **Web-first assertions.** `expect(locator).toBeVisible()`, `.toHaveText()`, `.toHaveURL()` — all auto-waiting.
- **No `waitForTimeout`.** State-based waits only. The webhook verifier polls with a deadline, never sleeps blindly.
- **Stripe Events API as webhook verification.** Cleaner than `stripe-cli` forwarding for CI: deterministic, no public URL, no extra process.
- **base64 storage for login.** `save-auth.js` saves a base64 token which makes it easily for the authentication to be successfully but that token can expire in a week so after a week, an update on the token needs to be done and saved in the secret variable called `STRIPE_AUTH_STATE`
- **Storage state for dashboard login.** A single `auth.setup.js` logs in once and persists the session; UI and E2E projects reuse it via `dependencies: ['setup']`.


## Prerequisites

- Node.js 20+
- A Stripe **test mode** account
- Stripe API keys (test mode): publishable + secret
- Stripe Dashboard login credentials (email + password) — **two-step authentication must be DISABLED on this account for automation reliability**


## Local setup

```bash
# 1. Install dependencies
npm install

# 2. Install Playwright browsers
npx playwright install --with-deps chromium

# 3. Configure environment
cp .env.example .env
# Edit .env and fill in your Stripe sandbox keys + dashboard credentials

# 4. Run all tests
npm test

# 5. Run a specific project
npm run test:api    # API-only (fastest)
npm run test:ui     # UI-only (requires auth setup)
npm run test:e2e    # Full E2E journeys

# 6. Generate and open Allure report locally
npm run report
```


## GitHub Actions setup

The workflow at `.github/workflows/playwright.yml` runs on every push and PR.


### Required GitHub Secrets

Configure these under **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Where to find |
|--------|---------------|
| `STRIPE_SECRET_KEY` | Stripe Dashboard → Developers → API keys (test mode) |
| `STRIPE_PUBLISHABLE_KEY` | Same page |
| `STRIPE_DASHBOARD_EMAIL` | Email used to sign in to the test Stripe account |
| `STRIPE_DASHBOARD_PASSWORD` | Password for the same account |
| `STRIPE_AUTH_STATE` | Generated locally by running `npm run save-auth` (see below) |

### Capturing the dashboard session (`STRIPE_AUTH_STATE`)

Stripe's anti-bot protection blocks automated logins in CI. The workaround is a one-time manual login that captures and reuses session cookies:

```bash
npm run save-auth
# A real Chrome window opens — log in manually and press ENTER.
# The script prints a base64 string. Paste it as STRIPE_AUTH_STATE.
```

If you already captured a session but got a "Value is too large" error from GitHub (happens when other browser tabs were open), run:

```bash
npm run trim-auth
# Filters the saved file to Stripe cookies only and prints a smaller base64.
```

Sessions expire after ~30 days. Re-run `npm run save-auth` when `auth.setup.js` reports "session expired".


### Enabling GitHub Pages

1. Push your code to a `main` branch on GitHub.
2. Go to **Settings → Pages → Source** and select **GitHub Actions**.
3. Push or open a PR — the workflow will publish the Allure report to the Pages URL on every successful `main` build.

The report is also uploaded as a downloadable workflow artifact (`allure-report`) regardless of branch.


## Assumptions

1. The test Stripe account uses **test mode** (sandbox) — no real funds move.
2. Two-step authentication is disabled on the test account. Also due to Stripe Captcha anti-bot system. The login is ran using your real browser and not playwright browser inorder to bypass the captcha and anti-bot system from strip 
3. Webhook verification uses Stripe's `/v1/events` API rather than a public HTTPS endpoint or `stripe-cli` forwarding. This is the cleanest and most reliable approach for CI environments and produces equivalent verification fidelity — every event Stripe would have delivered is recorded in `/v1/events`.
4. The Stripe Dashboard UI is heavyweight and its internal selectors change frequently. The page objects favour role/label/placeholder locators and direct deep-links (`/test/payments/:id`) over fragile row clicks.
5. PaymentMethod creation uses Stripe's published test tokens (`tok_visa`, `tok_mastercard`, etc.) rather than raw card numbers. This works on all Stripe test accounts without any account-level enablement.


## Reports

- **Local HTML:** `npm run report` opens an interactive Allure HTML report.
- **CI artifact:** Every workflow run uploads `allure-report` as a downloadable artifact.
- **GitHub Pages:** `main` branch builds publish the same report to `https://<your-username>.github.io/<repo-name>/`.

Allure preserves history across runs (cached on the runner), so trend data accumulates over time.