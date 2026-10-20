// Behaviour tests for the webhook receiver.
//
// Runs on Node's built-in test runner — `node --test` — so there is nothing to install,
// matching the Ruby suite's stdlib-only rule.
//
// Signatures here are generated with node:crypto rather than the Worker's own helper, so
// the Web Crypto implementation is checked against an independent one instead of itself.
// Nothing reaches the network: fetch is injected.

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';

import { handleRequest, constantTimeEqual, parseSignatureHeader } from '../src/index.js';

const SECRET = 'webhook-signing-secret-for-tests';
const NOW = 1_700_000_000;

const ENV = {
  STRIPE_WEBHOOK_SECRET: SECRET,
  GITHUB_TOKEN: 'github-token-for-tests',
  GITHUB_REPOSITORY: 'SRBayliss/glass-goblin',
};

function sign(body, { secret = SECRET, timestamp = NOW } = {}) {
  const digest = createHmac('sha256', secret).update(`${timestamp}.${body}`).digest('hex');
  return `t=${timestamp},v1=${digest}`;
}

function eventBody(type = 'checkout.session.completed') {
  return JSON.stringify({ id: 'evt_123', type, data: { object: { id: 'cs_123' } } });
}

// Records what the Worker tried to send GitHub, and answers with whatever status is asked for.
function stubFetch(status = 204) {
  const calls = [];
  const impl = async (url, options) => {
    calls.push({ url, options });
    return new Response(null, { status });
  };
  return { impl, calls };
}

function post(body, { signature, method = 'POST' } = {}) {
  const headers = new Headers();
  if (signature !== null) headers.set('stripe-signature', signature ?? sign(body));
  return new Request('https://trigger.example/', { method, headers, body: method === 'POST' ? body : undefined });
}

async function run(body, { env = ENV, signature, method, status = 204, nowSeconds = NOW } = {}) {
  const fetchStub = stubFetch(status);
  const response = await handleRequest(post(body, { signature, method }), env, {
    fetch: fetchStub.impl,
    nowSeconds,
  });
  return { response, calls: fetchStub.calls, text: (await response.text()).trim() };
}

describe('accepting a genuine event', () => {
  test('a signed sale dispatches a reconcile and is accepted', async () => {
    const { response, calls, text } = await run(eventBody());

    assert.equal(response.status, 202);
    assert.match(text, /Reconcile requested/);
    assert.equal(calls.length, 1);
  });

  test('the dispatch goes to the right repo with the event type the workflow listens for', async () => {
    const { calls } = await run(eventBody());
    const [{ url, options }] = calls;

    assert.equal(url, 'https://api.github.com/repos/SRBayliss/glass-goblin/dispatches');
    assert.equal(options.method, 'POST');
    assert.deepEqual(JSON.parse(options.body), { event_type: 'reconcile' });
    assert.equal(options.headers.authorization, 'Bearer github-token-for-tests');
    assert.equal(options.headers.accept, 'application/vnd.github+json');
    // GitHub rejects API calls that do not identify themselves.
    assert.ok(options.headers['user-agent']);
  });

  test('a payment link deactivating also triggers a reconcile', async () => {
    const { response, calls } = await run(eventBody('payment_link.updated'));

    assert.equal(response.status, 202);
    assert.equal(calls.length, 1);
  });

  test('a second v1 signature is accepted, so the secret can be rotated', async () => {
    const body = eventBody();
    const genuine = sign(body).split('v1=')[1];
    const signature = `t=${NOW},v1=${'0'.repeat(64)},v1=${genuine}`;

    const { response } = await run(body, { signature });

    assert.equal(response.status, 202);
  });

  test('the raw body is verified, not a re-serialisation of it', async () => {
    // Whitespace and key order survive signing only if the bytes are used as sent.
    const body = '{\n  "type":   "checkout.session.completed",\n  "id": "evt_1"\n}';

    const { response } = await run(body);

    assert.equal(response.status, 202);
  });
});

describe('refusing what it should refuse', () => {
  test('an unsigned request is rejected and dispatches nothing', async () => {
    const { response, calls, text } = await run(eventBody(), { signature: null });

    assert.equal(response.status, 400);
    assert.match(text, /no Stripe-Signature header/);
    assert.equal(calls.length, 0);
  });

  test('a signature from the wrong secret is rejected', async () => {
    const body = eventBody();
    const { response, calls, text } = await run(body, { signature: sign(body, { secret: 'not-the-secret' }) });

    assert.equal(response.status, 400);
    assert.match(text, /does not match/);
    assert.equal(calls.length, 0);
  });

  test('a body altered after signing is rejected', async () => {
    const signature = sign(eventBody());
    const tampered = eventBody('payment_intent.succeeded');

    const { response, calls } = await run(tampered, { signature });

    assert.equal(response.status, 400);
    assert.equal(calls.length, 0);
  });

  test('an old signature is rejected, so a captured request cannot be replayed', async () => {
    const body = eventBody();
    const { response, calls, text } = await run(body, { signature: sign(body, { timestamp: NOW - 3600 }) });

    assert.equal(response.status, 400);
    assert.match(text, /away from now/);
    assert.equal(calls.length, 0);
  });

  test('a signature from the future is rejected too', async () => {
    const body = eventBody();
    const { response } = await run(body, { signature: sign(body, { timestamp: NOW + 3600 }) });

    assert.equal(response.status, 400);
  });

  test('a signature header with no timestamp is rejected', async () => {
    const { response, text } = await run(eventBody(), { signature: `v1=${'a'.repeat(64)}` });

    assert.equal(response.status, 400);
    assert.match(text, /timestamp/);
  });

  test('a signature header with no v1 part is rejected', async () => {
    const { response, text } = await run(eventBody(), { signature: `t=${NOW},v0=whatever` });

    assert.equal(response.status, 400);
    assert.match(text, /no v1 signature/);
  });

  test('a GET is refused without reading anything', async () => {
    const { response, calls } = await run(eventBody(), { method: 'GET' });

    assert.equal(response.status, 405);
    assert.equal(calls.length, 0);
  });

  test('valid signature but junk JSON is rejected', async () => {
    const { response, calls, text } = await run('not json at all');

    assert.equal(response.status, 400);
    assert.match(text, /not JSON/);
    assert.equal(calls.length, 0);
  });
});

describe('events it has no business acting on', () => {
  test('an unrelated event is acknowledged but dispatches nothing', async () => {
    const { response, calls, text } = await run(eventBody('customer.created'));

    assert.equal(response.status, 200);
    assert.match(text, /Ignored customer.created/);
    assert.equal(calls.length, 0);
  });

  test('a signed event with no type is ignored rather than crashing', async () => {
    const { response, calls } = await run(JSON.stringify({ id: 'evt_1' }));

    assert.equal(response.status, 200);
    assert.equal(calls.length, 0);
  });
});

describe('configuration and failure', () => {
  for (const missing of ['STRIPE_WEBHOOK_SECRET', 'GITHUB_TOKEN', 'GITHUB_REPOSITORY']) {
    test(`refuses to run with ${missing} unset`, async () => {
      const env = { ...ENV, [missing]: '' };
      const { response, calls, text } = await run(eventBody(), { env });

      assert.equal(response.status, 500);
      assert.match(text, new RegExp(missing));
      assert.equal(calls.length, 0);
    });
  }

  // Stripe retries on a 5xx, and the cron is the backstop if the retries fail too.
  test('a refused dispatch returns a status Stripe will retry', async () => {
    const { response, text } = await run(eventBody(), { status: 403 });

    assert.equal(response.status, 502);
    assert.match(text, /HTTP 403/);
  });

  test('no response ever contains the GitHub token', async () => {
    const bodies = await Promise.all([
      run(eventBody()),
      run(eventBody(), { status: 403 }),
      run(eventBody(), { signature: null }),
      run(eventBody('customer.created')),
      run(eventBody(), { env: { ...ENV, GITHUB_TOKEN: '' } }),
    ]);

    for (const { text } of bodies) {
      assert.doesNotMatch(text, /github-token-for-tests/);
      assert.doesNotMatch(text, /webhook-signing-secret-for-tests/);
    }
  });
});

describe('helpers', () => {
  test('constantTimeEqual matches only identical strings', () => {
    assert.equal(constantTimeEqual('abc', 'abc'), true);
    assert.equal(constantTimeEqual('abc', 'abd'), false);
    assert.equal(constantTimeEqual('abc', 'abcd'), false);
    assert.equal(constantTimeEqual('abc', undefined), false);
  });

  test('parseSignatureHeader keeps every v1 and ignores noise', () => {
    const parsed = parseSignatureHeader('t=123, v1=aaa, v0=bbb, rubbish, v1=ccc');

    assert.equal(parsed.timestamp, '123');
    assert.deepEqual(parsed.signatures, ['aaa', 'ccc']);
  });

  test('parseSignatureHeader survives an empty or missing header', () => {
    assert.deepEqual(parseSignatureHeader(''), { timestamp: null, signatures: [] });
    assert.deepEqual(parseSignatureHeader(undefined), { timestamp: null, signatures: [] });
  });
});
