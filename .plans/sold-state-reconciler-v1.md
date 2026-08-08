# Sold-state reconciler & webhooks — specification v1

> Drafted by Claude (Opus 4.8). Sits under Phase 4 of `.plans/ecommerce-integration-v1.md`
> (this is the detailed spec for what that plan calls Phase 4a + 4b).
> Created: 2026-08-02.
>
> **Status: Phase 4a built 2026-08-08** (Claude, Opus 5) — `scripts/reconcile_sold.rb` +
> `.github/workflows/reconcile-sold.yml`. Awaiting the operator's one-time setup (restricted
> Stripe key → `STRIPE_SECRET_KEY` secret) before its first real run. Phase 4b not started.
> Where the build departs from the sketch below, see **"As built"** at the end.

## Purpose

Keep each product's `status:` front matter in sync with the real state at the payment provider,
so the shop shows an item as **sold** reasonably soon after it sells — on a static GitHub Pages
site with **no backend the operator runs** and **no risk of oversell**.

## What this is NOT for (read first — it sets the stakes)

**Money-safety is already handled provider-side and does not depend on this system:**

- **Stripe one-offs:** the Payment Link has a **1-use cap** (`restrictions.completed_sessions.limit
  = 1`). Once used, Stripe **auto-deactivates the link** (`active` → `false`); a second buyer hits
  "this link is no longer active". Repeatable lines self-close the same way at their total-uses cap.
- **PayPal (repeatable lines only, per policy):** hosted button with **inventory tracking +
  `allow_over_sell:false`** self-closes at zero stock and redirects to `sold_out_url`.

So a second buyer is blocked **at the provider** regardless of what the cached static page still
shows. **The stale page label is cosmetic lag, not an oversell risk.** This reconciler improves the
*freshness of the label*; it is not the thing that protects your money. That is why it can be
eventually-consistent and simple.

**Explicitly out of scope (and why):**

- **Cross-provider mutual deactivation** — dropped, because the policy makes one-offs
  **single-provider (Stripe)**, so no unique unit is ever live on two checkouts at once. There is no
  cross-provider oversell race left to mitigate. (It was considered; see the plan's decision log.)
- **Quantity decrement for repeatable lines** — the provider `active` flag flips only at **full**
  sell-out (the cap), not on each partial sale. Per-sale stock decrement stays **manual** (runbook).
  A future v2 could reconcile remaining stock; v1 handles the boolean available↔sold only.
- **PayPal one-off reconciliation** — none exist by policy (the `gg-0001` PayPal item is a
  deliberate demo exception). PayPal has no clean *official* read of no-code-button inventory, so we
  do not attempt to poll it; the repeatable-line PayPal case is covered by webhook (4b) if wanted.

## Core design: one idempotent reconciler, two triggers

The trap in "belt-and-braces" is two code paths that both write `status:` and can disagree. Avoid it
by making the **provider's API the single source of truth**, wrapped in one idempotent operation:

```
reconcile():
  active = set of Stripe Payment Link URLs currently active   # provider truth
  for each _products/*.md with a stripe_url:
     should_be = (stripe_url in active) ? current : 'sold'
     if file.status != should_be:
        set status: sold, quantity: 0
        stage change
  if any change staged: commit + push   # Pages rebuild follows
```

Idempotent (re-deriving the same truth is a no-op), and it **reads truth then writes derived
state**, so duplicate / out-of-order / missed triggers are all harmless. Then:

- **Trigger 1 — scheduled Action (Phase 4a):** runs `reconcile()` on a cron. Baseline correctness,
  bounded staleness. Ships first, on its own.
- **Trigger 2 — provider webhook (Phase 4b, optional):** on a sale event, fires the **same**
  `reconcile()` via `repository_dispatch`. A low-latency *trigger*, not a second writer. Add only if
  the cron interval's lag proves too slow in practice.

---

## Phase 4a — scheduled reconciler

### The reconcile script

Recommend **Ruby** (matches the repo — Jekyll already brings Ruby; front matter is YAML; the Stripe
call is a single REST GET, so no SDK/Node toolchain needed). Node is a fine alternative if preferred.

**Mapping the committed `stripe_url` to provider state — important detail.** The committed URL is
`https://buy.stripe.com/<shortcode>`; the `<shortcode>` is **not** the `plink_…` id the official API
keys on. Rather than store ids, **list active links and match by URL**:

```
GET https://api.stripe.com/v1/payment_links?active=true&limit=100   (paginate on has_more)
   → each object has { url: "https://buy.stripe.com/<shortcode>", active: true }
```

Build the set of active `url`s. Any product whose `stripe_url` is **absent** from that set is sold
(its link was deactivated → it dropped out of the `active=true` list). One or two API calls total,
no per-product lookups, no extra front-matter fields.

Sketch (`scripts/reconcile_sold.rb`):

```ruby
require 'net/http'; require 'json'; require 'yaml'
KEY = ENV.fetch('STRIPE_SECRET_KEY')          # restricted key, PaymentLinks:read
DRY = ENV['DRY_RUN'] == '1'

def stripe_get(path)
  uri = URI("https://api.stripe.com/v1/#{path}")
  req = Net::HTTP::Get.new(uri); req.basic_auth(KEY, '')
  JSON.parse(Net::HTTP.start(uri.host, 443, use_ssl: true) { |h| h.request(req) }.body)
end

# 1. Collect all ACTIVE payment-link URLs (paginate).
active = []; params = 'payment_links?active=true&limit=100'
loop do
  page = stripe_get(params)
  active.concat(page['data'].map { |pl| pl['url'] })
  break unless page['has_more']
  params = "payment_links?active=true&limit=100&starting_after=#{page['data'].last['id']}"
end
active = active.to_set

# 2. Derive status per product; rewrite only on change.
changed = []
Dir['_products/*.md'].each do |path|
  raw = File.read(path)
  fm  = YAML.safe_load(raw.split(/^---\s*$/, 3)[1])
  url = fm['stripe_url'].to_s.strip
  next if url.empty?                            # no Stripe link → not our concern (see coverage)
  sold = !active.include?(url)
  next unless sold && fm['status'] != 'sold'    # idempotent: only when it actually flips
  changed << fm['sku']
  next if DRY
  body = raw.sub(/^status:.*$/, 'status: sold').sub(/^quantity:.*$/, 'quantity: 0')
  File.write(path, body)
end
puts changed.empty? ? 'no changes' : "marked sold: #{changed.join(', ')}"
```

(Front-matter rewrite kept to a minimal `sub` so comments/formatting survive; harden the regex or use
a front-matter library when implementing.)

### The workflow — `.github/workflows/reconcile-sold.yml`

```yaml
name: Reconcile sold state
on:
  schedule:
    - cron: '*/15 * * * *'        # ~15 min; GitHub's floor is 5 min and runs can be delayed
  workflow_dispatch:               # manual run / testing
  repository_dispatch:
    types: [reconcile]             # fired by the Phase 4b webhook
concurrency:
  group: reconcile-sold            # never let two runs race on the commit
  cancel-in-progress: false
permissions:
  contents: write                  # commit status changes with the built-in GITHUB_TOKEN
jobs:
  reconcile:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with: { ruby-version: '3.3' }
      - run: ruby scripts/reconcile_sold.rb
        env:
          STRIPE_SECRET_KEY: ${{ secrets.STRIPE_SECRET_KEY }}
      - name: Commit if changed
        run: |
          git config user.name  "reconcile-bot"
          git config user.email "actions@users.noreply.github.com"
          if ! git diff --quiet -- _products; then
            git add _products
            git commit -m "chore(shop): reconcile sold state from Stripe"
            git push
          fi
```

The push to `main` triggers the existing `jekyll.yml` build → the shop page updates.

### Secrets & least privilege

- **`STRIPE_SECRET_KEY`** → GitHub **Actions secret** (repo or a protected environment). **Never**
  committed (L2). Use a **restricted key** scoped to **`PaymentLinks: read`** only — the reconciler
  never writes to Stripe (Stripe already did the deactivation we're detecting).
- **`GITHUB_TOKEN`** (built-in) with `contents: write` — enough to commit on the same repo; no PAT.

### Coverage & limitations (state them honestly in the runbook)

| Case | Covered by 4a? | Notes |
|------|:---:|-------|
| Stripe one-off sold out | ✅ | link `active:false` → dropped from active list → `status: sold` |
| Stripe repeatable fully sold out (cap hit) | ✅ | same mechanism at the total-uses cap |
| Stripe repeatable partial stock | ❌ | `active` flips only at full sell-out; decrement stays manual |
| PayPal repeatable | ❌ (4a) | needs webhook (4b); no official inventory read |
| PayPal one-off | n/a | none by policy (gg-0001 is a demo exception) |
| Oversell (money) | independent | provider self-close, not this system |

**Staleness:** worst case ≈ one cron interval (~15 min; GitHub may delay scheduled runs under load).

### Ready-made first test

The demo's `gg-0002` Stripe link (`buy.stripe.com/…43S01`) is **already deactivated** — the operator
test-paid it, and it now returns `payment_link_deactivated`. Yet the committed page still shows
`status: available`. So the **first run of the reconciler should flip `gg-0002` → sold** with no other
setup. Use it as the acceptance test (`DRY_RUN=1` first to preview, then a real `workflow_dispatch`).

---

## Phase 4b — webhook trigger (optional, deferred)

Add only if ~15-min staleness is too slow. It does **not** change the reconciler; it just fires it
sooner. It stays non-safety-critical: if the webhook path breaks entirely, the cron still catches up.

### Shape

```
Stripe 'checkout.session.completed'  ─┐
PayPal 'PAYMENT.CAPTURE.COMPLETED'   ─┤→  Cloudflare Worker (free)
                                        │     • verify provider signature
                                        │     • POST /repos/OWNER/REPO/dispatches
                                        │       { event_type: "reconcile" }
                                        └→  → Action runs reconcile() (seconds)
```

The Worker is a **dumb trigger**: it does not parse which SKU sold or write any state — it just says
"something changed, go reconcile", and the reconciler re-derives truth. That keeps one writer.

### Receiver options

- **Cloudflare Worker** (recommended) — free tier, HTTPS endpoint, tiny. Or **AWS Lambda Function
  URL** (aligns with AM's AWS-first default) — either is ~£0 at this volume.

### Security (must-haves)

- **Verify the provider signature before dispatching.** Stripe: check the `Stripe-Signature` header
  against the endpoint's **signing secret** (reject otherwise) — else anyone can POST your Worker and
  spam GitHub dispatches. PayPal: verify via its webhook-verification API / signature.
- **Secrets live in the Worker's env, never in the repo:** the Stripe/PayPal signing secrets and a
  **fine-scoped GitHub token** (a GitHub App installation token or a PAT limited to `repository_dispatch`
  / `contents` on this one repo). Rotate on leak.
- Ignore/return 2xx quickly for unrelated event types (don't dispatch on everything).

### PayPal note

PayPal webhooks are the **only** automated signal for repeatable-line PayPal sales (there's no clean
official inventory read to reconcile against). Because one-offs are Stripe-only, PayPal 4b is
low-priority — implement it only when a repeatable line is actually dual-listed and the lag matters.

---

## As built (Phase 4a, 2026-08-08)

The shipped script follows the design above — list active links, match by URL, derive, rewrite only
on a flip — with these changes, each of which came out of building or testing it:

1. **The built-in `GITHUB_TOKEN` cannot trigger workflows.** GitHub deliberately does not fire
   workflows for anything it does, so a push to `main` left `jekyll.yml`'s `on: push` silent and the
   shop never rebuilt. **This was the one defect in the spec that would have made the feature
   silently useless.** The first fix was an explicit `gh workflow run jekyll.yml`; superseded by the
   PR flow below, where the merge is performed by a GitHub App whose token *does* trigger `on: push`.
2. **Empty-active-set guard.** A key pointed at the wrong Stripe account returns a successful,
   empty list — which the naive derive reads as "everything sold" and commits, with no automatic
   way back. The script refuses when the active set is empty while products still reference links,
   unless `ALLOW_EMPTY_ACTIVE=1` (a checkbox on manual runs, for a real full sell-out).
3. **URL normalisation** before comparison: scheme+host+path, lowercased, query/fragment and any
   trailing slash dropped — so a `stripe_url` carrying a prefill parameter still matches.
4. **Front-matter rewrite preserves inline comments and their column**, and only matches keys at
   column 0, so nested `details:`/`images:` entries can never be hit. Verified against the real
   product files.
5. **Never resurrects.** Explicit: a re-activated link does not flip a `sold` item back to
   available. Re-listing stays a human act.
6. **`exclude: [scripts/]`** added to `_config.yml` — Jekyll would otherwise copy the script into
   `_site` and publish it.
7. **Missing key is a no-op, not a failure.** The cron lands on `main` before the operator has
   created the Stripe key; failing every 15 minutes would mail them round the clock. Unset
   `STRIPE_SECRET_KEY` → log and exit 0. A *bad* key still fails loudly (verified: 401).
8. Entry point guarded by `if __FILE__ == $PROGRAM_NAME`, and `reconcile()` takes its glob,
   key, active-set and flags by injection — so the tests drive it without a network or the
   real catalogue, and without patching constants. (`run` was the original name; it collides
   with `Minitest::Test#run`.)

### Tests and the CD gate (added same day)

The reconciler writes to the repo unattended, so it should not be able to ship a regression.
`ruby test/all.rb` — 32 cases, stdlib minitest, no gems, no network — covers the reconciler's
behaviour and validates the committed catalogue (see the main plan's "Verification approach").

Three places enforce it:

| Where | What it stops |
|-------|---------------|
| `ci.yml` called by `jekyll.yml` (`build` needs `test`) | a regression reaching the live site |
| `ci.yml` on `pull_request` | a broken catalogue or site build surviving the go-live PR |
| Test steps inside `reconcile-sold.yml`, before **and** after the rewrite | a red suite touching a product file; a bad rewrite being committed |

The reconciler needs its own gate rather than relying on the deploy one: it runs whatever is on
`main` every 15 minutes, including a change pushed straight there, which the deploy gate would
block from *shipping* but could not stop from *running*.

### The reconciler raises a PR rather than pushing (2026-08-08, superseding the direct push)

The gaps in the direct-push design were that the bot's own commits reached `main` without facing
any of the checks a human's would, and that its output was only ever validated by the reconciler
itself. It now commits to a bot-owned branch, opens (or updates) a PR, and enables auto-merge, so
`ci.yml` gates its writes exactly as it gates ours.

What makes this work, and what it costs:

- **It needs a GitHub App.** `GITHUB_TOKEN` cannot trigger workflows, so a PR it opened would sit
  with checks pending forever and never merge — the same rule that broke the original build
  trigger, in a new place. `actions/create-github-app-token@v3` mints a one-hour installation
  token (Contents + Pull requests, read/write); a fine-grained PAT in `RECONCILE_PAT` is the
  fallback. **This is the real price of the design: a credential to create and hold.**
- **The explicit Pages dispatch is gone.** An App/PAT merge is a genuine push by a real identity,
  so `jekyll.yml`'s `on: push` fires by itself.
- **Fixed branch `reconcile/sold-state`, force-pushed, rebuilt from `main` each run.** Repeat sales
  update the one PR instead of spawning a queue of them, and a stale branch can never accumulate.
- **Failure modes are deliberately asymmetric.** No App/PAT while an item has sold → hard error
  (an actionable problem). Auto-merge unavailable → warning only, PR left open; the alternative is
  96 failure emails a day for a setting the operator can fix at leisure.
- **Required approvals must be 0** on the ruleset, or the bot's PR waits on a human that will
  never come — which defeats the automation while looking like it is working.
- **Self-healing.** The reconciler re-derives from Stripe every run, so closing its PR, or a
  transient failure, changes nothing: the next run reopens the same state.

Verified locally as far as it can be without GitHub: workflow YAML parses, every `run:` block
passes `bash -n`, and the PR step was executed against a stubbed `gh` and a local bare remote
across four paths — no PR open (creates one), PR already open (reuses it, no duplicate), auto-merge
refused (warns, exit 0), and no token while changes exist (errors, exit 1).

Each test was checked against a deliberate mutation (never-resurrect guard removed, empty-active
guard removed, URL normalisation dropped, catalogue field corrupted, secret-shaped string committed)
to confirm it actually goes red. The first attempt at the never-resurrect test did **not** — it
asserted a case the guard was not responsible for; it was rewritten until the mutation failed it.

Untested until the operator supplies a key: the live Stripe call and pagination, the commit/push,
and the build trigger.

## Rollout

1. **4a first.** Add `scripts/reconcile_sold.rb` + the workflow + the restricted Stripe key. Validate
   with `DRY_RUN=1`, then the `gg-0002` acceptance test. Live with the cron; measure real staleness.
2. **4b only if needed.** Stand up the Worker for low latency once 4a's lag proves annoying. Stripe
   first; PayPal only for dual-listed repeatable lines.
3. Update `.docs/shop-runbook.md` to note the reconciler exists, its coverage table, and that manual
   `status: sold` edits are still the fallback (and still needed for partial repeatable-stock changes).

## Failure modes

| Failure | Caught by | Max staleness |
|---------|-----------|---------------|
| Webhook down / event missed (4b) | cron (4a) | one cron interval |
| Cron alone (no 4b) | — | one cron interval |
| Both healthy | — | seconds (webhook), cron as ceiling |
| Reconciler script errors | next scheduled run | one cron interval; Actions logs the failure |
| Stripe API down/rate-limited | next run (no partial writes — commit only on clean derive) | one interval |

Because every path converges on the same idempotent, derive-from-truth reconcile, **no failure here
can cause an oversell** — the worst outcome is a stale label until the next successful run.
