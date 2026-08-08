# Glass Goblin shop — operator runbook

> Drafted by Claude (Opus 4.8) as a Phase 2 scaffold — review and adjust before relying on it.
> Lives in a dot-folder (`.docs/`), so Jekyll does **not** publish it. Risk tags (C/H/M/L) map to
> the security review folded into `.plans/ecommerce-integration-v1.md`.

## How the shop works (read first)

- Static Jekyll site, **no backend**. Each product is `_products/<sku>.md` and renders at `/shop/<sku>`.
- **Charge authority lives on Stripe/PayPal, never on the site.** The front matter (`price`,
  `status`, `quantity`) is **cosmetic** — it only changes what the page shows and enforces nothing.
  The real controls are the Stripe link settings, the PayPal button type, HTTPS/domain integrity,
  and your manual checks.
- Buttons render automatically: an **available** item shows Stripe (if `stripe_url` set) + PayPal
  (if `paypal_url` set) + the bank-transfer invoice enquiry (always). A **sold** item shows no buttons.

## Which providers per item (policy, decided 2026-08-02)

- **One-off items (`gg-NNNN`, qty 1): Stripe only** — set `stripe_url`, leave `paypal_url` blank.
  A unique unit listed on two independent checkouts can be bought on *both* before either
  self-closes (cross-provider oversell); one provider per one-off removes that risk entirely, and
  Stripe is the cheaper fee + has the cleaner deactivation API.
- **Repeatable lines (beads, qty >1): Stripe + PayPal both fine** — oversell here is soft
  (backorder / remake), so buyer choice wins.
- Known exception: **`gg-0001` is intentionally on PayPal** as a validated demo of the one-off
  PayPal path; switch it to Stripe-only at real go-live.

## List a new item

1. Add photos to `assets/products/` as `<sku>-1.jpg`, `<sku>-2.jpg`, …
2. Create `_products/<sku>.md` (copy an existing one). Set `title`, `price` (GBP), `status: available`,
   `quantity`, `category`, `tags`, `condition`/`details`, and the description body.
3. Create the payment links (below) and paste `stripe_url` / `paypal_url`.
4. Preview with `bundle exec jekyll serve`; check the product page and the shop card/filters.
5. Commit + push.

## Stripe Payment Link (per item)

- In the Stripe dashboard: create a **Product + Price** in **GBP** (M2), then a **Payment Link** for it.
- **Enable shipping-address collection**, and **bind postage to the charge** — bundle it into the
  price or add a Stripe **shipping rate**. Never collect postage out-of-band (M3).
- **One-off items (`quantity: 1`):**
  - Limit the link to **1 use** so it can't be bought twice.
  - **Adjustable quantity OFF, fixed quantity = 1** — the 1-use cap limits checkouts, not units per
    checkout (H2).
- **Repeatable lines (`quantity > 1`, e.g. beads):**
  - Set the link's **total-uses cap ≈ current stock** as a crude oversell guard.
  - Beads are priced *per bead*, so buyers pick a quantity in checkout — turn **adjustable quantity
    ON** (max = stock). Note this makes "total-uses = stock" imperfect (one checkout can take many
    beads), so treat it as a backstop, not a real inventory count.
  - ⚠️ **No automatic stock decrement.** When stock changes, update `quantity` in the `.md` **and**
    re-cap the link. Skip this and qty>1 lines are not protected against oversell (H3).
- Paste the **public Payment Link URL** into `stripe_url` (safe to commit — it's public).
- ❌ **Never commit the Stripe secret key** — not in the repo, front matter, or client JS. Only the
  public Payment Link URL is committed (L2). (The future bulk-listing script reads the secret from
  an environment variable.)

## PayPal button (repeatable lines only — see provider policy above)

- Only for repeatable lines (qty >1). One-offs are Stripe-only; do not create a PayPal button for them.
- Create a **server-side hosted button** (button ID references a price stored at PayPal).
- Enable **inventory tracking with over-sell OFF** so the button self-closes at zero stock and
  redirects to its `sold_out_url` (point that at your shop, not paypal.com).
- ❌ Do **not** use a legacy amount-in-form button or a PayPal.me link as a buy button — both let the
  buyer set their own amount (C1).
- Paste into `paypal_url`.

## Bank-transfer invoice (Monzo)

- The "Pay by bank transfer — request an invoice" button opens a prefilled email to
  hello@glassgoblin.co.uk (title + SKU); it shows on every available item.
- The prefilled subject/body is **buyer-editable**. Always issue the Monzo invoice from **your own
  catalogue lookup of the SKU** — never from the price/figures in the buyer's email (M4).

## Confirm a sale (critical)

- **A "thank-you"/success page is NOT proof of payment** — its URL and parameters are forgeable (H4).
- Confirm **every** sale in the Stripe/PayPal dashboard or the payment-confirmation email before
  you dispatch or mark anything sold. Never wire fulfilment (or auto-mark-sold) to a buyer landing
  on a success page.

## Mark an item sold / retire it — do in this order (H1)

1. **Kill the payment primitive first:** deactivate the Stripe Payment Link **and** disable the
   PayPal button at the provider.
2. **Then** set `status: sold` in the `.md` (keeps the page for SEO/history) or delete the file.
3. Commit + push.

Why this order: the payment link is the real gate. Front matter is cosmetic, and cached pages /
shared URLs outlive your edit — a still-live link could take money for a sold item if you flip
`status` first. After retiring, **verify** the deactivated link now blocks or 404s at the provider (L3).

For repeatable lines selling down (not gone): decrement `quantity` and re-cap the Stripe link
(H3 above); only set `status: sold` at zero.

Step 2 now also happens on its own for Stripe items — see the reconciler below. Step 1 is still
yours, and it is the one that matters.

## Automatic sold-state reconciler (Phase 4a)

`scripts/reconcile_sold.rb`, run by `.github/workflows/reconcile-sold.yml` roughly every 15 minutes,
keeps `status:` in step with Stripe **so you don't have to remember step 2 above**. It asks Stripe
which payment links are still active; any product whose `stripe_url` has dropped off that list has
sold out, so it rewrites the file to `status: sold`, `quantity: 0` and **opens a pull request**.
The PR merges itself once the checks pass, and the merge rebuilds the site.

You should see nothing but a green PR appearing and closing on its own. If one sits open, its
checks failed — that is the system working.

**It is a label-freshness tool, not a money guard.** A second buyer is already blocked at Stripe by
the link's 1-use cap, whatever a cached page still says. Worst case here is a stale "available"
badge for one cron interval.

What it covers, and what it does not:

| Case | Automatic? |
|------|:---:|
| Stripe one-off sold | ✅ |
| Stripe repeatable fully sold out (uses cap hit) | ✅ |
| Stripe repeatable **partial** stock change | ❌ — `active` only flips at full sell-out; decrement `quantity` by hand |
| PayPal (any) | ❌ — no inventory read; mark it sold by hand |
| Item with no `stripe_url` | ❌ — ignored entirely |

It **never** flips an item back to available. Re-listing is deliberate: new link, restock, re-cap.
**Manual `status: sold` edits remain the fallback** and are still required for the ❌ rows.

### Why a pull request rather than a direct push

So the bot's own commits go through the same checks as yours. A push straight to `main` skips
every gate; a PR does not. It costs a couple of minutes of extra latency on a sold badge, which
is worth nothing next to the risk it removes.

This is the one piece that needs real setup, because of a deliberate GitHub rule: **the built-in
`GITHUB_TOKEN` cannot trigger workflows.** A PR it opened would sit with its checks pending
forever and could never merge. So the workflow needs a GitHub App (or a PAT) whose token does
trigger them.

### One-time setup

Until step 2 is done the workflow runs but does nothing — it logs "STRIPE_SECRET_KEY is not set —
skipping" and passes, rather than mailing you a failure every 15 minutes. Steps 3–6 are only
needed once something actually sells.

1. **Stripe key.** Dashboard → **restricted key**, permission **Payment links: read** only
   (it never writes).
2. **Stripe secret.** Repo → Settings → Secrets and variables → Actions → new repository secret
   **`STRIPE_SECRET_KEY`**.
3. **GitHub App.** Settings (your account) → Developer settings → GitHub Apps → New GitHub App.
   Name it anything ("glass-goblin reconciler"); untick Webhook → Active. Under **Repository
   permissions** grant only **Contents: Read and write** and **Pull requests: Read and write**.
   Create it, then **Install** it on this repository only.
4. **App credentials.** From the App's page: copy the **Client ID** into a repository *variable*
   named **`RECONCILE_APP_CLIENT_ID`** (Settings → Secrets and variables → Actions → Variables —
   a variable, not a secret; it isn't sensitive). Then **Generate a private key**, and paste the
   whole downloaded `.pem` file, including the BEGIN/END lines, into a repository *secret* named
   **`RECONCILE_APP_PRIVATE_KEY`**.
   *Simpler alternative:* skip the App and put a fine-grained PAT (same two permissions, this repo
   only) in a secret named **`RECONCILE_PAT`**. The workflow uses it if no App is configured. It
   works, but it is a long-lived credential tied to you personally; the App's token lasts an hour.
5. **Allow auto-merge.** Settings → General → Pull Requests → tick **Allow auto-merge**. Without
   it the PR still opens, and the run warns instead of failing — you just merge it yourself.
6. **Make the checks required** (this is what gives the PR its teeth). Settings → Rules → New
   ruleset, targeting `main`: enable **Require a pull request before merging** with **0 required
   approvals** — leave it at 0, or the bot's PR waits for a human forever — and **Require status
   checks to pass**, adding **`Ruby tests`** and **`Jekyll build`**. Leave "Do not allow bypassing"
   unticked so you can still push directly when you want to.
7. On the **fork**, GitHub disables scheduled workflows by default — open the Actions tab and enable
   them. (Public repos also auto-disable a schedule after 60 days with no activity; a manual run
   re-arms it.)

Without step 6 the PR flow still works, it just merges as soon as it is mergeable — the plumbing
is proven but nothing is actually enforced.

### Running it by hand

Actions → *Reconcile sold state* → **Run workflow**. Tick **dry run** first: it prints what it would
change and writes nothing. Untick to apply.

### If a reconcile PR is sitting open

- **Checks red** — something the suite guards is broken. Read the failing check; fix the cause on
  `main`. The next run rebuilds the PR branch from `main`, so a fix on `main` clears it.
- **Checks green but not merging** — auto-merge probably isn't enabled (step 5), or the ruleset
  asks for an approval it will never get (step 6). Merge it by hand meanwhile.
- **It keeps reopening after you close it** — that is correct. The item really is sold at Stripe
  and `main` still says otherwise; closing the PR doesn't change either. Fix the underlying state.

### If it refuses to run

`Refusing to reconcile: Stripe reports zero active payment links…` means Stripe returned an empty
list while products still point at links. That is what a wrong-account or de-permissioned key looks
like, and acting on it would mark the whole shop sold with no automatic way back. Check the key
first. If the shop genuinely has sold out, re-run with the **allow empty active** box ticked.

## The test suite and what it blocks

Run it any time with **`ruby test/all.rb`** (a second or two; needs no gems, no network, no
Stripe key). It checks the reconciler's behaviour and validates every product file.

It is wired in as a gate, so you do not have to remember to run it:

- **The site will not deploy if it fails.** `jekyll.yml` builds only after the tests pass.
- **The reconciler will not run, or raise a PR, if it fails.** It tests before touching a product
  file and again before pushing what it wrote.
- **Pull requests get the tests plus a full site build** — the reconciler's own PRs included, and
  the go-live PR upstream.

What it will catch for you when editing the catalogue by hand:

- a product missing `sku`/`title`/`price`/`status`/`quantity`, or one whose `sku` no longer
  matches its filename;
- an image referenced in front matter that isn't in `assets/products/`;
- a price that isn't a number, a negative stock count, or an item marked sold that still
  claims stock;
- a payment link that isn't https or isn't on `buy.stripe.com` / `www.paypal.com`;
- **a one-off given a PayPal link** — the cross-provider oversell risk the provider policy
  above exists to prevent (`gg-0001` is listed in the test as the known demo exception; when
  you switch it to Stripe-only at go-live, remove it from that list);
- **a Stripe secret key committed anywhere in the repo.** If this one fails, rotate the key at
  Stripe first, then remove it — a key that has been pushed should be treated as burnt.

If a failure looks wrong rather than real, the message names the file and the field. Fix the
data; don't loosen the test to make it pass.

## Test before trusting (Phase 2 "done when")

For **each** item (not just one per provider): do a real test purchase and confirm the hosted
checkout's **price, currency, and item match the product page** (M1, M2) — through **both** Stripe
and PayPal — and that the invoice button produces a correctly prefilled enquiry.

## Buttons / SDK note (L1)

Prefer plain hosted link-out buttons (what the site uses) over embedded provider JS SDKs. If you
ever embed an SDK, pin it to the provider origin and add Subresource Integrity where supported.

## Go-live checklist (Phase 3)

- [ ] `bundle exec jekyll build` runs clean.
- [ ] Links/assets use `relative_url`.
- [ ] Images optimised.
- [ ] Prices and currency (GBP) correct on every item.
- [ ] Sold items handled (no buttons; "Sold" badge shows).
- [ ] Mobile layout of the shop grid checked.
- [ ] **"Enforce HTTPS" enabled** on `www.glassgoblin.co.uk` with the certificate issued — otherwise
      buy-button URLs can be swapped in transit (C2).
- [ ] At least the real sample item purchasable end-to-end, then merge/PR `main` to the live repo.
