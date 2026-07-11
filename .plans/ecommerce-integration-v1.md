# E-commerce integration — v1 implementation plan

Status: **Planned** (awaiting go-ahead to implement)
Created: 2026-07-11
Supporting investigation: `.investigations/ecommerce-integration.md`
Repo: glass-goblin (static Jekyll site on GitHub Pages)

## Objective

Add passive product sales to the static Glass Goblin site at **£0/month**, lowest per-sale fee,
no backend, no change to free GitHub Pages hosting. Catalogue shape is ours to control.

## Decisions this plan implements

- Checkout: **embedded buy buttons** on Jekyll product pages, hosted checkout off-site.
- Payments: **Stripe Payment Links (primary)** + **PayPal (alternative)** on every item.
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

### Phase 0 — Data model and config
- [ ] Add the `products` collection + defaults to `_config.yml`.
- [ ] Create one real sample product file in `_products/` to build against.
- [ ] Add `assets/products/` for product images.
- **Done when:** `bundle exec jekyll build` succeeds and the sample product renders at
  `/shop/<sku>`.

### Phase 1 — Templates and styling
- [ ] `_layouts/product.html` — image(s), title, price, condition, description body, the
      buy-buttons include, and the existing Royal Mail shipping note.
- [ ] Rework `pages/shop.md` into a **grid listing** iterating `site.products`: card per item
      (image, title, price, status), linking to the product page. Show sold items as "Sold"
      (or filter them out — see retire workflow).
- [ ] `_includes/buy-buttons.html` — conditional rendering:
      - `status: sold` → "Sold" badge, no buttons.
      - available → Stripe button (primary) + PayPal button (alternative) + a "Pay by bank
        transfer — request an invoice" CTA linking to the Contact page / a `mailto:` prefilled
        with SKU + title. The invoice CTA shows on every available item.
- [ ] SCSS: product grid, cards, buttons, sold badge — **classes only, colours from
      `_variables.scss`**; add new colour variables if needed.
- [ ] Confirm the Shop nav entry in `_data/navigation.yml` points at the listing.
- **Done when:** shop grid and a product page render correctly; buttons appear/hide per
      `status`; all three purchase options show on available items.

### Phase 2 — Payment wiring and runbook
- [ ] **Stripe:** create a product/price per item, create a Payment Link, enable shipping-address
      collection, and for one-offs **limit the link to 1 use** so it cannot be bought twice.
      Paste the URL into `stripe_url`.
- [ ] **PayPal:** create a hosted button (or PayPal.me link); paste into `paypal_url`.
- [ ] **Invoice route:** wire the CTA to the seller's contact/enquiry so a Monzo invoice can be
      issued manually.
- [ ] Write a short **runbook** in `.docs/` (dot-folder, not published) covering: list an item,
      mark it sold, and issue an invoice.
- **Done when:** a test purchase through Stripe and through PayPal each reach a working hosted
      checkout for a live product, and the invoice CTA produces a correctly prefilled enquiry.

### Phase 3 — Go-live and retire/sold workflow
- [ ] Define the **retire-on-sale** step: set `status: sold` (keeps page for SEO/history) or
      delete the file, **and deactivate the Stripe link**. Record in the runbook.
- [ ] Go-live checklist: build clean, links use `relative_url`, images optimised, prices/currency
      correct, sold items handled, mobile layout of the grid checked.
- **Done when:** the shop is live on `main` (GitHub Pages deploy) with at least the real sample
      item purchasable end-to-end.

### Phase 4 — Deferred (not v1)
- Bulk-listing **script**: reads a source (CSV/inline) and, per item, creates a Stripe product +
  Payment Link via the Stripe API, then writes the `_products/<sku>.md` file. The v1 file shape
  above is designed so this is a clean add.
- **Cross-posting hub** (Shopify Basic + Marketplace Connect, or a multichannel lister) — see the
  investigation's phase-2 analysis; revisit when safely cross-listing unique stock is the goal.

---

## Fees recorded (verify before go-live)

| Route | Per-sale cost (approx UK) | Notes |
|-------|---------------------------|-------|
| Stripe Payment Link | ~1.5% + 20p | Primary; lowest card fee, £0/month, no product cap. |
| PayPal button | ~2.9% + fixed | Alternative for buyer preference. |
| Monzo invoice (bank transfer) | ~£0 | Offered on every item; manual, no buyer card protection. |

## Verification approach

Repo has no test suite/linter by design (personal static site). Verify each phase with
`bundle exec jekyll build` / `serve` plus a visual check of the shop grid, a product page, the
sold state, and the invoice CTA. Optional: add HTML link-checking later if desired.

## Open items before implementing

_(none — ready to implement)_
