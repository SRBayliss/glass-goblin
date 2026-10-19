#!/usr/bin/env ruby
# frozen_string_literal: true

# Bulk-list products: CSV in, Stripe objects + _products/*.md files out.
#
# Spec: .plans/ecommerce-integration-v1.md ("Bulk-listing script")
# Tests: test/test_bulk_list.rb — run them before changing anything here.
# Operator guide: .docs/shop-runbook.md ("Bulk-list a batch of items")
#
# What it does, per CSV row
#   1. Creates a Stripe Product (id = the sku, so a re-run cannot duplicate it),
#      a GBP Price, and a Payment Link carrying the oversell caps the policy requires.
#   2. Writes _products/<sku>.md with the returned public link in `stripe_url`.
#
# What it deliberately does NOT do
#   - It never writes to a product file that already exists. Descriptions and photo
#     lists are hand-written; clobbering them to re-paste a URL is not a trade worth
#     making. An existing file means the row is skipped.
#   - It never modifies or deletes anything already on Stripe. If the product id is
#     taken, the row is reported and the run stops — it does not "fix up" a live object.
#   - It does not commit. The operator reviews the diff and pushes (unlike the
#     reconciler, which has no human in the loop and therefore has to).
#   - It does not create PayPal buttons. PayPal has no equivalent no-code API, and by
#     policy one-offs are Stripe-only anyway; a `paypal_url` column is copied through
#     for repeatable lines that already have one.
#
# Safety posture (differs from reconcile_sold.rb on purpose)
#   The reconciler acts by default because every write it can make is undone by a human
#   editing a file. This script creates objects in a live Stripe account, so it previews
#   by default and only acts when told to: pass --apply.
#
# Environment
#   STRIPE_WRITE_KEY   a key with write access to Products, Prices and Payment Links.
#                      Deliberately NOT the reconciler's STRIPE_SECRET_KEY: that one is
#                      a read-only restricted key held by an unattended cron, and sharing
#                      the variable name invites widening it to write scope. Run this
#                      locally; it has no business in an Actions secret.
#
# Usage
#   ruby scripts/bulk_list.rb products.csv              # preview, writes nothing
#   ruby scripts/bulk_list.rb products.csv --apply      # create and write
#   ruby scripts/bulk_list.rb --help
#
# Exit codes
#   0  ran clean (a preview, or everything asked for was created)
#   1  refused to start, or stopped partway — the report says exactly what exists

require 'json'
require 'net/http'
require 'uri'

begin
  require 'csv'
rescue LoadError
  abort 'bulk_list: the csv library is unavailable — `gem install csv` (Ruby 3.4 unbundled it).'
end

REPO_ROOT = File.expand_path('..', __dir__)
DEFAULT_PRODUCTS_DIR = File.join(REPO_ROOT, '_products')
DEFAULT_IMAGES_DIR = File.join(REPO_ROOT, 'assets', 'products')
STRIPE_API_BASE = 'https://api.stripe.com/v1/'
CURRENCY = 'gbp' # M2: the charge currency is fixed here, never taken from the CSV.
IMAGE_EXTENSIONS = %w[jpg jpeg png webp avif].freeze

# Stripe's ceiling on adjustable quantity. A bead line with more stock than this still
# lists; it just cannot be bought out in one checkout.
MAX_ADJUSTABLE_QUANTITY = 99

COLUMNS = %w[sku title price quantity category tags subtitle condition details
             description paypal_url shipping_rate].freeze
REQUIRED_COLUMNS = %w[sku title price quantity].freeze

class BulkListError < StandardError; end

# A row that cannot be listed, carrying its line number so the operator can find it
# in the spreadsheet they actually edit.
Problem = Struct.new(:line, :sku, :message) do
  def to_s
    "line #{line}#{sku.to_s.empty? ? '' : " (#{sku})"}: #{message}"
  end
end

Item = Struct.new(:line, :sku, :title, :price, :pence, :quantity, :category, :tags,
                  :subtitle, :condition, :details, :description, :paypal_url,
                  :shipping_rate, keyword_init: true) do
  def one_off?
    quantity <= 1
  end

  def adjustable_maximum
    [quantity, MAX_ADJUSTABLE_QUANTITY].min
  end
end

# --- Stripe ------------------------------------------------------------------

def stripe_write_key
  key = ENV['STRIPE_WRITE_KEY'].to_s.strip
  key.empty? ? nil : key
end

# Stripe takes form-encoded bodies with bracketed paths for nesting:
#   line_items[0][adjustable_quantity][enabled]=true
def form_encode(value, prefix = nil)
  case value
  when Hash
    value.flat_map { |key, nested| form_encode(nested, prefix ? "#{prefix}[#{key}]" : key.to_s) }
  when Array
    value.each_with_index.flat_map { |nested, index| form_encode(nested, "#{prefix}[#{index}]") }
  else
    ["#{URI.encode_www_form_component(prefix)}=#{URI.encode_www_form_component(value.to_s)}"]
  end
end

# The real Stripe. Swapped for a stub in the tests, so no test reaches the network.
class StripeClient
  def initialize(key)
    @key = key
  end

  def post(path, params, idempotency_key: nil)
    request = Net::HTTP::Post.new(URI.join(STRIPE_API_BASE, path))
    request['Content-Type'] = 'application/x-www-form-urlencoded'
    request['Idempotency-Key'] = idempotency_key if idempotency_key
    request.body = form_encode(params).join('&')
    send_request(request)
  end

  # Asks whether an id is already taken, so here a 404 is an answer rather than a fault.
  def exists?(path)
    send_request(Net::HTTP::Get.new(URI.join(STRIPE_API_BASE, path)))
    true
  rescue BulkListError => e
    return false if e.message.start_with?('Stripe [404]')

    raise
  end

  private

  def send_request(request)
    request.basic_auth(@key, '')
    uri = request.uri

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
                                                       open_timeout: 15, read_timeout: 30) do |http|
      http.request(request)
    end

    body = begin
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      {}
    end

    unless response.is_a?(Net::HTTPSuccess)
      detail = body.dig('error', 'message') || response.message
      raise BulkListError, "Stripe [#{response.code}] #{detail}"
    end

    body
  end
end

# --- Reading the CSV ---------------------------------------------------------

def split_list(value)
  value.to_s.split('|').map(&:strip).reject(&:empty?)
end

# "Size=8 mm|Glow=Bright green" becomes the details: block the product layout renders.
def parse_details(value)
  split_list(value).filter_map do |pair|
    label, detail = pair.split('=', 2)
    next if detail.nil? || label.to_s.strip.empty? || detail.strip.empty?

    { 'label' => label.strip, 'value' => detail.strip }
  end
end

# Money as an exact integer of pence. Rational keeps float error out of a price: binary
# floating point turns a plain-looking "4.35" into 434 pence often enough to matter.
def to_pence(text)
  cleaned = text.to_s.strip
  raise BulkListError, 'price must be a plain number of pounds, e.g. 12.50' unless /\A\d+(\.\d{1,2})?\z/.match?(cleaned)

  # The pattern already limits this to two decimal places, so the result is always whole.
  (Rational(cleaned) * 100).to_i
end

def validate_row(row, line, seen, products_dir)
  problems = []
  sku = row['sku'].to_s.strip
  title = row['title'].to_s.strip

  problems << Problem.new(line, sku, 'sku is blank') if sku.empty?
  unless sku.empty? || /\A[a-z0-9][a-z0-9-]*\z/.match?(sku)
    problems << Problem.new(line, sku, 'sku must be lowercase letters, digits and hyphens — ' \
                                       'it becomes both the filename and the Stripe product id')
  end
  problems << Problem.new(line, sku, "duplicate sku, already used on line #{seen[sku]}") if seen.key?(sku)
  problems << Problem.new(line, sku, 'title is blank') if title.empty?

  pence = begin
    to_pence(row['price'])
  rescue BulkListError => e
    problems << Problem.new(line, sku, e.message)
    nil
  end
  problems << Problem.new(line, sku, 'price must be above zero') if pence&.zero?

  quantity = row['quantity'].to_s.strip
  unless /\A\d+\z/.match?(quantity)
    problems << Problem.new(line, sku, 'quantity must be a whole number of units in stock')
    quantity = nil
  end
  problems << Problem.new(line, sku, 'quantity 0 would list something already sold out') if quantity == '0'

  paypal = row['paypal_url'].to_s.strip
  # The one-off provider policy, enforced rather than merely documented: one unique unit
  # live on two checkouts can be bought on both before either self-closes.
  if !paypal.empty? && quantity.to_i <= 1
    problems << Problem.new(line, sku, 'one-off items are Stripe-only — remove the paypal_url, ' \
                                       'or raise the quantity if this is a repeatable line')
  end
  if !paypal.empty? && !paypal.start_with?('https://www.paypal.com/')
    problems << Problem.new(line, sku, 'paypal_url must be an https www.paypal.com link')
  end

  if !sku.empty? && File.exist?(File.join(products_dir, "#{sku}.md"))
    problems << Problem.new(line, sku, "_products/#{sku}.md already exists — listing it again " \
                                       'would overwrite the description')
  end

  return [nil, problems] unless problems.empty?

  seen[sku] = line

  [Item.new(
    line: line, sku: sku, title: title,
    price: row['price'].to_s.strip, pence: pence, quantity: quantity.to_i,
    category: row['category'].to_s.strip,
    tags: split_list(row['tags']),
    subtitle: row['subtitle'].to_s.strip,
    condition: row['condition'].to_s.strip,
    details: parse_details(row['details']),
    description: row['description'].to_s.strip,
    paypal_url: paypal,
    shipping_rate: row['shipping_rate'].to_s.strip
  ), []]
end

# Every row is validated before anything is created. A batch that fails halfway leaves
# live Stripe objects with no file pointing at them, so the cheap failure has to come first.
def read_csv(path, products_dir: DEFAULT_PRODUCTS_DIR)
  raise BulkListError, "no such file: #{path}" unless File.file?(path)

  table = CSV.read(path, headers: true, encoding: 'bom|utf-8')
  headers = (table.headers || []).compact.map { |header| header.to_s.strip }

  missing = REQUIRED_COLUMNS - headers
  raise BulkListError, "the CSV is missing required column(s): #{missing.join(', ')}" unless missing.empty?

  unknown = headers - COLUMNS
  unless unknown.empty?
    raise BulkListError, "unrecognised column(s): #{unknown.join(', ')}. " \
                         "Known columns: #{COLUMNS.join(', ')}"
  end

  items = []
  problems = []
  seen = {}

  table.each_with_index do |row, index|
    line = index + 2 # +1 for the header row, +1 because spreadsheets count from 1
    next if row.to_h.values.all? { |value| value.to_s.strip.empty? }

    item, row_problems = validate_row(row, line, seen, products_dir)
    item ? items << item : problems.concat(row_problems)
  end

  raise BulkListError, 'the CSV has no rows to list' if items.empty? && problems.empty?

  [items, problems]
end

# --- Stripe objects ----------------------------------------------------------

def payment_link_params(item, price_id)
  line_item = { 'price' => price_id, 'quantity' => 1 }

  if item.one_off?
    # H2: the completed-sessions cap limits checkouts, not units within one. Both needed.
    line_item['adjustable_quantity'] = { 'enabled' => 'false' }
    completed_sessions = 1
  else
    line_item['adjustable_quantity'] = {
      'enabled' => 'true',
      'minimum' => 1,
      'maximum' => item.adjustable_maximum
    }
    # H3: a crude backstop, not an inventory count — one checkout can take many beads.
    completed_sessions = item.quantity
  end

  params = {
    'line_items' => [line_item],
    'restrictions' => { 'completed_sessions' => { 'limit' => completed_sessions } },
    'shipping_address_collection' => { 'allowed_countries' => ['GB'] },
    'metadata' => { 'sku' => item.sku }
  }
  # M3: postage bound to the charge. With no rate it has to be inside the price — the run
  # warns about that, because collecting postage afterwards is the thing that must not happen.
  params['shipping_options'] = [{ 'shipping_rate' => item.shipping_rate }] unless item.shipping_rate.empty?
  params
end

# Returns the public Payment Link URL for a freshly created listing.
def create_listing(item, stripe)
  if stripe.exists?("products/#{item.sku}")
    raise BulkListError, "Stripe already has a product with id #{item.sku} — delete or rename " \
                         'it there, or drop this row'
  end

  stripe.post('products', {
                'id' => item.sku, # deterministic, so a repeat run collides instead of duplicating
                'name' => item.title,
                'metadata' => { 'sku' => item.sku }
              }, idempotency_key: "gg-bulk-#{item.sku}-product")

  price = stripe.post('prices', {
                        'product' => item.sku,
                        'currency' => CURRENCY,
                        'unit_amount' => item.pence
                      }, idempotency_key: "gg-bulk-#{item.sku}-price-#{item.pence}")

  price_id = price['id'].to_s
  raise BulkListError, "Stripe created a price for #{item.sku} but returned no id" if price_id.empty?

  link = stripe.post('payment_links', payment_link_params(item, price_id),
                     idempotency_key: "gg-bulk-#{item.sku}-link-#{price_id}")

  url = link['url'].to_s
  raise BulkListError, "Stripe created the link for #{item.sku} but returned no url" if url.empty?

  url
end

# --- Writing the product file ------------------------------------------------

# Quote anything YAML would otherwise read as structure. Cheaper and more predictable
# than YAML.dump, which would restyle and reorder the whole block.
def yaml_scalar(value)
  text = value.to_s
  return '""' if text.empty?

  needs_quoting = text.start_with?(' ', '-', '?') || text.end_with?(' ') ||
                  /[:#\[\]{}&*!|>'"%@`,\t\r\n]/.match?(text)
  return text unless needs_quoting

  # Block form on both: in the string form of gsub, a backslash in the replacement is
  # itself an escape character, which is exactly the thing being escaped here.
  escaped = text.gsub('\\') { '\\\\' }.gsub('"') { '\\"' }
  %("#{escaped}")
end

def images_for(sku, images_dir)
  pattern = File.join(images_dir, "#{sku}-*.{#{IMAGE_EXTENSIONS.join(',')}}")
  Dir.glob(pattern, File::FNM_CASEFOLD).sort.map { |path| "/assets/products/#{File.basename(path)}" }
end

def product_markdown(item, stripe_url, images)
  lines = ['---', "sku: #{item.sku}"]
  lines << "category: #{yaml_scalar(item.category)}" unless item.category.empty?
  lines << "tags: [#{item.tags.map { |tag| yaml_scalar(tag) }.join(', ')}]" unless item.tags.empty?
  lines << "title: #{yaml_scalar(item.title)}"
  lines << "subtitle: #{yaml_scalar(item.subtitle)}" unless item.subtitle.empty?
  lines << "price: #{item.price}"
  lines << 'status: available'
  lines << "quantity: #{item.quantity}"

  unless images.empty?
    lines << 'images:'
    images.each { |image| lines << "  - #{image}" }
  end

  lines << "condition: #{yaml_scalar(item.condition)}" unless item.condition.empty?

  unless item.details.empty?
    lines << 'details:'
    item.details.each do |detail|
      lines << "  - label: #{yaml_scalar(detail['label'])}"
      lines << "    value: #{yaml_scalar(detail['value'])}"
    end
  end

  lines << "stripe_url: #{stripe_url}"
  lines << "paypal_url:#{item.paypal_url.empty? ? '' : " #{item.paypal_url}"}"
  lines << '---'
  lines << (item.description.empty? ? item.title : item.description)
  "#{lines.join("\n")}\n"
end

def write_product(item, stripe_url, images, products_dir)
  path = File.join(products_dir, "#{item.sku}.md")
  raise BulkListError, "#{item.sku}.md appeared while the batch was running — not overwriting it" if File.exist?(path)

  File.binwrite(path, product_markdown(item, stripe_url, images))
  path
end

# --- Orchestration -----------------------------------------------------------

# Named `say` rather than `report`: reconcile_sold.rb defines a top-level `report`, and
# test/all.rb loads both scripts into one process, where the second definition would win.
def say(lines)
  lines.each { |line| puts line }
end

def preview_lines(items)
  items.map do |item|
    shape = if item.one_off?
              'one-off, 1-use cap'
            else
              "repeatable, max #{item.adjustable_maximum} per checkout, #{item.quantity}-use cap"
            end
    postage = item.shipping_rate.empty? ? 'postage in price' : "shipping rate #{item.shipping_rate}"
    "  #{format('%-8s', item.sku)} #{format('%-32.32s', item.title)} £#{item.price}  #{shape}; #{postage}"
  end
end

# Dependencies injected so the tests drive this without a network or the real catalogue.
def bulk_list(csv_path:,
              stripe: nil,
              key: stripe_write_key,
              apply: false,
              products_dir: DEFAULT_PRODUCTS_DIR,
              images_dir: DEFAULT_IMAGES_DIR)
  items, problems = read_csv(csv_path, products_dir: products_dir)

  unless problems.empty?
    say(["Refusing to list: #{problems.length} row(s) cannot be listed.",
            *problems.map { |problem| "  #{problem}" },
            '', 'Nothing was created. Fix the CSV and run again.'])
    return 1
  end

  say(["#{items.length} item(s) ready to list:", *preview_lines(items)])

  missing_images = items.reject { |item| images_for(item.sku, images_dir).any? }
  unless missing_images.empty?
    say(['', "Warning: no photos in assets/products/ for #{missing_images.map(&:sku).join(', ')}.",
            'Those pages will list without a gallery — add <sku>-1.jpg and reference it before go-live.'])
  end

  if items.all? { |item| item.shipping_rate.empty? }
    say(['', 'Warning: no shipping_rate on any row — postage must already be inside the price (M3).'])
  end

  unless apply
    say(['', 'Preview only. Nothing was created on Stripe and no files were written.',
            'Re-run with --apply to create them.'])
    return 0
  end

  if stripe.nil?
    if key.nil?
      say(['', 'STRIPE_WRITE_KEY is not set. Create a key with write access to Products, Prices ' \
                  'and Payment Links, then export it — see .docs/shop-runbook.md.'])
      return 1
    end

    stripe = StripeClient.new(key)
  end

  listed = []
  say([''])

  items.each_with_index do |item, index|
    url = create_listing(item, stripe)
    path = write_product(item, url, images_for(item.sku, images_dir), products_dir)
    listed << item.sku
    say(["listed #{item.sku} → #{url}  (#{File.basename(path)})"])
  rescue BulkListError => e
    say(['', "Stopped at #{item.sku} (line #{item.line}): #{e.message}"])
    say(["Listed before the failure: #{listed.join(', ')}"]) unless listed.empty?
    remaining = items.drop(index + 1).map(&:sku)
    say(["Not attempted: #{remaining.join(', ')}"]) unless remaining.empty?
    say(['', 'Check Stripe for a product left without a file beside it before re-running.'])
    return 1
  end

  say(['', "Listed #{listed.length} item(s). Review the new files, preview the shop, then commit."])
  0
end

def parse_argv(argv)
  apply = false
  paths = []

  argv.each do |arg|
    case arg
    when '--apply' then apply = true
    when '--help', '-h' then return [:help, nil, false]
    else
      return [:unknown, arg, false] if arg.start_with?('-')

      paths << arg
    end
  end

  return [:usage, nil, false] unless paths.length == 1

  [:run, paths.first, apply]
end

USAGE = <<~TEXT
  Usage: ruby scripts/bulk_list.rb <products.csv> [--apply]

    Previews by default; --apply creates the Stripe objects and writes _products/*.md.
    Needs STRIPE_WRITE_KEY in the environment when applying.

  CSV columns (required: #{REQUIRED_COLUMNS.join(', ')}):
    #{COLUMNS.join(', ')}

    tags and details separate entries with |; details are Label=Value pairs.
    See scripts/products.example.csv.
TEXT

if __FILE__ == $PROGRAM_NAME
  mode, value, apply = parse_argv(ARGV)

  case mode
  when :help
    puts USAGE
    exit 0
  when :usage
    warn USAGE
    exit 1
  when :unknown
    warn "bulk_list: unknown option #{value}\n\n#{USAGE}"
    exit 1
  end

  begin
    exit bulk_list(csv_path: value, apply: apply)
  rescue BulkListError => e
    warn "bulk_list: #{e.message}"
    exit 1
  rescue StandardError => e
    warn "bulk_list: unexpected failure — #{e.class}: #{e.message}"
    exit 1
  end
end
