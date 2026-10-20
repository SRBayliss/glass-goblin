# Full test pass — CSV to Stripe to sold

> Drafted by Claude (Opus 5). Do this once, in order, when you have the Stripe credentials.
> It proves the whole chain end to end: a CSV row becomes a Stripe listing and a page on the
> site, someone buys it, and the site takes it off sale by itself.
>
> Setup detail for each individual piece lives in `shop-runbook.md`. This is the order to do
> them in, and what to look for at each step.

Everything in the repo is built and tested. Nothing in it has ever run against a real Stripe
account, so this pass is where the untested boundaries get exercised: the live Stripe calls, the
commit and push, the PR, the auto-merge, and the Pages rebuild.

**Budget about two hours**, most of it waiting. Stage 1 costs nothing.

---

## Read this first — three things that will bite

**1. Mixing Stripe modes will mark your whole shop sold.**

The reconciler lists *active payment links* and marks any product whose link is missing from that
list as sold. Test-mode and live-mode links are completely separate universes. So if
`STRIPE_SECRET_KEY` is a **test**-mode key while products carry **live** links, every one of those
products looks deactivated and gets marked sold.

The empty-active guard does **not** save you here. It only fires when the active list is
*completely* empty. One active test link is enough to let the guard pass and everything else be
marked sold. And the reconciler never resurrects — unmarking is manual, item by item.

**Rule: the mode of `STRIPE_SECRET_KEY` must match the mode of every committed `stripe_url`.**
Stage 0 below exists to make that true before anything is switched on.

**2. The scheduled reconcile is currently disabled, and the cron is far slower than documented.**

`Reconcile sold state` is in state `disabled_inactivity` — GitHub switched it off, so it is not
running at all right now. Worse, the run history shows that while it *was* enabled, the `*/15`
cron actually fired roughly **every 3 to 7 hours**:

```
20:45 → 01:37 → 08:07 → 15:07 → 20:16 → 23:56 → 04:02 → 11:02
 4.9h    6.5h    7.0h    5.2h    3.7h    4.1h    7.0h
```

GitHub heavily deprioritises scheduled workflows on free public repositories. So the "worst case
≈ 15 minutes" in the spec is wrong in practice: **plan for a sold item showing as available for
several hours.** If that is not acceptable, Stage 3 (the webhook) stops being optional.

**3. Nothing is configured yet.** The repo has no Actions secrets and no variables. The ruleset
and auto-merge are done; everything else in the runbook's one-time setup is not.

---

## What you need to have

| # | Credential | Where it lives | Scope | For |
|---|------------|----------------|-------|-----|
| 1 | `STRIPE_WRITE_KEY` | your shell, local only | Products **write**, Prices **write**, Payment links **write** | `bulk_list.rb` |
| 2 | `STRIPE_SECRET_KEY` | Actions secret | Payment links **read** only | the reconciler |
| 3 | GitHub App *or* `RECONCILE_PAT` | Actions variable + secret, or one secret | Contents + Pull requests, read/write | the reconciler's PR |
| 4 | *(Stage 3 only)* Worker PAT + `whsec_…` | Cloudflare Worker secrets | Contents read/write | the webhook |

Keys 1 and 2 are deliberately different keys. Never give the Actions secret write scope — it is
held by an unattended cron, and it is the one credential in this system that should not be able to
create anything.

---

## Stage 0 — clear the decks (15 min, no credentials needed)

The catalogue is all demo data, and two products carry demo payment links from the old test
account: `gg-0002` (a link that is already dead) and `b030`. Those are mode-and-account landmines
for everything below.

- [ ] Confirm which products still reference a link:
      ```sh
      grep -l "stripe_url: http" _products/*.md
      ```
- [ ] **Blank the `stripe_url` and `paypal_url` on every demo product**, and set them
      `status: sold`, `quantity: 0` if they are not real stock. Leave the files in place —
      they are useful demo content, they just must not claim to be buyable.
- [ ] Re-run the gate: `ruby test/all.rb` → **78 runs, 0 failures**.
- [ ] Commit and push.

**Check:** `grep -l "stripe_url: http" _products/*.md` returns nothing. With no product carrying a
link, the reconciler reports *"No products carry a stripe_url — nothing to reconcile"* and exits
cleanly, whatever key it is given. That is a safe state to switch things on from.

> Losing the `gg-0002` acceptance test is fine — this pass supersedes it, and tests the same
> mechanism against an item you watched being created.

---

## Stage 1 — the whole chain in test mode (about an hour, costs nothing)

Stripe test mode behaves identically to live for everything here. Do the full pass this way
first; the only thing it does not prove is that your live account is configured the same.

### 1.1 Credentials, in this order

- [ ] Stripe → **test mode** → create a restricted key with Products, Prices and Payment links at
      **write**. Export it locally:
      ```sh
      export STRIPE_WRITE_KEY=rk_test_...        # PowerShell: $env:STRIPE_WRITE_KEY = "rk_test_..."
      ```
- [ ] Stripe → **test mode** → create a second restricted key, **Payment links: read** only.
      Add it as the Actions secret — but **do not enable the cron yet**:
      ```sh
      gh secret set STRIPE_SECRET_KEY -R SRBayliss/glass-goblin
      ```
- [ ] Create the GitHub App (runbook step 3–4), or the simpler `RECONCILE_PAT` fallback. Without
      one of these the reconciler **hard-errors** the moment something sells, by design.
- [ ] *(Recommended)* Stripe → Product catalogue → **Shipping rates** → create one, e.g. Royal Mail
      2nd class at £3.50. Note the `shr_…` id. This is what binds postage to the charge (M3).

### 1.2 List an item from a CSV

- [ ] Write `batch.csv` with one throwaway item. Keep it above Stripe's **£0.30 minimum**:
      ```csv
      sku,title,price,quantity,category,tags,subtitle,condition,details,description,paypal_url,shipping_rate
      gg-9001,Test pass item,1.50,1,Glassware,uv-glow,"A real listing used to prove the chain","Good","Piece=One of a kind","Created by the bulk lister during the go-live test pass.",,shr_YOUR_RATE
      ```
- [ ] Drop a photo in as `assets/products/gg-9001-1.jpg` (any image — it proves the gallery path).
- [ ] **Preview. This writes nothing:**
      ```sh
      ruby scripts/bulk_list.rb batch.csv
      ```
      **Expect:** `1 item(s) ready to list` and `gg-9001 … one-off, 1-use cap; shipping rate shr_…`.
      If it says *postage in price*, your `shipping_rate` column did not come through.
- [ ] **Create it for real:**
      ```sh
      ruby scripts/bulk_list.rb batch.csv --apply
      ```
      **Expect:** `listed gg-9001 → https://buy.stripe.com/… (gg-9001.md)`.

**Check in Stripe** (this is the first time these calls have ever run for real):

- [ ] A product `gg-9001` exists, with a **GBP** price of **£1.50**.
- [ ] Its payment link has **"limit to 1 use"** set, **adjustable quantity off**, shipping address
      collection **on**, and the shipping rate attached.

> If the script failed partway, read its report before re-running — it names exactly what was
> created and what was not. A Stripe product left without a file beside it must be deleted in
> Stripe first, because the id is the sku and the next run will collide with it.

### 1.3 Put it on the site

- [ ] `ruby test/all.rb` → **79 runs** now (the new product is validated too), 0 failures.
- [ ] `bundle exec jekyll serve` → check `/shop` shows the card and `/shop/gg-9001` renders with
      the photo, the price, and a **Buy with card** button pointing at the Stripe link.
- [ ] Commit and push. Wait for the deploy to go green:
      ```sh
      gh run list -R SRBayliss/glass-goblin --limit 1
      ```
- [ ] Open the live page on the test site and click through to Stripe. **Confirm the price,
      currency and item on Stripe's checkout match the page** (M1, M2).

### 1.4 Buy it

- [ ] Pay with Stripe's test card `4242 4242 4242 4242`, any future expiry, any CVC.
- [ ] **Confirm the sale in the Stripe dashboard.** The thank-you page is not proof of payment —
      its URL is forgeable (H4). The dashboard is the only thing that counts.
- [ ] In Stripe, check the payment link now shows as **deactivated**. That is the 1-use cap doing
      its job, and it is what actually prevents a second sale — not anything on the website.
- [ ] Try the link again in a browser. You should get *"this link is no longer active"*.

> **At this moment the site still says the item is available.** That is expected and is not an
> oversell risk — a second buyer is already blocked at Stripe. Everything below is only about
> catching the label up.

### 1.5 Let the reconciler notice

Do it by hand first, so you see it work before trusting the schedule.

- [ ] **Dry run** — reports, writes nothing:
      ```sh
      gh workflow run reconcile-sold.yml -R SRBayliss/glass-goblin -f dry_run=true
      gh run list -R SRBayliss/glass-goblin --workflow=reconcile-sold.yml --limit 1
      ```
      **Expect:** `Would mark sold: gg-9001 (DRY_RUN)`.
      - *"STRIPE_SECRET_KEY is not set"* → the secret did not save.
      - *"Refusing to reconcile: Stripe reports zero active payment links"* → wrong account or
        wrong mode. **Stop and fix the key.** Do not use `allow_empty_active` to force past it.
- [ ] **Real run:**
      ```sh
      gh workflow run reconcile-sold.yml -R SRBayliss/glass-goblin
      ```
      **Expect:** `Marked sold: gg-9001`, then a pull request from branch
      `reconcile/sold-state` titled for the sold-state change.

### 1.6 Watch the PR land by itself

This is the part with the most moving pieces, and none of it has run before.

- [ ] The PR exists, and its checks start **on their own**. If they sit pending forever, the App
      or PAT is missing — `GITHUB_TOKEN` cannot trigger workflows, which is the entire reason
      that credential exists.
- [ ] All three required checks pass: **Ruby tests**, **Worker tests**, **Jekyll build**.
- [ ] It **auto-merges** without you touching it. If it waits, check the ruleset still has
      **0 required approvals** — any other number and the bot waits for a human forever.
- [ ] The merge triggers `Deploy Jekyll site to Pages`.
- [ ] The live page `/shop/gg-9001` now says **sold**, shows the Sold badge on the shop grid, and
      offers **no buy buttons**.

- [ ] Finally, confirm it is idempotent — run the workflow once more. **Expect:**
      `Checked N product(s) against M active Stripe link(s): no changes.`

### 1.7 Turn the schedule on and leave it

- [ ] Re-enable the cron, which GitHub has disabled:
      ```sh
      gh workflow enable reconcile-sold.yml -R SRBayliss/glass-goblin
      ```
- [ ] Check back the next day and look at the actual gaps between runs:
      ```sh
      gh run list -R SRBayliss/glass-goblin --workflow=reconcile-sold.yml --limit 10 \
        --json createdAt --jq '.[].createdAt'
      ```
      **This is the number that decides whether you need Stage 3.** If the gaps are hours, as they
      were before, a sold item will sit there looking available for hours.

### 1.8 Clean up before going live

- [ ] Delete `_products/gg-9001.md`, the photo, and `batch.csv`.
- [ ] Delete the `gg-9001` product in Stripe **test mode** (the sku is the id, so leaving it blocks
      re-use of that sku later).
- [ ] Commit and push; confirm the page 404s.

---

## Stage 2 — the live pass (30 min, costs one real sale)

Same chain, real money, one cheap real item. This is what proves your live account is configured
the way your test account was.

- [ ] **Swap both keys to live mode.** Re-create the restricted keys in live mode and replace
      `STRIPE_WRITE_KEY` locally and `STRIPE_SECRET_KEY` in Actions.
      **Both at once** — a live write key with a test read key is the mode-mixing trap from the top
      of this document.
- [ ] Re-create the shipping rate in live mode and use its new `shr_…`.
- [ ] Repeat 1.2 → 1.6 with **one real item at a real price**, bought with a real card. Use
      something genuinely cheap; you are paying yourself minus roughly 1.5% + 20p.
- [ ] Confirm the money arrives in the Stripe balance, and that the payout details are right.
- [ ] Refund yourself if you want the money back. **A refund does not reactivate the payment
      link**, and the reconciler never resurrects — so the item stays sold, which is correct.

**Once this passes, Phase 2 is genuinely done** for that item, and the per-item checklist in
`product-checklist.md` becomes a matter of repeating 1.2 for each real item.

---

## Stage 3 — the webhook, if the cron is too slow (30 min)

Decide this with the real numbers from 1.7 in front of you. Given what the history shows, expect
to need it.

- [ ] Follow "Webhook trigger" in `shop-runbook.md`: PAT, `npx wrangler deploy`, two secrets, and
      a Stripe endpoint subscribed to `checkout.session.completed` and `payment_link.updated`.
- [ ] Use Stripe's **Send test webhook** and confirm a `202` in the delivery log and a
      `Reconcile sold state` run appearing within seconds.
- [ ] Then the real proof: list a second cheap item, buy it, and **time how long** until the live
      page says sold. Seconds, not hours.

---

## What "done" looks like

| Proved | How you know |
|--------|--------------|
| The bulk lister works against real Stripe | A product, price and capped link exist that you did not create by hand |
| The caps are right | The link is dead after one purchase, and the dead link 404s |
| The catalogue gate works | `ruby test/all.rb` green with the generated file in place |
| The reconciler reads Stripe correctly | Dry run names the right sku and nothing else |
| The PR flow works | The PR's checks start by themselves and it auto-merges |
| The site self-updates | `/shop/<sku>` says sold without you editing anything |
| It is safe to re-run | A second reconcile reports "no changes" |
| You know your real staleness | Measured gaps between scheduled runs |

---

## If you need to stop everything

In rough order of bluntness:

```sh
gh workflow disable reconcile-sold.yml -R SRBayliss/glass-goblin   # stop the bot writing
gh secret delete STRIPE_SECRET_KEY -R SRBayliss/glass-goblin       # it then no-ops anyway
gh api -X DELETE repos/SRBayliss/glass-goblin/rulesets/25443801    # drop the branch rules
```

Deactivating a payment link in Stripe is what actually stops a sale. Everything in this repo is
downstream of that, and none of it can oversell anything on its own.
