# E-commerce integration — v1 implementation plan

Status: **Phases 0–1 complete** (2026-07-20), deployed to the test fork, runbook scaffolded.
All three Phase-4 items were then built early, because none of them needed operator setup to write:
the **sold-state reconciler** (4a, 2026-08-08), the **bulk-listing script** and the **webhook
trigger** (4b, both 2026-10-20). Phase 4 is therefore code-complete; deploying 4b stays optional.
**Phase 2 (payment wiring) is still next** — and everything now waits on the same thing: Stripe
credentials. The reconciler needs a read-only key as an Actions secret; the bulk lister needs a
write-scoped key locally. Neither can be proven until those exist.
**When those credentials arrive, work through `.docs/go-live-test-pass.md`** — an ordered pass
that takes a CSV row through to an item taking itself off sale, and which supersedes the ad-hoc
`gg-0002` acceptance test.
Created: 2026-07-11
Supporting investigation: `.investigations/ecommerce-integration.md`
Security review (payment manipulation): folded into the phases below; findings tagged inline
(C1–C2, H1–H4, M1–M4, L1–L3).
Repo: glass-goblin (static Jekyll site on GitHub Pages)

## Objective

Add passive product sales to the static Glass Goblin site at **£0/month**, lowest per-sale fee,
no backend, no change to free GitHub Pages hosting. Catalogue shape is ours to control.

## Decisions this plan implements

- Checkout: **embedded buy buttons** on Jekyll product pages, hosted checkout off-site.
- Payments **by item type** (decided 2026-08-02):
  - **One-off items (`gg-NNNN`, qty 1): Stripe only.** Cleanest deactivation API in both
    directions, lowest per-sale fees, and — critically — it makes the **cross-provider oversell
    race structurally impossible**: one unique unit listed on two independent checkouts can be
    bought on both before either self-closes, so a single provider per one-off removes that risk
    at the root rather than merely narrowing the window.
  - **Repeatable lines (beads, qty >1): Stripe + PayPal both allowed.** Cross-provider oversell
    here is soft (backorder / remake), so buyer choice outweighs the small risk.
- **Monzo bank-transfer invoice** option shown on **every available item**.
- Catalogue is a **Jekyll collection we control**; bulk listing handled by our own script later.
- No multi-item cart in v1 (one item per checkout). Accepted.
- Cross-posting hub (Shopify/multichannel) is **phase 2**, out of scope here.

## Constraints that shape the design

- GitHub Pages builds Jekyll in safe mode. **Use only core Jekyll features** — a `_products`
  collection is core (configured in `_config.yml`), so no new gems and the free build keeps
  working. No plugins that GitHub Pages does not whitelist.
- SCSS convention (repo `CLAUDE.md`): **all colours via variables** in `_sass/_variables.scss`;
  no hardcoded hex/rgb, no inline colour styles. New UI gets classes styled in SCSS.
- Links/assets use `relative_url` so paths work under the Pages baseurl.
- **Security principle (payment integrity):** charge authority lives on Stripe/PayPal, never on
  the static page. The front matter (`price`, `status`, `quantity`) is **cosmetic** — it changes
  only what the page displays and enforces nothing. The real controls are Stripe link settings,
  PayPal button type, HTTPS/domain integrity, and the operator's manual checks. Never wire
  fulfilment to anything the buyer can edit (page fields, `mailto` body, success-redirect URL).

---

## Product data model

A **`_products` collection** (one markdown file per item), configured in `_config.yml`. Each
product gets its own page/permalink (shareable for passive/social sales) and a markdown body for
the description. A script can write these files later.

`_config.yml` addition:

```yaml
collections:
  products:
    output: true
    permalink: /shop/:name
defaults:
  - scope: { path: "", type: products }
    values: { layout: product }
```

Per-product front matter (`_products/<sku>.md`):

```yaml
---
sku: gg-0001            # our id, also the filename
title: Uranium glass vase
price: 45.00            # number, GBP
condition: Good, minor base wear
status: available       # available | sold
quantity: 1             # 1 for one-offs; >1 for repeatable lines
images:
  - /assets/products/gg-0001-1.jpg
stripe_url: https://buy.stripe.com/xxxx   # Stripe Payment Link
paypal_url: https://www.paypal.com/...    # hosted button / PayPal.me link
---
Longer description in markdown.
```

Fields are ours; nothing here is shaped around a third-party platform.

---

## Phases

### Phase 0 — Data model and config ✅ (done 2026-07-20)
- [x] Add the `products` collection + defaults to `_config.yml`.
- [x] Create one real sample product file in `_products/` (`gg-0001`, uranium glass vase) to build against.
- [x] Add `assets/products/` for product images (holds an on-brand placeholder SVG until real photos land).
- **Done when:** `bundle exec jekyll build` succeeds and the sample product renders at
  `/shop/<sku>`. ✅ Verified — builds clean; renders at `/shop/gg-0001` (output `_site/shop/gg-0001.html`).

**Correction to the plan:** Phase 0 could not satisfy its own build check in isolation — the
`layout: product` default points at a layout not created until Phase 1, so the build fails with
"Could not find layout 'product'" until it exists. A **minimal** `_layouts/product.html` (fields +
body only; no buttons, shipping note, or styling) was therefore added in Phase 0, and Phase 1 now
**expands** it rather than creating it. Also added a `.gitignore` (`_site/`, `vendor/`, caches) —
the repo had none and the local build produces those artifacts.

### Phase 1 — Templates and styling ✅ (done 2026-07-20)
- [x] `_layouts/product.html` — expanded: buy-buttons include + Royal Mail shipping note (and,
      beyond the original scope, a multi-photo mosaic + hand-rolled lightbox, subtitle, a
      specifications block, and a stock count + "each" pricing for qty>1 lines).
- [x] `pages/shop.md` — grid listing over `site.products` (card = image, title, price); sold
      items get a "Sold" badge and dimmed image; each card links to its product page.
- [x] `_includes/buy-buttons.html` — sold → no buttons ("This piece has sold."); available →
      Stripe (primary, when `stripe_url` set) + PayPal (when `paypal_url` set) + a bank-transfer
      invoice `mailto:` (hello@glassgoblin.co.uk, prefilled with title + SKU) on every available item.
- [x] SCSS: product grid, cards, buttons, sold badge — classes only, colours from `_variables.scss`.
- [x] Shop nav entry points at the listing (later restructured: "Online shop" top-level +
      "Shop in person" group; frosted dropdown panel).
- **Done when:** shop grid + product page render ✅; buttons appear/hide per `status` ✅;
      **all three purchase options show on available items** — ⏳ today only the invoice CTA shows;
      the Stripe & PayPal buttons are wired and render as soon as their links exist (verified with
      mock links). This last criterion is therefore gated on **Phase 2**, not a Phase 1 gap.

**Phase 1.5 extras (done, beyond the original plan):** mosaic gallery + lightbox; client-side shop
search/filter (search, category, max price, in-stock, glows-under-UV) backed by `category`/`tags`
metadata; frosted nav dropdown + nav restructure; per-item stock display. Catalogue expanded to
**8 products** (tiara, 2 rings, 5 bead lines). Data caveats still open: ring prices are placeholders
(no price in source post); ring photos show both rings together; bead images are the maker's
composite cards with price/stock text baked in.

### Phase 2 — Payment wiring and runbook

> **▶ Pick up here (next session).** Phases 0–1 are done and live on the test fork; the runbook +
> per-item checklist are scaffolded in `.docs/`. Remaining Phase 2 work is mostly the operator's:
> create the Stripe Payment Links + PayPal hosted buttons in your own accounts, paste the URLs into
> each `_products/*.md` (`stripe_url` / `paypal_url`), then verify a per-item test purchase. While
> wiring `gg-0002`/`gg-0003`, also set their **real prices** (currently placeholders).

- [ ] **Stripe:** create a product/price per item, create a Payment Link, enable shipping-address
      collection. Currency **GBP** (M2). Bind shipping to the charge — bundle it into the price
      or configure a Stripe **shipping rate**; never rely on collecting it out-of-band (M3).
      - One-offs: **limit the link to 1 use** so it cannot be bought twice **and** turn
        **adjustable quantity OFF, fixed quantity = 1** — the 1-use cap limits checkouts, not
        units per checkout (H2).
      - Repeatable lines (qty>1): set the Stripe link **total-uses cap = current stock count**
        as a crude oversell limit; document a restock/re-cap step. There is no automatic stock
        decrement — if this is skipped, qty>1 lines are **not** protected against oversell (H3).
      - Paste the URL into `stripe_url`.
- [ ] **PayPal:** create a **server-side hosted button only** (button ID references a
      PayPal-stored price). **Do not** use a legacy amount-in-form button or PayPal.me as a buy
      button — both let the buyer set the amount (C1). Paste into `paypal_url`.
- [ ] **Invoice route:** wire the CTA to the seller's contact/enquiry so a Monzo invoice can be
      issued manually. The prefilled `mailto` (SKU + title) is buyer-editable — the operator must
      issue the invoice from their **own catalogue lookup of the SKU**, never from figures in the
      buyer's email (M4).
- [x] **Runbook scaffolded** in `.docs/` (not published): `shop-runbook.md` (list / sell / retire,
      Stripe/PayPal/Monzo setup, go-live checklist, security rules inline) + `product-checklist.md`
      (per-item template + current-catalogue wiring-status table). Finalise as links are created.
      It must carry these security rules:
      - **Success redirect ≠ proof of payment.** Confirm every sale in the Stripe/PayPal
        dashboard/email; never trigger fulfilment (or auto-mark-sold) from a buyer landing on a
        thank-you page — its URL/params are forgeable (H4).
      - Issue Monzo invoices from catalogue lookup, not the buyer's email (M4).
      - **Never** commit the Stripe secret key — repo, front matter, or client JS. The Phase 4
        script reads it from the environment; only the public Payment Link URL is committed (L2).
- [ ] Prefer plain hosted link-out buttons over embedded provider JS SDKs; if an SDK is embedded,
      pin it to the provider origin and add Subresource Integrity where supported (L1).
- **Done when:** a **per-item** test purchase (not just one per provider) reaches a working
      hosted checkout whose **price, currency, and item match the product page** (M1, M2), through
      both Stripe and PayPal, and the invoice CTA produces a correctly prefilled enquiry.

### Phase 3 — Go-live and retire/sold workflow
- [ ] Define the **retire-on-sale** step, in this order: **(1) deactivate the Stripe link +
      disable the PayPal button, then (2)** set `status: sold` (keeps page for SEO/history) or
      delete the file. The payment link is the real gate — front matter is cosmetic and cached
      pages/shared URLs outlive it, so kill the payment primitive first (H1). Record in the
      runbook. After retiring, verify the deactivated link blocks/404s at the provider (L3).
- [ ] Go-live checklist: build clean, links use `relative_url`, images optimised, prices/currency
      correct, sold items handled, mobile layout of the grid checked, and **"Enforce HTTPS"
      enabled** on the custom domain (`www.glassgoblin.co.uk`) with the certificate issued — else
      buy-button URLs can be swapped in transit (C2).
- **Done when:** the shop is live on `main` (GitHub Pages deploy) with at least the real sample
      item purchasable end-to-end.

### Phase 4 — Deferred (not v1)
- **Sold-state reconciler + webhooks** — keep `status:` in sync with the providers automatically.
  Full spec: `.plans/sold-state-reconciler-v1.md` (4a = scheduled Action polling Stripe's `active`
  flag; 4b = optional webhook trigger for low latency). Non-safety-critical: money-safety is already
  provider-side, so this only improves label freshness.
  - **4a built 2026-08-08** (ahead of Phase 2/3, since it needed no operator setup to write):
    `scripts/reconcile_sold.rb` + `.github/workflows/reconcile-sold.yml`, runbook section added.
    Blocked on the operator creating a restricted Stripe key and adding it as the
    `STRIPE_SECRET_KEY` Actions secret; `gg-0002`'s already-deactivated demo link is then the
    acceptance test (dry run first). See the spec's "As built" section.
  - **4b built 2026-10-20** — `workers/reconcile-trigger/`, a dependency-free Cloudflare Worker
    that verifies a Stripe webhook signature and fires the same `reconcile` dispatch the cron
    fires, cutting label lag from ~15 minutes to seconds. **Deploying it remains optional and is
    still the operator's call**: it changes nothing about money-safety, and the cron catches
    everything if it is never stood up. Setup in the runbook ("Webhook trigger").
- Bulk-listing **script** — **built 2026-10-20** (like 4a, ahead of its turn, because it needed no
  operator setup to write). `scripts/bulk_list.rb` + `scripts/products.example.csv`, runbook section
  added. Reads a CSV and, per row, creates the Stripe Product + Price + Payment Link and writes
  `_products/<sku>.md`. The v1 file shape did prove a clean fit — nothing about the data model
  needed changing. Blocked only on the operator creating a **write-scoped** Stripe key; the script
  previews fully without one. See the "As built" notes below.
- **Cross-posting hub** (Shopify Basic + Marketplace Connect, or a multichannel lister) — see the
  investigation's phase-2 analysis; revisit when safely cross-listing unique stock is the goal.

---

## Build, deployment & conventions (notes from the 2026-07-20 build)

**Environments & deploy**
- `origin` = `SRBayliss/glass-goblin` — the operator's **test fork**. Deploys via GitHub Actions
  (`.github/workflows/jekyll.yml`) to a **project page** at `https://srbayliss.github.io/glass-goblin/`.
- `upstream` = `smolpotatoes/glass-goblin` — production. Go-live (Phase 3) = a **PR from the fork's
  `main` to `smolpotatoes`**.
- Rhythm: commit → push `main` to `origin` → verify on the test Pages site.
- **Do NOT set `baseurl` in `_config.yml`.** The Actions build injects `--baseurl` from
  `actions/configure-pages` (`base_path`) — so it's `/glass-goblin` on the fork's project page and
  empty on production's root domain automatically. Local `jekyll serve` uses an empty baseurl (correct
  for localhost). A hardcoded baseurl would break one of the two targets.

**Conventions**
- SKUs: one-offs use `gg-NNNN`; bead lines reuse the maker's own catalogue codes (`b015`, `b025`, …)
  as the SKU/filename, since those are what the operator recognises for orders.
- Product images: `assets/products/<sku>-N.jpg`. Invoice enquiries go to `hello@glassgoblin.co.uk`.
- Gallery/lightbox: `assets/js/product-gallery.js`. Shop filtering: `assets/js/shop-filter.js`
  (facets driven by each product's `category` + `tags`). Both hand-rolled, no dependencies.

**Catalogue as of 2026-07-20 (8 products):** tiara `gg-0001`; rings `gg-0002`/`gg-0003`; beads
`b015`/`b016`/`b020`/`b025`/`b030`. Open data caveats (see the Phase 1.5 note): placeholder ring
prices; ring photos show both rings together; bead images are composite cards with baked-in
price/stock text; not all source photos were pulled (post 1: 5 of 8; beads post had a "+6" that may
hide 1–2 more bead types).

**Sourcing product data from Facebook (reusable method).** The operator's FB posts are login-walled
to scrapers. With a logged-in Chrome (Claude-in-Chrome MCP): open a post's photo theatre, step
through with the arrow key reading each photo's `fbid` from the URL, then download full-res via
`https://lookaside.fbsbx.com/lookaside/crawler/media/?media_id=<fbid>` (unauthenticated, no token).
Read captions from the post; per-bead detail is baked into the composite images.

---

## Fees recorded (verify before go-live)

| Route | Per-sale cost (approx UK) | Notes |
|-------|---------------------------|-------|
| Stripe Payment Link | ~1.5% + 20p | Primary; lowest card fee, £0/month, no product cap. |
| PayPal button | ~2.9% + fixed | Alternative for buyer preference. |
| Monzo invoice (bank transfer) | ~£0 | Offered on every item; manual, no buyer card protection. |

## Verification approach

**Automated (added 2026-08-08, once the reconciler made unattended writes possible).**
`ruby test/all.rb` — 78 minitest cases, stdlib only, no gems, no network:

- `test/test_reconcile_sold.rb` — the reconciler's behaviour, with Stripe injected.
- `test/test_bulk_list.rb` — the bulk lister's behaviour, with Stripe injected: the batch it
  refuses, the caps it sets, and the fact that the files it generates satisfy the catalogue rules
  below rather than merely parsing.
- `test/test_catalogue.rb` — every committed product parses and is internally consistent
  (sku matches filename, images exist, prices positive, sold ⇒ no stock, payment links are
  https and on the provider's host), the one-off Stripe-only policy holds, and no provider
  secret is committed (L2).

Plus 24 tests for the webhook receiver (`cd workers/reconcile-trigger && node --test`) — Node's
built-in runner, nothing to install, `fetch` injected so nothing reaches the network.

The suite **gates deployment**: `jekyll.yml` will not build or deploy unless
`.github/workflows/ci.yml` passes, and the reconciler runs it both before it is allowed to
touch a product file and again before it commits the result. `ci.yml` runs the Ruby suite and
the receiver's tests as separate jobs, and the `main` ruleset requires all three check names
(**Ruby tests**, **Worker tests**, **Jekyll build**) — created 2026-10-20, with the Admin role
on the bypass list so direct pushes still work.

**Manual, still required for anything visual.** `bundle exec jekyll build` / `serve` plus a
look at the shop grid, a product page, the sold state, and the invoice CTA. The tests say
nothing about how the page looks.

---

## As built — bulk-listing script (2026-10-20)

`scripts/bulk_list.rb`. CSV in, Stripe objects and `_products/*.md` out. The decisions worth
recording, because most of them are departures from how the reconciler behaves:

1. **Preview is the default; `--apply` is opt-in.** The opposite of the reconciler, deliberately.
   Every write the reconciler makes is undone by a human editing a file. This one creates objects
   in a live Stripe account, so the default had to be the harmless one.
2. **The whole batch is validated before anything is created.** A run that fails on row 8 of 12
   leaves live payment links with no page pointing at them — the expensive mess. Every bad row is
   reported at once, with its spreadsheet line number, and nothing reaches Stripe.
3. **The Stripe product id is the sku.** This is what makes a repeat run safe without storing any
   state: a second attempt at the same item collides at Stripe instead of silently creating a
   duplicate listing. Idempotency keys cover a retry inside the 24-hour window; the deterministic
   id covers forever.
4. **It never overwrites an existing `_products/<sku>.md`.** Descriptions and photo lists are
   hand-written; clobbering them to re-paste a URL is not a trade worth making.
5. **The one-off provider policy is enforced in code**, not just documented — a row with
   `quantity: 1` and a `paypal_url` is refused. The policy's whole value is that the race is
   structurally impossible, which a convention nobody checks does not deliver.
6. **Prices convert through `Rational`, not `Float`.** `(4.35 * 100).to_i` is 434. That is a real
   mispriced listing, and it only shows up on the prices unlucky enough to land badly in binary.
7. **A separate `STRIPE_WRITE_KEY`**, not the reconciler's `STRIPE_SECRET_KEY`. Sharing the
   variable name would invite widening the unattended cron's read-only key to write scope — the
   one credential in this system that should never be able to create anything.
8. **Photos are discovered on disk, not declared in the CSV.** The catalogue test fails the build
   if a product references an image that is not in the repo, so the generator can only reference
   what it can see. No photos at all is a warning, not an error: the templates skip the gallery.
9. It does **not** commit. The reconciler commits because nobody is watching it; here the operator
   reviews the diff.

**Verified** with 46 tests (stubbed Stripe, no network), each checked against a deliberate
mutation — guard removed, cap changed, currency switched, quoting dropped — to confirm it actually
goes red. Two mutations in the first pass were not caught by the tests I thought covered them: one
never matched the source, and one hit the first of two identical `return 1` lines, so it tested the
wrong branch. Both were re-run against the exact text before the suite was trusted. One generated
file was also put through a real `jekyll build` to confirm the page renders — gallery, details,
buy button and shop card — since the tests check fields, not rendering.

**Untested until a write key exists:** the live Stripe calls and their response shapes.

## Open items before implementing

_(none — ready to implement)_
