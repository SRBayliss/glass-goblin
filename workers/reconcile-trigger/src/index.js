// Webhook receiver: tells the repo to reconcile, sooner than the cron would.
//
// Spec: .plans/sold-state-reconciler-v1.md (Phase 4b)
// Tests: workers/reconcile-trigger/test/index.test.js — run them before changing anything.
// Setup: .docs/shop-runbook.md ("Webhook trigger").
//
// What it does
//   Stripe posts an event here. If the signature is genuine and the event is one that
//   could have changed what is for sale, this fires a `reconcile` repository_dispatch at
//   GitHub, which runs the same reconcile workflow the cron runs.
//
// What it deliberately does NOT do
//   It does not read which item sold, and it does not decide anything. It says "something
//   changed, go and look" and nothing else. The reconciler re-derives the truth from
//   Stripe either way, so there is exactly one writer and this cannot disagree with it.
//
//   That is also why losing this service is survivable: the cron still catches everything
//   within its interval. This only shortens the wait.

const DISPATCH_EVENT_TYPE = 'reconcile';

// Events worth a look. `checkout.session.completed` is the sale; `payment_link.updated`
// is the link self-deactivating at its cap, which is the signal the reconciler actually
// reads — kept as well as the sale, because it still arrives if the sale event is missed.
const TRIGGER_EVENTS = new Set(['checkout.session.completed', 'payment_link.updated']);

// Stripe's own default. Bounds how long a captured request stays replayable.
const TOLERANCE_SECONDS = 300;

const REQUIRED_CONFIG = ['STRIPE_WEBHOOK_SECRET', 'GITHUB_TOKEN', 'GITHUB_REPOSITORY'];

function text(status, body) {
  return new Response(`${body}\n`, {
    status,
    headers: { 'content-type': 'text/plain; charset=utf-8' },
  });
}

function toHex(buffer) {
  return [...new Uint8Array(buffer)].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

async function hmacHex(secret, message) {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  return toHex(await crypto.subtle.sign('HMAC', key, encoder.encode(message)));
}

// Compares in time independent of how far along the first difference is. Length is
// allowed to leak: both sides are fixed-width hex digests, so it tells an attacker nothing.
export function constantTimeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;

  let difference = 0;
  for (let index = 0; index < a.length; index += 1) {
    difference |= a.charCodeAt(index) ^ b.charCodeAt(index);
  }
  return difference === 0;
}

// `t=1700000000,v1=abc…,v1=def…` — more than one v1 appears while a signing secret is
// being rotated, and either one is legitimate.
export function parseSignatureHeader(header) {
  const signatures = [];
  let timestamp = null;

  for (const piece of String(header ?? '').split(',')) {
    const separator = piece.indexOf('=');
    if (separator === -1) continue;

    const scheme = piece.slice(0, separator).trim();
    const value = piece.slice(separator + 1).trim();

    if (scheme === 't') timestamp = value;
    else if (scheme === 'v1') signatures.push(value);
  }

  return { timestamp, signatures };
}

// The payload must be the exact bytes Stripe sent. Parsing and re-serialising the JSON
// would reorder keys and drop whitespace, and the signature would never match again.
export async function verifyStripeSignature(payload, header, secret, nowSeconds, tolerance = TOLERANCE_SECONDS) {
  if (!header) return { ok: false, reason: 'no Stripe-Signature header' };

  const { timestamp, signatures } = parseSignatureHeader(header);

  if (timestamp === null || !/^\d+$/.test(timestamp)) return { ok: false, reason: 'no usable timestamp' };
  if (signatures.length === 0) return { ok: false, reason: 'no v1 signature' };

  const age = Math.abs(nowSeconds - Number(timestamp));
  if (age > tolerance) return { ok: false, reason: `timestamp is ${age}s away from now` };

  const expected = await hmacHex(secret, `${timestamp}.${payload}`);
  const matched = signatures.some((candidate) => constantTimeEqual(candidate, expected));

  return matched ? { ok: true } : { ok: false, reason: 'signature does not match the body' };
}

async function dispatchReconcile(env, fetchImpl) {
  const response = await fetchImpl(`https://api.github.com/repos/${env.GITHUB_REPOSITORY}/dispatches`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${env.GITHUB_TOKEN}`,
      accept: 'application/vnd.github+json',
      'content-type': 'application/json',
      'x-github-api-version': '2022-11-28',
      // GitHub rejects API requests that do not identify themselves.
      'user-agent': 'glass-goblin-reconcile-trigger',
    },
    body: JSON.stringify({ event_type: DISPATCH_EVENT_TYPE }),
  });

  return { ok: response.status === 204, status: response.status };
}

export async function handleRequest(request, env, deps = {}) {
  const fetchImpl = deps.fetch ?? globalThis.fetch;
  const nowSeconds = deps.nowSeconds ?? Math.floor(Date.now() / 1000);

  if (request.method !== 'POST') return text(405, 'Send a POST.');

  // Checked before anything else touches the request: a receiver that cannot dispatch
  // should say so plainly rather than accept webhooks and drop them.
  const missing = REQUIRED_CONFIG.filter((name) => !env?.[name]);
  if (missing.length > 0) return text(500, `Receiver is misconfigured: ${missing.join(', ')} not set.`);

  const body = await request.text();
  const verified = await verifyStripeSignature(
    body,
    request.headers.get('stripe-signature'),
    env.STRIPE_WEBHOOK_SECRET,
    nowSeconds,
  );

  // Without this check anyone who finds the URL can make the repo run a workflow at will.
  if (!verified.ok) return text(400, `Rejected: ${verified.reason}.`);

  let event;
  try {
    event = JSON.parse(body);
  } catch {
    return text(400, 'Rejected: body is not JSON.');
  }

  const type = typeof event?.type === 'string' ? event.type : null;
  if (!TRIGGER_EVENTS.has(type)) return text(200, `Ignored ${type ?? 'an event with no type'}.`);

  const dispatched = await dispatchReconcile(env, fetchImpl);

  // Deliberately a failure Stripe will retry. The cron covers the gap if the retries also
  // fail, so the worst case here is ordinary staleness rather than a missed sale.
  if (!dispatched.ok) return text(502, `GitHub refused the dispatch (HTTP ${dispatched.status}).`);

  return text(202, 'Reconcile requested.');
}

export default {
  fetch: (request, env) => handleRequest(request, env),
};
