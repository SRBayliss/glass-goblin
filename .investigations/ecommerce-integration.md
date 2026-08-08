# E-commerce integration investigation

Status: **Planned** — requirements complete, direction signed off. Implementation plan:
`.plans/ecommerce-integration-v1.md`
Started: 2026-07-11
Repo: glass-goblin (static Jekyll site on GitHub Pages)

## Goal

Add a simple e-commerce capability to the Glass Goblin website so it can generate
passive sales, without breaking the free-hosting, low-cost model the business runs on.

## Context

- Glass Goblin is a one-person fledgling business selling glass (unique antique/collectible
  pieces and some repeatable lines) plus services (restoration, jewellery commissions, etc.).
- The website is a **static Jekyll site deployed free on GitHub Pages**. There is **no
  server-side code** and no paid hosting. Keeping cost at or near £0 is a core constraint,
  not a nice-to-have.
- The business already sells on **eBay, Vinted, and Etsy**. The website is an *additional*
  sales channel, not a replacement.
- Current `pages/shop.md` is a stub. Fulfilment is already handled: Royal Mail tracked
  services (Tracked 48 for most items), tracking emailed on dispatch.

## Constraints (hard)

1. **Static site, no backend.** Any integration must work as client-side JS embeds or
   outbound links. No server we control can hold secrets or run order logic.
2. **£0/month target.** No fixed monthly platform fee if avoidable. Per-transaction fees
   should be as low as possible (this is the explicit priority over feature richness).
3. **GitHub Pages hosting retained.** No migration to paid hosting for v1.
4. **One operator.** Time spent per sale must be minimal; the solution should be "passive".

## Requirements captured (round 1)

| Dimension | Answer |
|-----------|--------|
| Platform | Not committed to Shopify. Wants cheapest possible, minimal/zero monthly cost, lowest per-sale fees. Already on eBay/Vinted/Etsy. |
| Catalogue | Mix of unique one-offs (qty 1) and repeatable stock. |
| Checkout UX | Undecided — wants a recommendation (embedded buy buttons vs hosted store). |
| Priority | Willing to invest development time up front for a robust solution with minimal ongoing cost (ideally free) and minimal time per sale. |

## Requirements captured (round 2)

| Dimension | Answer |
|-----------|--------|
| Cross-listing | **Website carries its own stock** — distinct items, not simultaneously listed on the marketplaces. |
| Payments | Both **PayPal and Stripe** available / preferred. |
| Scale | **Small now** (handful of curated items, occasional sales). Wants a path to scale and automate listing later. Warn of any product caps. |

## Key risk: cross-listing / overselling — RESOLVED for v1

Originally the crux: a one-off listed on the website *and* the marketplaces could sell twice,
with no backend to sync inventory. Round 2 resolves this — **the website carries its own
distinct stock**, so there is no simultaneous cross-listing and no double-sell risk. Inventory
handling for v1 is therefore trivial: retire a one-off from the site when it sells (and
deactivate its payment link). Revisit only if cross-listing is introduced later.

## Candidate approaches (initial landscape — to be refined)

Recorded here as a starting point; fees/plan details are approximate and MUST be
re-verified against current provider pricing before any decision.

| Option | Monthly cost | Per-sale fee (approx, UK) | Fit for static site | Notes |
|--------|-------------|---------------------------|---------------------|-------|
| Stripe Payment Links / Buy Button | £0 | ~1.5% + 20p (UK cards) | Embed link/button, hosted checkout | Lowest fees; limited storefront/inventory features |
| PayPal Buttons | £0 | ~2.9% + fixed | Embed button | Familiar to buyers; higher fee than Stripe |
| Snipcart | £0 test; fee/min on live | ~2% txn (min monthly above a threshold) | JS cart on the static site | True cart across items; watch minimum monthly |
| Ecwid (Lightspeed) free tier | £0 | payment-provider fee only | JS embed | Free tier caps product count; verify current limits |
| Gumroad | £0 | ~10% flat | Link/embed | Highest fee; simplest setup |
| Shopify Starter/Basic | Monthly fee | + per-sale | Buy Button embed | Likely ruled out by the monthly fee |

## Requirements captured (round 3 — confirmations)

| Dimension | Decision |
|-----------|----------|
| Cross-posting hub | **Parked to phase 2.** Not part of v1. |
| Catalogue shape | **We control it** — do not shape v1 data around Shopify's model. |
| Bulk listing | Handled later by **our own script**, not a platform's importer. |
| Payments | **Stripe primary, PayPal alternative** — confirmed. |
| Existing route | Business already issues **Monzo invoices** as a current sales route (see below). |

### Monzo invoices (existing route)

Monzo Business invoicing is already in use. Paid by bank transfer it is effectively **£0 fee**,
making it the cheapest route for the seller — cheaper than Stripe (~1.5% + 20p) or PayPal
(~2.9% + fixed). Trade-offs: it is **manual** (issue an invoice per sale, so not "passive"),
offers the buyer **no card-payment protection**, needs manual reconciliation, and **cannot be
an instant buy-button** on a static page. Decision: offer a "request an invoice / pay by bank
transfer" CTA on **every available item** (not gated by value), alongside Stripe and PayPal.

## Recommendation (v1)

Given £0/month, lowest per-sale fee, static site, own-stock, and a scale-later ambition:

**Checkout UX — embedded buy buttons, not a redirect to a hosted store.**
Render product pages on the Jekyll site and place a "Buy" button on each that opens a
provider-hosted checkout. Buyers stay on the Glass Goblin brand until the payment step, and
we avoid running a full hosted storefront elsewhere. A redirect-to-hosted-store approach buys
us nothing here and cedes branding.

**Payment — Stripe Payment Links as primary, PayPal button as an alternative.**
Both are £0/month with **no product caps**. Stripe has the lower card fee (~1.5% + 20p UK
vs PayPal ~2.9% + fixed), so it is the default; offering PayPal alongside captures buyers who
prefer it. A Payment Link is a URL per product/price — created in the dashboard now, created
via API later when we automate.

**Architecture — data-driven products, so it scales.**
Store products as structured data (a `_data/products.yml` file or a `_products` Jekyll
collection) and generate the product cards, pages, and buy buttons from a single Liquid
template. Adding an item = one data entry + a payment link. This is the "invest dev time now"
robustness: v1 is manual per item, but the same structure lets us later run a script that
creates the Stripe product via API and writes the data entry, i.e. automated listing.

**One-off inventory.** Retire the item from the data file when it sells and deactivate its
Stripe link. No sync needed while the website holds its own stock.

### Trade-off to be aware of: no customer-built multi-item cart

Stripe Payment Links / PayPal buttons check out **one item (or one fixed link) at a time** —
there is no cart letting a buyer combine several pieces into one order. For a small curated
shop of mostly unique items this is usually acceptable. If a true multi-item cart becomes a
priority, the options that add one (Snipcart, Ecwid) bring the caveats below.

### Product-cap / cost warnings

- **Stripe Payment Links** — no product cap, £0/month. ✅
- **PayPal buttons** — no product cap, £0/month. ✅
- **Ecwid free tier** — historically caps at ~5 products; a real limit for even a small shop.
  Verify current cap before considering. ⚠️
- **Snipcart** — adds a real cart but is not strictly £0: ~2% per transaction with a minimum
  monthly fee once live sales pass a threshold. ⚠️
- **Shopify Starter/Basic** — fixed monthly fee; ruled out by the £0 target. ❌

All fee/plan figures above are approximate and MUST be re-verified against current provider
pricing before committing.

## Option analysis: 3rd-party catalogue hub (Shopify) for cross-posting

Researched 2026-07-11 (figures verified against current sources; re-verify before committing).

### Cheapest Shopify option — Shopify Starter (UK)

- £5/month, monthly billing only.
- **5% transaction fee on every sale, charged even with Shopify Payments** (higher plans
  waive it with Shopify Payments; Starter never does). Card processing on top. All-in ≈ £7+
  per £100 sold — roughly 3–4× Stripe Payment Links (~1.5% + 20p) plus a fixed monthly cost.
- No full online store: embeddable buy buttons, Linkpop link-in-bio, social/messaging selling.
- **Conclusion for website-only own-stock use:** more expensive than the £0 Stripe path both
  monthly and per sale. Not justified for v1.

### The cross-posting case (why a hub could be worth it later)

Managing the catalogue in a hub like Shopify makes **one system the single source of truth
for products and inventory**, then syncs outward to marketplaces:

- List once, push the listing to eBay / Amazon / Walmart (Etsy with caveats) instead of
  re-keying per marketplace.
- **Inventory sync prevents overselling** — a sale on any channel decrements stock
  everywhere. This is exactly what would let the unique one-offs be *safely cross-listed*,
  removing the constraint that currently keeps the website on separate stock.
- One dashboard for orders and tracking across channels.
- Shopify **Marketplace Connect** app: free to install; first 50 marketplace orders/month
  free, then 1% per order capped at $99/month; syncs listings, inventory, orders, tracking,
  pricing.

### Caveats that stop this being a v1 decision

1. The sync benefit needs a **full online-store plan (Basic ≈ £25+/month), not Starter**.
   "Cheap Shopify" and "cross-posting hub" are different, more expensive tiers.
2. **Etsy is currently closed to new connections** via Shopify's native Marketplace Connect;
   syncing Etsy needs a third-party app (LitCommerce / Sellbery / Salestio) — another cost.
3. The hub **need not be Shopify** — dedicated multichannel listers do the same job, some with
   free tiers (e.g. LitCommerce free up to 10 products/orders).
4. Hybrid is possible: keep the free GitHub Pages front-end and pull products from a Shopify
   catalogue via the Storefront API / Buy Button SDK, so Shopify owns catalogue + checkout +
   marketplace sync while the site stays on free hosting — but this still carries the monthly
   plan cost.

**Verdict:** the cross-posting benefit is real and aligns with the "scale later" ambition, but
it only pays off once cross-listing is actually the goal, and it conflicts with the £0-now
target. Treat it as a **phase-2 option to revisit when cross-listing unique stock becomes a
priority**, not part of v1.

## Open questions

_(none blocking — requirements gathering complete)_

## Decisions log

- 2026-07-11 — Website carries its own stock (no marketplace cross-listing) → overselling
  risk removed for v1; inventory handling is manual retire-on-sale.
- 2026-07-11 — Recommend embedded buy buttons + Stripe Payment Links (primary) with PayPal
  alternative, over a hosted storefront or a monthly-fee platform.
- 2026-07-11 — Recommend a data-driven Jekyll product structure to keep v1 simple and enable
  automated listing later. _(proposed — awaiting sign-off before planning)_
- 2026-07-11 — Shopify Starter (£5/mo + 5% per sale) rejected for v1: dearer than £0 Stripe
  both monthly and per sale, and does not unlock marketplace sync.
- 2026-07-11 — A catalogue hub for cross-posting (Shopify Basic + Marketplace Connect, or a
  dedicated multichannel lister) deferred to phase 2, to revisit when safely cross-listing the
  unique stock across eBay/Etsy becomes the goal.
- 2026-08-08 — Phase 4a (sold-state reconciler) built: a scheduled Action reads Stripe's active
  payment links and rewrites `status:` for anything that has sold. Brought forward ahead of the
  remaining Phase 2/3 work because it was the only piece buildable without operator account setup.
  It refreshes the label only — oversell protection stays provider-side. Spec + as-built notes:
  `.plans/sold-state-reconciler-v1.md`.
- 2026-07-11 — v1 signed off: Stripe primary + PayPal alternative + Monzo bank-transfer invoice
  CTA on **every** available item (no high-value gating); catalogue is a Jekyll `_products`
  collection we control; bulk listing via our own script (phase 4); runbook lives in `.docs/`
  (unpublished). Plan written to `.plans/ecommerce-integration-v1.md`.
