# Switching on the sold-state reconciler — your manual steps

> Written by Claude (Opus 5). Lives in `.docs/`, so Jekyll does not publish it.
> Companion to `.docs/shop-runbook.md` (day-to-day operation) and
> `.plans/sold-state-reconciler-v1.md` (why it is built this way).
>
> Everything in the repo is done and pushed. These are the steps only you can do,
> because they need your Stripe and GitHub accounts. **About 25 minutes.**

## What you are switching on

When a Stripe payment link sells out, Stripe deactivates it. Every 15 minutes a GitHub
Action notices, sets that product to `status: sold` in the repo, and opens a pull request.
The PR runs the test suite, merges itself, and the shop rebuilds.

**None of this protects your money** — Stripe already blocks a second buyer at the link.
It only stops the website advertising something that has gone.

Do the steps in order. Sections A and B are enough to switch it on; C makes the pull
request actually mean something.

---

## A. Stripe: a read-only key (~5 min)

The reconciler needs to ask Stripe which links are still active. It never writes to Stripe.

- [ ] **A1.** Stripe Dashboard → make sure you are in **live mode**, not test mode. Your
      payment links are live ones, so a test-mode key would see none of them.
- [ ] **A2.** Developers → API keys → **Create restricted key**.
- [ ] **A3.** Name it `glass-goblin reconciler`. Set **every** permission to *None* except
      **Payment links → Read**. Nothing else. Create it.
- [ ] **A4.** Copy the key — it starts `rk_live_`. You can only see it once.
- [ ] **A5.** GitHub → your repo → **Settings → Secrets and variables → Actions** →
      *Secrets* tab → **New repository secret**.
      Name: `STRIPE_SECRET_KEY` — Value: the key you just copied. Add it.

> ⚠️ That key goes in the GitHub secret and nowhere else. Never in a file, never in the
> repo. If it ever ends up in a commit, roll it in Stripe first, then remove it.

**Check it worked:** Actions tab → **Reconcile sold state** → *Run workflow* → tick
**dry run** → Run. It should finish green and say `Would mark sold: gg-0002`. Nothing has
changed yet — a dry run writes nothing.

*If it says "Refusing to reconcile: Stripe reports zero active payment links" — the key is
probably from the wrong account or test mode. Redo A1–A5. That refusal is deliberate: an
empty list would otherwise read as "the whole shop has sold".*

---

## B. GitHub App: so the bot can raise a pull request (~10 min)

GitHub deliberately refuses to let a workflow's built-in token start other workflows. A
pull request opened with it would sit with its checks pending forever and could never
merge. So the bot needs its own identity.

- [ ] **B1.** GitHub → your profile → **Settings → Developer settings → GitHub Apps** →
      **New GitHub App**.
- [ ] **B2.** Fill in:
      - **GitHub App name:** `glass-goblin reconciler` (names are global — add a suffix if
        taken).
      - **Homepage URL:** `https://www.glassgoblin.co.uk` (required, not used for anything).
      - **Webhook:** untick **Active**. It does not need one.
- [ ] **B3.** **Repository permissions** — grant exactly two, leave everything else *No access*:
      - **Contents:** Read and write
      - **Pull requests:** Read and write
- [ ] **B4.** "Where can this GitHub App be installed?" → **Only on this account**. Create.
- [ ] **B5.** On the App's page, copy the **Client ID** (looks like `Iv23li…`).
- [ ] **B6.** Same page → **Private keys** → **Generate a private key**. A `.pem` file
      downloads. Keep it only until step B9.
- [ ] **B7.** Left menu → **Install App** → your account → **Only select repositories** →
      pick **glass-goblin** → Install.
- [ ] **B8.** Repo → **Settings → Secrets and variables → Actions** → ***Variables* tab** →
      **New repository variable**.
      Name: `RECONCILE_APP_CLIENT_ID` — Value: the Client ID from B5.
      *A variable, not a secret — a Client ID is not sensitive, and the workflow checks it to
      decide whether an App is configured.*
- [ ] **B9.** Same page → ***Secrets* tab** → **New repository secret**.
      Name: `RECONCILE_APP_PRIVATE_KEY` — Value: open the `.pem` in Notepad and paste the
      **whole file**, including the `-----BEGIN` and `-----END` lines. Add it, then
      **delete the downloaded `.pem`** — GitHub has it now, and it is a credential.
- [ ] **B10.** Repo → **Settings → General** → scroll to **Pull Requests** → tick
      **Allow auto-merge**.

> **Simpler alternative to B1–B9** if you would rather not run an App: create a fine-grained
> personal access token (Settings → Developer settings → Personal access tokens →
> Fine-grained), scoped to this repository only, with the same two permissions, and save it
> as a secret named `RECONCILE_PAT`. The workflow falls back to it. It works, but it is
> long-lived and tied to you personally, where the App's token expires after an hour.

**Check it worked:** Actions → **Reconcile sold state** → *Run workflow*, this time with
**dry run unticked**. Expect: the run goes green, a pull request appears titled
*"chore(shop): reconcile sold state from Stripe"* setting `gg-0002` to sold, its checks run,
and it merges itself. The site then rebuilds and `gg-0002` shows as sold in the shop.

That is the whole system working end to end.

---

## C. Make the checks binding (~10 min)

Without this the pull request still opens and merges — but nothing is *stopping* it merging
if the tests fail. This step is what turns it into a real gate.

- [ ] **C1.** Repo → **Settings → Rules → Rulesets** → **New ruleset** → **New branch ruleset**.
- [ ] **C2.** Name it `main protection`. **Enforcement status: Active**.
- [ ] **C3.** **Target branches** → Add target → **Include default branch**.
- [ ] **C4.** **Bypass list** → Add bypass → **Repository admin**.
      *This keeps your own direct pushes to `main` working. The App is deliberately not on
      this list, so the bot's commits still have to go through the checks — which is the
      entire point.*
- [ ] **C5.** Tick **Require a pull request before merging**, and set
      **Required approvals: 0**.
      ⚠️ **It must be 0.** Any higher and the bot's pull request waits for an approval that
      will never come — it would look like it is working while quietly doing nothing.
- [ ] **C6.** Tick **Require status checks to pass**, then **Add checks** and enter:
      - `Ruby tests`
      - `Jekyll build`
      
      Type the names exactly if the search does not offer them; they become selectable once
      they have run on a pull request at least once.
- [ ] **C7.** Leave **Require branches to be up to date before merging** *unticked*. If you
      tick it, a reconcile PR can stall whenever you push to `main` while it is open — it
      clears itself on the next run, but it is needless friction.
- [ ] **C8.** Create.

**Check it worked:** open any small pull request (or wait for the next reconcile one) and
confirm *Ruby tests* and *Jekyll build* are listed as **Required**, and that Merge is
blocked until they pass.

---

## D. One thing to watch on the fork

- [ ] **D1.** GitHub disables scheduled workflows on **forked** repositories by default.
      Open the **Actions** tab; if it offers to enable workflows, do so. Public repos also
      switch a schedule off after 60 days with no activity — any manual run re-arms it.
- [ ] **D2.** After all the above, leave it a while and check the Actions tab shows
      *Reconcile sold state* running on its own roughly every 15 minutes. Delays are normal;
      GitHub queues scheduled runs under load.

---

## What "normal" looks like afterwards

- Most runs do nothing and say `no changes`. That is the expected state.
- When something sells: a pull request appears and closes itself within a few minutes.
- **If a pull request sits open, read it — that is the system stopping something.** Its
  checks failed, or auto-merge is not enabled. See "If a reconcile PR is sitting open" in
  `.docs/shop-runbook.md`.
- It only ever marks things **sold**, never available. Relisting stays a deliberate act.
- It cannot see partial stock on the bead lines, and it cannot see PayPal at all. Those
  stay manual — the coverage table is in the runbook.

## Still outstanding after this (not part of the reconciler)

These are the Phase 2/3 items from `.plans/ecommerce-integration-v1.md`, unchanged:

- Real Stripe Payment Links and PayPal buttons for the items that do not have them, pasted
  into each `_products/*.md`.
- Real prices for `gg-0002` and `gg-0003` — currently placeholders.
- Switch `gg-0001` to Stripe-only (it is on PayPal as a deliberate demo), and remove it from
  the exception list in `test/test_catalogue.rb`.
- Per-item test purchase, then go-live: PR from this fork to `smolpotatoes/glass-goblin`.
