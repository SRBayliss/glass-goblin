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

## Bulk-list a batch of items

For more than two or three items at once, `scripts/bulk_list.rb` does steps 2 and 3 for you: it
creates the Stripe Product, Price and Payment Link per row — with the caps from the policy below
already set — and writes `_products/<sku>.md`. One command instead of a round of dashboard clicking
per item.

**One-time setup.** Create a Stripe key with **write** access to Products, Prices and Payment Links.
This is *not* the reconciler's key: that one is read-only and lives in an Actions secret. This one
stays on your machine and is never committed or added to GitHub.

```sh
export STRIPE_WRITE_KEY=...            # PowerShell: $env:STRIPE_WRITE_KEY = "..."
```

**Each batch.**

1. Copy `scripts/products.example.csv` and fill in a row per item. Required columns: `sku`, `title`,
   `price`, `quantity`. Optional: `category`, `tags`, `subtitle`, `condition`, `details`,
   `description`, `paypal_url`, `shipping_rate`. `tags` and `details` separate entries with `|`;
   `details` are `Label=Value` pairs.
2. Put the photos in `assets/products/` as `<sku>-1.jpg`, … **before** running it. The script
   references the files that exist at the time it runs; it warns about any item with none.
3. Preview — this is the default, and it writes nothing anywhere:
   ```sh
   ruby scripts/bulk_list.rb batch.csv
   ```
   Read the caps it reports per item. Fix the CSV and preview again until it is right.
4. Create them for real:
   ```sh
   ruby scripts/bulk_list.rb batch.csv --apply
   ```
5. Preview the site (`bundle exec jekyll serve`), then commit and push. The script does not commit —
   you review the new files first.

**What it will not do, so you are not surprised:**

- **It refuses the whole batch if any row is bad**, before creating anything. A half-listed batch
  leaves live Stripe links with no page pointing at them, which is the expensive mess to clean up.
- **It never touches an existing `_products/<sku>.md`.** A sku you already have is reported and the
  batch stops. Re-pasting a URL is not worth losing a description you wrote by hand.
- **It never reuses a Stripe product id.** The id *is* the sku, so a second run for the same item
  collides and stops rather than quietly creating a duplicate listing.
- **It will not list a one-off with a `paypal_url`** — that is the cross-provider oversell race, so
  the policy is enforced in code, not just written down here.
- **It does not create PayPal buttons.** Make those by hand for repeatable lines (below) and either
  put the URL in the CSV or paste it afterwards.
- **It does not set postage.** Add a `shipping_rate` column (a Stripe shipping-rate id, `shr_…`) or
  make sure postage is inside the price — it warns when neither is evident. Never collect it
  separately afterwards (M3).

**If it stops partway**, the report names exactly what was listed, what failed, and what was never
attempted. Check Stripe for a product created without a file beside it before you run it again.

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
5. ~~**Allow auto-merge.**~~ **Done 2026-10-20.** Settings → General → Pull Requests →
   **Allow auto-merge** is ticked. (Without it the PR still opens and the run warns instead of
   failing — you just merge it yourself.)
6. ~~**Make the checks required.**~~ **Done 2026-10-20** — a ruleset named **`main`** now targets
   the default branch with **Require a pull request** at **0 required approvals** and required
   status checks **`Ruby tests`**, **`Worker tests`** and **`Jekyll build`**. The **Admin**
   repository role is on the bypass list, so you can still push straight to `main` yourself.
   To see or change it: Settings → Rules → Rulesets → `main`. To drop it entirely:
   `gh api -X DELETE repos/SRBayliss/glass-goblin/rulesets/25443801`.
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

## Webhook trigger (Phase 4b) — optional

The reconciler above runs on a 15-minute cron, so a sold item can show as available for up to
15 minutes. This makes that seconds instead, by having Stripe tell the repo the moment something
happens: `workers/reconcile-trigger/` is a small Cloudflare Worker that verifies the webhook came
from Stripe and then fires the same `reconcile` run the cron fires.

**You do not need this.** It changes nothing about money-safety — a second buyer is blocked at
Stripe either way — and if the Worker breaks, is deleted, or never gets deployed, the cron carries
on catching everything exactly as before. Set it up only if the 15-minute label lag turns out to
bother you in practice.

### What it does and does not do

It reads one field of the event: the type. It does **not** work out which item sold, and it does
not write anything. It says "something changed, go and look", and the reconciler re-derives the
truth from Stripe as it always does. That is deliberate — it keeps exactly one writer, so the fast
path and the cron can never disagree with each other.

### One-time setup

1. **A GitHub token for the Worker.** A fine-grained PAT, this repo only, **Contents: Read and
   write** (that is what `repository_dispatch` needs). Note its expiry — when it lapses the Worker
   starts returning errors and you fall back to cron speed, which is easy to miss.
2. **Deploy the Worker.** From `workers/reconcile-trigger/`:
   ```sh
   npx wrangler deploy
   npx wrangler secret put GITHUB_TOKEN           # paste the PAT
   ```
   Copy the `https://….workers.dev` URL it prints.
3. **Add the endpoint in Stripe** (Developers → Webhooks → Add endpoint). Point it at that URL and
   subscribe to exactly two events:
   - `checkout.session.completed` — something sold.
   - `payment_link.updated` — a link hit its cap and switched itself off.
4. **Give the Worker the signing secret.** Stripe shows a `whsec_…` for the endpoint:
   ```sh
   npx wrangler secret put STRIPE_WEBHOOK_SECRET
   ```
   Until this is set the Worker rejects everything with a 500, which is the intended behaviour for
   a receiver that cannot verify what it is being sent.
5. **Verify.** Use "Send test webhook" in Stripe for `checkout.session.completed`. You should see a
   `202` in Stripe's delivery log and a **Reconcile sold state** run appear in the repo's Actions
   tab within seconds. A `400` means the signing secret does not match the endpoint.

### If something goes wrong

- **`400 Rejected: signature does not match the body`** — the `STRIPE_WEBHOOK_SECRET` belongs to a
  different endpoint. Each endpoint has its own; re-copy it.
- **`400 … timestamp is …s away from now`** — the event is older than five minutes. Normal for a
  replayed request; suspicious otherwise.
- **`500 Receiver is misconfigured`** — a secret or var was never set. The message names which.
- **`502 GitHub refused the dispatch`** — almost always the PAT: expired, or missing Contents
  write. Stripe retries a 502 on its own, and the cron covers the gap meanwhile.
- **Nothing arrives at all** — check Stripe's delivery log first; if Stripe shows no attempt, the
  endpoint is disabled or subscribed to the wrong events.

To remove it: delete the endpoint in Stripe and run `npx wrangler delete`. Nothing else changes.

### The receiver is gated like everything else

`ci.yml` has a **Worker tests** job, and **Worker tests** is in the `main` ruleset's required
checks alongside **Ruby tests** and **Jekyll build** (added 2026-10-20). A check that is not
listed there cannot block anything, so if you ever add another job, add it to the ruleset too.

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
