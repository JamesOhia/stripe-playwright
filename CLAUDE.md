# CLAUDE.md — Architectural rules for this Playwright suite

This file gives Claude Code (and any future contributor) the rules of the road for this project. **Read it before adding or modifying tests.**

---

## Project purpose

End-to-end automated tests for a realistic Stripe Sandbox payment processing workflow. The suite must run on every push/PR in GitHub Actions and produce Allure reports (downloadable artifact + GitHub Pages).

The assessment requires coverage of:
1. PaymentIntent creation
2. Payment confirmation with a test card
3. Payment status retrieval
4. Webhook notification verification (simulated)
5. Refund processing
6. **GUI validation** — open Stripe Dashboard sandbox, log in, verify payment appears in list with correct amount and status, and refund is visible.

---

## Stack

- **Playwright with JavaScript** (assessment requirement — TypeScript is not allowed)
- **JSDoc + `@ts-check`** to enforce strict typing in pure JS (via `jsconfig.json` with `checkJs: true` and `strict: true`). Every public function, class method, and exported helper must carry full JSDoc types.
- **Allure** for reporting (`allure-playwright` + `allure-commandline`)
- **dotenv** for local env, GitHub Secrets in CI
- **Stripe `/v1/events` polling** for webhook verification — no Stripe CLI, no public URL

---

## Folder layout — do not deviate

```
.github/workflows/    # GitHub Actions
src/api/              # API clients & verifiers
src/pages/            # Page Object Model classes (extend BasePage)
src/fixtures/         # Playwright fixtures extending `test`
src/utils/            # env loader, JSON data loader, logger
data/                 # JSON test data (cards, amounts, customers)
tests/api/            # API-only specs
tests/ui/             # UI-only specs (use storage state)
tests/e2e/            # Full journeys (API + UI)
tests/auth.setup.js   # Dashboard login → storageState (runs once)
auth/                 # Persisted storage state (gitignored)
```

If a new file doesn't fit, ask first; do not invent new top-level folders.

---

## Locator strategy — strict rules

**Use, in this preference order:**

1. `page.getByRole('button', { name: 'Submit' })`
2. `page.getByLabel('Email address')`
3. `page.getByPlaceholder('Search')`
4. `page.getByTestId('payment-row')` (only when developers have added test IDs — Stripe Dashboard has none)
5. `page.getByText('Payments', { exact: true })` (only as a last resort)

**Never use:**

- Raw CSS selectors (`page.locator('.x-12abc')`)
- XPath
- `nth-child` / `nth-of-type`
- Sibling combinators (`+`, `~`)

If a Stripe element has no accessible role/label, document why in a code comment and prefer a deep-link navigation over clicking through fragile DOM.

---

## Auto-waiting & anti-flakiness

**Mandatory:**

- Use `expect(locator).toBeVisible()`, `.toHaveText()`, `.toHaveURL()` — these auto-wait.
- Use `page.waitForURL(/pattern/)` for navigation.
- Use the `WebhookVerifier` class for "wait until event X happens" — never `waitForTimeout`.

**Forbidden:**

- `page.waitForTimeout(...)` — there is no acceptable use case in this codebase.
- `setTimeout` outside of the `WebhookVerifier` polling loop.
- `try/catch` to swallow assertion failures (let them fail loudly).

---

## Page Object rules

Every Page Object extends `BasePage` and follows this pattern:

```js
// @ts-check
import { expect } from '@playwright/test';
import { BasePage } from './BasePage.js';
import { NextPage } from './NextPage.js';

export class SomePage extends BasePage {
  /** @param {import('@playwright/test').Page} page */
  constructor(page) {
    super(page, 'SomePage');
    // Locators as instance properties (named after the user-visible thing)
    this.submitButton = page.getByRole('button', { name: 'Submit' });
  }

  /**
   * @param {SomeInput} input
   * @returns {Promise<NextPage>}
   */
  async submit(input) {
    this.logger.info(`Submitting ${input.id}`);
    await this.submitButton.click();
    return new NextPage(this.page);  // enables chaining to next page object
  }
}
```

**Rules:**

- One Page Object per logical page or major panel.
- Locators live in the constructor as named instance properties.
- Public methods are **verbs in the user's vocabulary** (`loginWith`, `openPaymentById`, `refund`) — not click-by-click instructions.
- Return either `this` (for fluent chaining on the same page) or the next Page Object (for navigation flows).
- Assertions inside Page Objects are allowed but only when they are **invariants** of being on that page (e.g. `assertLoaded()`). Test-specific assertions belong in the spec.
- No business logic in Page Objects — they wrap the UI only.

---

## API client rules

`src/api/StripeApiClient.js` is the single entry point for all Stripe REST calls.

- Use Playwright's `request.newContext()` (not `fetch` or the `stripe` npm package) — it gives us tracing, consistent timeouts, and built-in retry on network errors.
- Every method returns a typed `StripeResponse { status, body, headers }` so specs can assert on all three.
- Form-encode bodies using the internal `_toFormParams` helper (Stripe expects `application/x-www-form-urlencoded` with bracket notation for nested objects).
- Always dispose the context in a fixture teardown — never leak request contexts.

If a new Stripe endpoint is needed:

1. Add a JSDoc-typed method on `StripeApiClient`.
2. Reuse `_post` / `_get` — don't bypass them.
3. Add at least one happy-path spec under `tests/api/`.

---

## Test data rules

- **All test data lives in `/data/*.json`.** No hardcoded amounts, currencies, card numbers, emails, or metadata inside test files or page objects.
- Load via the typed helpers from `src/utils/data-loader.js`:
  ```js
  import { loadTestCards, loadTestAmounts } from '../../src/utils/data-loader.js';
  const cards = loadTestCards();
  const { amount, currency, display } = loadTestAmounts().medium;
  ```
- If a test needs new data, add it to the appropriate JSON file with a meaningful key.

---

## Spec writing style — BDD without Cucumber

Every spec reads as a user story. Use this structure:

```js
test.describe('Feature or capability under test', () => {
  test.describe('Given <precondition>', () => {
    test('When <action>, Then <expected outcome>', async ({ stripeApi }) => {
      // Arrange — minimal setup beyond what fixtures already provide
      // Act    — single user-meaningful action
      // Assert — web-first expects
    });
  });
});
```

**Rules:**

- `describe` blocks express Given/When/Then narrative — they are not technical groupings.
- One `test` = one user-meaningful behaviour. Don't chain multiple unrelated assertions.
- Spec files contain **no locators**, **no JSON paths**, and **no `fetch()` calls**. All of that goes through page objects and the API client.

---

## Fixtures

Import `test` and `expect` from `src/fixtures/playwright-fixtures.js` — **never** from `@playwright/test` directly inside specs. The custom fixtures provide:

- `stripeApi` — `StripeApiClient` instance (auto-disposed)
- `webhookVerifier` — `WebhookVerifier` instance
- `loginPage`, `dashboardPage`, `paymentsPage` — pre-instantiated page objects

If a new shared resource is needed (e.g. a Stripe Customer with seeded data), add it as a fixture.

---

## Environment & secrets

`src/utils/env.js` is the single place that reads `process.env`. It validates every required variable at startup and fails fast with a clear error message.

**Never** read `process.env` directly inside specs or page objects.

CI provides values via GitHub Secrets (see README). Local development uses `.env` (gitignored).

---

## Reporting

- Allure is the canonical reporter (`allure-playwright`).
- Don't add `console.log` in production code paths — use the `Logger` class for structured logs.
- Add `await test.step('description', async () => { ... })` blocks around multi-action operations so they appear as collapsible steps in Allure.
- Failures auto-capture trace, screenshot, and video (configured in `playwright.config.js`).

---

## CI rules

`.github/workflows/playwright.yml` is the source of truth.

- Tests run on push and PR.
- `continue-on-error: true` on the test step so the Allure report always uploads (even on failure).
- Allure history is cached between runs so trend data accumulates.
- The Pages deployment only runs on `main` to avoid noisy PR deploys.

---

## When extending the suite

If you're adding a new test capability:

1. Check `/data/*.json` first — can you reuse existing test data?
2. Check `StripeApiClient` — does the endpoint already have a method?
3. If you need a new Page Object, extend `BasePage` and follow the pattern above.
4. Write the spec as Given/When/Then.
5. Run `npm run typecheck` before committing — it must pass.
6. Run `npm test` locally and view `npm run report` to verify.

---

## What NOT to do (common pitfalls)

- ❌ `await page.waitForTimeout(2000)` — use `expect(...).toBeVisible()` or `WebhookVerifier`
- ❌ `page.locator('div.x-12abc > span:nth-child(2)')` — use `getByRole` / `getByLabel`
- ❌ Hardcoding `4242424242424242` inside a test — load from `test-cards.json`
- ❌ `try { ... } catch { /* ignore */ }` around assertions — let them fail
- ❌ Adding `stripe` npm package — we use raw REST via Playwright's request
- ❌ Calling Stripe from inside a Page Object — page objects wrap UI only
- ❌ Adding TypeScript files — assessment says JavaScript only
- ❌ Skipping JSDoc on a new public method — the strict checker will fail the build
