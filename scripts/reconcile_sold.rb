#!/usr/bin/env ruby
# frozen_string_literal: true

# Reconcile each product's sold state against Stripe.
#
# Spec: .plans/sold-state-reconciler-v1.md (Phase 4a)
# Tests: test/test_reconcile_sold.rb — run them before changing anything here.
#
# What it does
#   1. Asks Stripe for every payment link that is currently active.
#   2. For each _products/*.md that carries a stripe_url, checks whether that URL is
#      still in the active set. If it is not, Stripe has deactivated the link — the
#      item has sold out — so the file is rewritten to `status: sold`, `quantity: 0`.
#
# What it deliberately does NOT do
#   - It never flips an item back to available. Stripe is the source of truth for
#     "sold out"; re-listing is a human decision (new link, restock, re-cap).
#   - It never writes to Stripe. The key it needs is read-only.
#   - It does not track partial stock on repeatable lines: a link's `active` flag only
#     flips at the total-uses cap, not on each sale. Per-sale decrement stays manual.
#
# Environment
#   STRIPE_SECRET_KEY    restricted key, PaymentLinks:read only. Unset → the run no-ops
#                        rather than failing, so the cron stays quiet until it is configured.
#   DRY_RUN=1            report what would change; write nothing.
#   ALLOW_EMPTY_ACTIVE=1 permit the "Stripe reports zero active links" case (see below).
#
# Exit codes
#   0  ran clean (with or without changes)
#   1  refused to act, or the Stripe call failed — nothing was written

require 'json'
require 'net/http'
require 'set'
require 'uri'
require 'yaml'

DEFAULT_PRODUCTS_GLOB = File.expand_path('../_products/*.md', __dir__)
STRIPE_API = 'https://api.stripe.com/v1/'
PAGE_SIZE = 100

class ReconcileError < StandardError; end

# --- Stripe ------------------------------------------------------------------

# Nil when unconfigured. A scheduled run every 15 minutes should not mail the operator a
# failure until they have got round to creating the key; see reconcile().
def stripe_key
  key = ENV['STRIPE_SECRET_KEY'].to_s.strip
  key.empty? ? nil : key
end

def stripe_get(path, key)
  uri = URI.join(STRIPE_API, path)
  request = Net::HTTP::Get.new(uri)
  request.basic_auth(key, '')

  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) do |http|
    http.request(request)
  end

  body = begin
    JSON.parse(response.body.to_s)
  rescue JSON::ParserError
    {}
  end

  unless response.is_a?(Net::HTTPSuccess)
    detail = body.dig('error', 'message') || response.message
    raise ReconcileError, "Stripe returned #{response.code}: #{detail}"
  end

  body
end

# Every payment link Stripe currently considers active, as a set of normalised URLs.
# A link that has hit its completed-sessions cap self-deactivates and drops out of here.
def active_payment_link_urls(key)
  urls = Set.new
  path = "payment_links?active=true&limit=#{PAGE_SIZE}"

  loop do
    page = stripe_get(path, key)
    data = page['data'] || []
    data.each { |link| urls << normalise_url(link['url']) }

    break unless page['has_more'] && !data.empty?

    path = "payment_links?active=true&limit=#{PAGE_SIZE}&starting_after=#{data.last['id']}"
  end

  urls.delete(nil)
  urls
end

# Compare on the bare link, ignoring anything a prefill or tracking param may have added.
def normalise_url(url)
  text = url.to_s.strip
  return nil if text.empty?

  uri = URI.parse(text)
  "#{uri.scheme}://#{uri.host}#{uri.path.chomp('/')}".downcase
rescue URI::InvalidURIError
  text.downcase
end

# --- Product files -----------------------------------------------------------

FRONT_MATTER = /\A(---[ \t]*\r?\n)(.*?\r?\n)(---[ \t]*\r?\n)/m

# opener/closer are kept verbatim so a file's line endings survive a rewrite untouched.
Product = Struct.new(:path, :fields, :opener, :front_matter, :closer, :body)

def load_product(path)
  raw = File.read(path)
  match = raw.match(FRONT_MATTER)
  raise ReconcileError, "#{File.basename(path)} has no front matter" if match.nil?

  fields = YAML.safe_load(match[2], permitted_classes: [Date, Time], aliases: false) || {}
  Product.new(path, fields, match[1], match[2], match[3], raw[match.end(0)..] || '')
end

# Rewrite a top-level scalar field in the front matter, keeping any trailing comment.
# Only column-0 keys match, so nested list entries (details:, images:) are untouched.
def set_field(front_matter, key, value)
  pattern = /^(#{Regexp.escape(key)}:)([^\n#]*)(#[^\n]*)?$/
  unless front_matter.match?(pattern)
    newline = front_matter.include?("\r\n") ? "\r\n" : "\n"
    return "#{front_matter}#{key}: #{value}#{newline}"
  end

  front_matter.sub(pattern) do
    comment = Regexp.last_match(3)
    padding = Regexp.last_match(2).to_s
    # Keep the column the comment sat in, so the file's alignment survives.
    gap = comment ? ' ' * [padding.length - value.to_s.length - 1, 1].max : ''
    "#{Regexp.last_match(1)} #{value}#{gap}#{comment}"
  end
end

def mark_sold(product)
  updated = set_field(product.front_matter, 'status', 'sold')
  updated = set_field(updated, 'quantity', 0)
  File.write(product.path, "#{product.opener}#{updated}#{product.closer}#{product.body}")
end

# --- Reconcile ---------------------------------------------------------------

def report(lines)
  lines.each { |line| puts line }
  summary = ENV['GITHUB_STEP_SUMMARY']
  File.write(summary, "#{lines.join("\n")}\n", mode: 'a') if summary && !summary.empty?
end

# Dependencies are injectable so the tests can drive this without a network or the real
# catalogue; the defaults are what the workflow actually runs with.
def reconcile(glob: DEFAULT_PRODUCTS_GLOB,
              key: stripe_key,
              active: nil,
              dry_run: ENV['DRY_RUN'] == '1',
              allow_empty_active: ENV['ALLOW_EMPTY_ACTIVE'] == '1')
  if active.nil?
    if key.nil?
      report(['STRIPE_SECRET_KEY is not set — skipping. Add the restricted key as an Actions ' \
              'secret to switch the reconciler on (see .docs/shop-runbook.md).'])
      return 0
    end

    active = active_payment_link_urls(key)
  end

  products = Dir[glob].sort.map { |path| load_product(path) }
  tracked = products.select { |product| normalise_url(product.fields['stripe_url']) }

  if tracked.empty?
    report(['No products carry a stripe_url — nothing to reconcile.'])
    return 0
  end

  # A key pointed at the wrong account, or one whose permissions were revoked, can return
  # an empty-but-successful list. Deriving from that would mark the whole shop sold, and
  # nothing here can undo it automatically. Refuse, and let a human confirm.
  if active.empty? && !allow_empty_active
    report([
             'Refusing to reconcile: Stripe reports zero active payment links while ' \
             "#{tracked.length} product(s) still reference one.",
             'If the shop really has sold out, re-run with ALLOW_EMPTY_ACTIVE=1. ' \
             'Otherwise check the API key and its account.'
           ])
    return 1
  end

  sold = tracked.reject { |product| active.include?(normalise_url(product.fields['stripe_url'])) }
                .reject { |product| product.fields['status'].to_s == 'sold' }

  if sold.empty?
    report(["Checked #{tracked.length} product(s) against #{active.length} active Stripe link(s): no changes."])
    return 0
  end

  skus = sold.map { |product| product.fields['sku'] || File.basename(product.path, '.md') }
  sold.each { |product| mark_sold(product) } unless dry_run

  report([dry_run ? "Would mark sold: #{skus.join(', ')} (DRY_RUN)" : "Marked sold: #{skus.join(', ')}"])
  0
end

# Guarded so the tests can load the helpers above without running a reconcile.
if __FILE__ == $PROGRAM_NAME
  begin
    exit reconcile
  rescue ReconcileError => e
    warn "reconcile_sold: #{e.message}"
    exit 1
  rescue StandardError => e
    warn "reconcile_sold: unexpected failure — #{e.class}: #{e.message}"
    exit 1
  end
end
