---
name: testing
description: Principles and concrete rules for writing tests in this repo. Use whenever you're writing, reviewing, or fixing a test — unit, integration, or E2E. Distils Kent C. Dodds' "How to know what to test" and "Testing implementation details" into actionable rules.
---

# Testing principles — how to write tests that actually tell you the product is working

Adapted from Kent C. Dodds' [How to know what to test](https://kentcdodds.com/blog/how-to-know-what-to-test) and [Testing implementation details](https://kentcdodds.com/blog/testing-implementation-details).

## The core rule

> The more your tests resemble the way your software is used, the more confidence they can give you.

Every decision below follows from this. If you can't explain a test as "a real user does X, and then observes Y", the test is wrong.

## Deciding WHAT to test

**Think in use cases, not code coverage.** 100% line coverage with no use-case coverage is a lie — you can hit every branch without verifying a single user outcome. Before writing or reviewing a test, ask:

1. **What would be worst to break?** Rank work by business impact × blast radius. Payments, auth, submission, "publish"-style transitions: test these first and thoroughly. Obscure admin toggles: thin happy-path is enough.
2. **What use cases does this code support?** When looking at uncovered lines, ask this — not "what if/else paths exist?"
3. **Is this covered by an E2E that exercises the real user path?** If yes, you usually don't need to unit-test the same behaviour in every layer. If no, one happy-path E2E usually buys more confidence than five unit tests.

**Default priority when a surface is uncovered:**
1. One E2E for the happy path of the critical user journey.
2. Integration tests for edge cases that E2E can't cheaply reach (auth failures, empty states, error branches).
3. Unit tests for pure functions with non-obvious logic.

## Testing behaviour, not implementation details

**Definition.** Implementation details are things users of your code never see, use, or know about. For a React component, the two "users" are end-users (who click buttons and read screens) and other developers (who pass props). Anything else — internal state names, private method names, class names, CSS classes, `id` attributes, render-tree structure — is an implementation detail.

**Why it matters.** Implementation-coupled tests cause two orthogonal failures:

- **False negatives** — you rename an internal variable, the test breaks, nothing about user behaviour has changed. You stop trusting the test.
- **False positives** — you remove an `onClick` handler binding, the test that pokes state directly still passes, the bug ships. You stop trusting the test for the other reason.

**Red flags to grep for when reviewing a test:**

- `.state()`, `.instance()`, `.find('ComponentName')` — you're reading React internals.
- `wrapper.setProps({...})` with internal props the user wouldn't pass.
- CSS class assertions (`.text-error-400`, `.border-l-2`) — couples to Tailwind, not to meaning.
- `#id` selectors where a `<label>` exists — use `getByLabel`.
- `input[placeholder*="..."]` where a label exists — same.
- `[data-value="..."]` where `getByRole('option', { name: ... })` would work.
- Monster selectors (`tr, [role="row"], li, article`) trying to find "some ancestor row" — usually means you need to scope to a real landmark with a real accessible name.

## Concrete rules

Find the repo-specific paths and commands (test directories, config files,
seed users, fixture ids) in CLAUDE.md before applying the rules below — the
examples here are illustrative, not this repo's actual commands. If
CLAUDE.md doesn't say, read `package.json` scripts and the test config files
(`playwright.config.*`, `vitest.config.*`, and similar) directly.

### Playwright / E2E

**Selector preference, highest to lowest:**

1. `getByRole('heading', { name: ... })` / `getByRole('button', { name: ... })` — headings, buttons, links, tabs, dialogs, columnheaders, menuitems.
2. `getByLabel(/name/i)` — form inputs. Pair with `.toHaveValue('X')` not `.toBeVisible()`.
3. `getByPlaceholder(/.../)` — inputs without a visible label.
4. `getByText(...)` — **only** when the text IS the behaviour (e.g. an item's name appearing in a list after creation).
5. `data-testid` — last resort, for non-semantic elements (badges, decorative cards) with no accessible role.

**Gotcha — combobox accessible name.** A custom `<button>` associated to a `<label htmlFor>` has its accessible name come from the label, NOT from its rendered text. So a combobox whose button shows "Widget" is still `getByRole('button', { name: /category/i })`, not `name: /widget/i`. Assert the value with `.toContainText(...)`.

**Anti-patterns and fixes:**

| Anti-pattern | Fix | Why |
|---|---|---|
| `input[value="X"]` | `getByLabel(/name/i)` + `.toHaveValue('X')` | Breaks if `<input>` becomes `<textarea>`, or if the seed value changes |
| `#element-id` when a label exists | `container.getByLabel(/label/i)` scoped to parent dialog/section | IDs are implementation details; labels are what the user sees |
| `.first()` sprinkled everywhere | Remove if match should be unique; scope to a container if truly ambiguous | `.first()` suppresses Playwright's "multiple matches" error and hides real bugs |
| `waitForTimeout(N)` | `expect(locator).toHaveText(...)`, `toBeEnabled()`, `toHaveValue(...)` | Hardcoded waits are the #1 source of flake. Playwright auto-retries assertions |
| `waitForLoadState('networkidle')` | `waitForLoadState('domcontentloaded')` or an `expect(...).toBeVisible()` | `networkidle` is unreliable for SPAs with background polling/analytics |
| `waitForLoadState('load')` after a client-side nav | `waitForURL(matcher)` or `expect(headingThatMarksTheNewRoute).toBeVisible()` | `load` event already fired on initial page load; does NOT re-emit on client-side navigation. The call is a no-op masking its own absence |
| Loose regex (`/failed\|disqualified\|rejected/i`) | Tighten to the actual expected text, or scope to a container | Broad alternation matches unrelated copy elsewhere on the page |

**Scoping to a container instead of `.first()`:**

```typescript
// Bad — "completed" could match a heading, another row, or helper text
await expect(page.getByText(/completed/i).first()).toBeVisible()

// Good — scoped to the row containing the specific item
const row = page.locator('tr, [role="row"], li, article').filter({
  hasText: 'Widget Q3 Report',
})
await expect(row.getByText(/completed/i)).toBeVisible()
```

Same inside dialogs:

```typescript
const dialog = page.getByRole('dialog')
await dialog.getByLabel(/reason/i).fill('Does not meet criteria')
await dialog.getByRole('button', { name: /confirm/i }).click()
```

**Waits that actually work (in order of preference):**

1. Do nothing — the next `expect(...)` auto-waits.
2. `await page.waitForURL(matcher, { timeout: ... })` after a click that should navigate.
3. `await expect(knownStableElement).toBeVisible({ timeout: ... })` — the new route has mounted.
4. Retry helpers in the repo's E2E helpers file, if it has one — typically named something like `clickAndWaitForDialog` or `clickAndWaitFor`, wrapping `expect().toPass()`-style retries, which are hydration-safe.
5. **Never** `waitForTimeout`. Not for "just in case", not for "it's flaky in CI", not for any reason.

**Form-library inputs**: if the project's form library needs a special fill helper — for example, some libraries don't register a plain `.fill()` as a change on an already-populated field — use the repo's helper instead of a raw `.fill()`. Check CLAUDE.md or the E2E helpers file for one.

**Numeric inputs that format on blur** (e.g. an input renders `10000` as `"10,000"`): assert via a magnitude-aware helper if the repo has one — it should poll the raw value and strip formatting before comparing, so the test cares about magnitude (user intent) rather than presentation. A literal `toHaveValue('10000')` will spuriously fail the moment display formatting changes. Write one if the repo doesn't have it yet.

**Running tests:**

- Use the command CLAUDE.md documents for the E2E suite — often something like `npx playwright test --project=<name>` if the repo splits E2E into named projects.
- Against a live dev server (agents): check CLAUDE.md for the pattern; a common shape is `BASE_URL=http://localhost:<port> npx playwright test <path> --workers=1 --reporter=list`.
- See CLAUDE.md for seeded users and fixture ids the E2E suite relies on.

### Unit tests

- Use whatever flags CLAUDE.md specifies for a unit-only run — some test runners bundle an extra project (e.g. a component-story suite) into the default invocation, which you don't want to trigger by accident.
- Test pure functions, service-layer logic against a real test database (as an integration test, not mocked) for anything beyond the smallest pure-logic slice, and conditional rule evaluators. Don't mock the database layer past that smallest slice — mocked persistence tests drift from real schema and behaviour, and can hide a broken migration.
- For React Testing Library: reach for `screen.getByRole` / `screen.getByLabelText` first. `container.querySelector` is usually a smell.

## Deciding whether to fix a test or the code

Treat a failing test as "the contract said X, the code does Y" — don't short-circuit the diagnosis by loosening the assertion.

- If the assertion describes a real user outcome and the code doesn't produce it → **fix the code.**
- If the assertion couples to an implementation detail that a legitimate refactor changed → **fix the assertion** (and take the opportunity to decouple it).
- If the assertion is flaky on a timing hack → **fix the wait**, never bump the timeout. `waitForTimeout(5000)` today is `waitForTimeout(30000)` in a month.

When unclear, ASK the user before changing test or code.

## Checklist before opening a PR with tests

- [ ] Each test's description can be read as a user action + observable outcome ("admin fills the dialog → item appears in list as DRAFT").
- [ ] Selectors are role/label-first. No `#id`, no Tailwind classes, no placeholders where a label would work.
- [ ] No `waitForTimeout`, no `waitForLoadState('networkidle')`, no `waitForLoadState('load')` after client-side nav.
- [ ] No `.first()` unless the multi-match is genuinely ambiguous and documented.
- [ ] Assertions verify behaviour (`.toHaveValue`, `.toHaveText`, `.toBeEnabled`), not presence (`.toBeVisible`) where stronger checks exist.
- [ ] If you added an E2E test, it's in the suite/project that already covers the feature, per CLAUDE.md's test-project split if it has one — not a new sibling directory.
- [ ] Use the repo's test factories if it has them; clean up rows you create.
- [ ] If you touched seed or fixture data, you reseeded locally (per CLAUDE.md) and confirmed the affected suite still runs green.
