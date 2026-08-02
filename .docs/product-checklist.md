# Per-item Phase 2 wiring checklist

> Drafted by Claude (Opus 4.8). Copy the template block for each product you wire up.
> Full detail and the "why" behind each step are in `shop-runbook.md`.

## Template — copy per item

### `<sku>` — <title>
- [ ] Photos in `assets/products/<sku>-*.jpg`
- [ ] `_products/<sku>.md` fields set: title, **real price (GBP)**, status, quantity, category, tags, description
- [ ] **Stripe** — Product + Price (GBP), Payment Link, shipping-address collection ON, postage bound to charge
  - [ ] One-off → 1-use cap, adjustable-qty OFF, fixed qty = 1 (H2)
  - [ ] Repeatable → adjustable qty ON (max = stock), total-uses cap ≈ stock; re-cap on restock (H3)
  - [ ] `stripe_url` pasted (public link only — **never** the secret key, L2)
- [ ] **PayPal** — *repeatable lines only* (one-offs are Stripe-only, see policy): server-side
      hosted button (not amount-in-form / PayPal.me, C1), inventory tracking + over-sell OFF; `paypal_url` pasted
- [ ] **Invoice** button produces a correctly prefilled enquiry (title + SKU)
- [ ] **Test purchase** — one-off: Stripe only; repeatable: Stripe *and* PayPal — price, currency, item match the page (M1, M2)
- [ ] Committed + pushed

## Current catalogue — wiring status (as of 2026-07-20)

Prices marked `*` are placeholders and need real figures before go-live.

| SKU | Title | Type | Price | Stock | Stripe | PayPal | Notes |
|-----|-------|------|-------|-------|:------:|:------:|-------|
| gg-0001 | Upcycled vintage tiara | one-off | £45.00 | 1 | ☐ | demo | **off-policy demo:** on PayPal to validate the one-off PayPal path; switch to Stripe-only at go-live |
| gg-0002 | Green half-eternity ring | one-off | £32.00* | 1 | ☐ | ☐ | placeholder price; photo shows both rings |
| gg-0003 | Aurora borealis half-eternity ring | one-off | £36.00* | 1 | ☐ | ☐ | placeholder price; photo shows both rings |
| b025 | Blue bicolour beads (6 mm) | repeatable | £0.20 | 100 | ☐ | ☐ | per-bead; adjustable qty |
| b030 | Vaseline firepolished (8 mm) | repeatable | £0.25 | 45 | ☐ | ☐ | per-bead; adjustable qty |
| b020 | Opalescent teacup (5 mm) | repeatable | £0.10 | 75 | ☐ | ☐ | per-bead; adjustable qty |
| b016 | Vaseline firepolished (3 mm) | repeatable | £0.09 | 200 | ☐ | ☐ | per-bead; adjustable qty |
| b015 | Vaseline firepolished (4 mm) | repeatable | £0.08 | 50 | ☐ | ☐ | per-bead; adjustable qty |

Mark ☑ under Stripe/PayPal once the link is created and pasted into the `.md` and test-purchased.
