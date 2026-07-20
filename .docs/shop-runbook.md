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

## PayPal button (per item)

- Create a **server-side hosted button** (button ID references a price stored at PayPal).
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
