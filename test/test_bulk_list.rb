# frozen_string_literal: true

# Behaviour tests for scripts/bulk_list.rb.
#
# The script creates objects in a live Stripe account and writes new catalogue files, so
# the things worth pinning down are: it refuses a bad batch before touching anything, the
# oversell caps match the policy, and the files it writes satisfy the same rules
# test_catalogue.rb enforces on the committed catalogue.
#
# Stripe is never called — `bulk_list` takes the client by injection.

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'

require_relative '../scripts/bulk_list'
require_relative '../scripts/reconcile_sold' # load_product: read the output back the way the site does

# A key-shaped string deliberately unlike any real Stripe key, so the secret scan in
# test_catalogue.rb cannot trip over this file.
WRITE_KEY = 'stripe-write-key-for-tests'

# Records what it was asked to do and hands back the shape of Stripe's real replies.
class StubStripe
  attr_reader :calls

  def initialize(existing: [], fail_at: nil, message: 'card_declined-shaped failure')
    @existing = existing
    @fail_at = fail_at # [path, sku] — raise instead of creating
    @message = message
    @calls = []
  end

  def exists?(path)
    @calls << { method: :exists?, path: path }
    @existing.include?(path.sub('products/', ''))
  end

  def post(path, params, idempotency_key: nil)
    @calls << { method: :post, path: path, params: params, idempotency_key: idempotency_key }
    sku = params.dig('metadata', 'sku') || params['id'] || params['product']
    raise BulkListError, @message if @fail_at == [path, sku]

    case path
    when 'products' then { 'id' => params['id'] }
    when 'prices' then { 'id' => "price_#{params['product']}" }
    when 'payment_links' then { 'id' => "plink_#{sku}", 'url' => "https://buy.stripe.com/link#{sku}" }
    else {}
    end
  end

  def posts(path)
    calls.select { |call| call[:method] == :post && call[:path] == path }
  end

  def created_skus
    posts('products').map { |call| call[:params]['id'] }
  end
end

class BulkListTest < Minitest::Test
  HEADERS = %w[sku title price quantity category tags subtitle condition details
               description paypal_url shipping_rate].freeze

  def setup
    @dir = Dir.mktmpdir('gg-bulk')
    @products = File.join(@dir, '_products')
    @images = File.join(@dir, 'images')
    FileUtils.mkdir_p([@products, @images])
    @stripe = StubStripe.new
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # --- helpers ---------------------------------------------------------------

  def row(overrides = {})
    { 'sku' => 'gg-0010', 'title' => 'Uranium glass vase', 'price' => '38.00', 'quantity' => '1' }
      .merge(overrides.transform_keys(&:to_s))
  end

  def write_csv(rows, headers: HEADERS)
    path = File.join(@dir, 'batch.csv')
    body = CSV.generate do |csv|
      csv << headers
      rows.each { |entry| csv << headers.map { |header| entry[header] } }
    end
    File.write(path, body)
    path
  end

  def run_bulk(rows, apply: true, stripe: @stripe, headers: HEADERS, **options)
    path = rows.is_a?(String) ? rows : write_csv(rows, headers: headers)
    status = nil
    output = capture_io do
      status = bulk_list(csv_path: path, stripe: stripe, key: WRITE_KEY, apply: apply,
                         products_dir: @products, images_dir: @images, **options)
    end
    [status, output.join]
  end

  def photo(name)
    File.write(File.join(@images, name), 'not really a jpeg')
  end

  def written(sku)
    load_product(File.join(@products, "#{sku}.md"))
  end

  def link_params(sku)
    @stripe.posts('payment_links').find { |call| call[:params].dig('metadata', 'sku') == sku }[:params]
  end

  # --- refusing a bad batch --------------------------------------------------

  def test_a_price_that_is_not_a_plain_number_is_refused
    status, output = run_bulk([row('price' => '£38')])

    assert_equal 1, status
    assert_match(/price must be a plain number/, output)
    assert_empty @stripe.calls, 'nothing should reach Stripe when a row is invalid'
  end

  def test_a_price_below_a_penny_is_refused
    status, output = run_bulk([row('price' => '0.00')])

    assert_equal 1, status
    assert_match(/price must be above zero/, output)
  end

  def test_quantity_must_be_a_whole_number
    status, output = run_bulk([row('quantity' => '2.5')])

    assert_equal 1, status
    assert_match(/quantity must be a whole number/, output)
  end

  def test_a_row_with_no_stock_is_refused_rather_than_listed_as_sold_out
    status, output = run_bulk([row('quantity' => '0')])

    assert_equal 1, status
    assert_match(/already sold out/, output)
  end

  def test_a_sku_repeated_in_the_csv_is_refused
    status, output = run_bulk([row, row('title' => 'Second use of the same sku')])

    assert_equal 1, status
    assert_match(/duplicate sku, already used on line 2/, output)
    assert_empty @stripe.calls
  end

  def test_a_sku_that_would_not_make_a_clean_filename_is_refused
    status, output = run_bulk([row('sku' => 'GG 0010!')])

    assert_equal 1, status
    assert_match(/sku must be lowercase letters, digits and hyphens/, output)
  end

  # The policy that makes the cross-provider oversell race impossible, enforced in code.
  def test_a_one_off_carrying_a_paypal_link_is_refused
    status, output = run_bulk([row('paypal_url' => 'https://www.paypal.com/ncp/payment/ABC123')])

    assert_equal 1, status
    assert_match(/one-off items are Stripe-only/, output)
    assert_empty @stripe.calls
  end

  def test_a_repeatable_line_may_carry_a_paypal_link
    status, = run_bulk([row('sku' => 'b035', 'quantity' => '120',
                            'paypal_url' => 'https://www.paypal.com/ncp/payment/ABC123')])

    assert_equal 0, status
    assert_equal 'https://www.paypal.com/ncp/payment/ABC123', written('b035').fields['paypal_url']
  end

  def test_a_paypal_link_that_is_not_a_paypal_url_is_refused
    status, output = run_bulk([row('quantity' => '120', 'paypal_url' => 'https://paypa1.example/pay')])

    assert_equal 1, status
    assert_match(/must be an https www.paypal.com link/, output)
  end

  # Descriptions and photo lists are hand-written; a re-run must not flatten them.
  def test_an_existing_product_file_is_never_overwritten
    existing = File.join(@products, 'gg-0010.md')
    File.write(existing, "---\nsku: gg-0010\n---\nA description worth keeping.\n")

    status, output = run_bulk([row])

    assert_equal 1, status
    assert_match(/already exists/, output)
    assert_equal "---\nsku: gg-0010\n---\nA description worth keeping.\n", File.read(existing)
    assert_empty @stripe.calls
  end

  def test_every_bad_row_is_reported_in_one_pass
    status, output = run_bulk([row('price' => 'free'), row('sku' => 'b036', 'quantity' => 'lots')])

    assert_equal 1, status
    assert_match(/2 row\(s\) cannot be listed/, output)
    assert_match(/price must be a plain number/, output)
    assert_match(/quantity must be a whole number/, output)
  end

  # One bad row must not leave the good ones half-listed on Stripe with no file beside them.
  def test_one_bad_row_stops_the_whole_batch
    status, = run_bulk([row, row('sku' => 'b036', 'quantity' => '0')])

    assert_equal 1, status
    assert_empty @stripe.calls
    assert_empty Dir[File.join(@products, '*.md')]
  end

  def test_a_missing_required_column_is_refused
    error = assert_raises(BulkListError) do
      run_bulk([row], headers: %w[sku title price])
    end

    assert_match(/missing required column\(s\): quantity/, error.message)
  end

  def test_an_unrecognised_column_is_refused
    error = assert_raises(BulkListError) do
      run_bulk([row.merge('stripe_url' => 'https://buy.stripe.com/sneaky')],
               headers: HEADERS + ['stripe_url'])
    end

    assert_match(/unrecognised column\(s\): stripe_url/, error.message)
  end

  # --- previewing ------------------------------------------------------------

  def test_a_preview_creates_nothing_and_writes_nothing
    status, output = run_bulk([row], apply: false)

    assert_equal 0, status
    assert_match(/Preview only/, output)
    assert_empty @stripe.calls
    assert_empty Dir[File.join(@products, '*.md')]
  end

  def test_a_preview_warns_when_an_item_has_no_photos
    _, output = run_bulk([row], apply: false)

    assert_match(/no photos in assets\/products\/ for gg-0010/, output)
  end

  def test_a_preview_warns_when_postage_is_not_bound_to_the_charge
    _, output = run_bulk([row], apply: false)

    assert_match(/postage must already be inside the price/, output)
  end

  def test_apply_without_a_key_refuses_rather_than_half_listing
    path = write_csv([row])
    status = nil
    output = capture_io do
      status = bulk_list(csv_path: path, stripe: nil, key: nil, apply: true,
                         products_dir: @products, images_dir: @images)
    end.join

    assert_equal 1, status
    assert_match(/STRIPE_WRITE_KEY is not set/, output)
    assert_empty Dir[File.join(@products, '*.md')]
  end

  # --- what gets created on Stripe -------------------------------------------

  def test_the_product_id_is_the_sku_so_a_repeat_run_collides_instead_of_duplicating
    run_bulk([row])

    assert_equal ['gg-0010'], @stripe.created_skus
  end

  def test_a_product_id_already_taken_on_stripe_stops_the_run
    stripe = StubStripe.new(existing: ['gg-0010'])
    status, output = run_bulk([row], stripe: stripe)

    assert_equal 1, status
    assert_match(/Stripe already has a product with id gg-0010/, output)
    assert_empty stripe.posts('products'), 'the duplicate must not be created'
    assert_empty Dir[File.join(@products, '*.md')]
  end

  def test_the_price_is_created_in_gbp_pence
    run_bulk([row('price' => '38.00'), row('sku' => 'b035', 'price' => '0.08', 'quantity' => '50')])

    amounts = @stripe.posts('prices').map { |call| [call[:params]['currency'], call[:params]['unit_amount']] }

    assert_equal [%w[gbp].first, 3800], amounts.first
    assert_equal ['gbp', 8], amounts.last
  end

  def test_an_awkward_price_converts_without_float_error
    run_bulk([row('price' => '4.35')])

    assert_equal 435, @stripe.posts('prices').first[:params]['unit_amount']
  end

  # H2: the completed-sessions cap limits checkouts, not units inside one checkout.
  def test_a_one_off_gets_a_single_use_cap_and_a_fixed_quantity
    run_bulk([row])
    params = link_params('gg-0010')

    assert_equal 1, params.dig('restrictions', 'completed_sessions', 'limit')
    assert_equal 'false', params['line_items'].first.dig('adjustable_quantity', 'enabled')
  end

  # H3: a crude backstop, not an inventory count.
  def test_a_repeatable_line_gets_an_adjustable_quantity_capped_at_stock
    run_bulk([row('sku' => 'b035', 'quantity' => '40')])
    params = link_params('b035')

    assert_equal 40, params.dig('restrictions', 'completed_sessions', 'limit')
    assert_equal 'true', params['line_items'].first.dig('adjustable_quantity', 'enabled')
    assert_equal 40, params['line_items'].first.dig('adjustable_quantity', 'maximum')
  end

  def test_adjustable_quantity_stays_within_stripes_own_ceiling
    run_bulk([row('sku' => 'b035', 'quantity' => '500')])
    params = link_params('b035')

    assert_equal MAX_ADJUSTABLE_QUANTITY, params['line_items'].first.dig('adjustable_quantity', 'maximum')
    assert_equal 500, params.dig('restrictions', 'completed_sessions', 'limit'),
                 'the use cap still reflects real stock'
  end

  def test_every_link_collects_a_shipping_address
    run_bulk([row])

    assert_equal ['GB'], link_params('gg-0010').dig('shipping_address_collection', 'allowed_countries')
  end

  # M3: postage bound to the charge rather than collected out of band.
  def test_a_shipping_rate_is_bound_to_the_link_when_one_is_given
    run_bulk([row('shipping_rate' => 'shr_1234')])

    assert_equal [{ 'shipping_rate' => 'shr_1234' }], link_params('gg-0010')['shipping_options']
  end

  def test_no_shipping_options_are_sent_when_no_rate_is_given
    run_bulk([row])

    refute link_params('gg-0010').key?('shipping_options')
  end

  def test_each_creation_carries_an_idempotency_key
    run_bulk([row])

    keys = @stripe.calls.select { |call| call[:method] == :post }.map { |call| call[:idempotency_key] }

    assert_equal keys.compact, keys, 'every write should be replay-safe'
    assert_equal keys.uniq, keys, 'the three writes must not share a key'
  end

  # --- what gets written to the repo -----------------------------------------

  def test_the_written_file_carries_the_link_stripe_returned
    status, = run_bulk([row])
    fields = written('gg-0010').fields

    assert_equal 0, status
    assert_equal 'https://buy.stripe.com/linkgg-0010', fields['stripe_url']
    assert_equal 'available', fields['status']
    assert_equal 1, fields['quantity']
    assert_equal 38.0, fields['price']
  end

  # The same rules test_catalogue.rb enforces on the committed catalogue: a generated
  # file that fails them would turn the deploy gate red.
  def test_the_written_file_satisfies_the_catalogue_rules
    photo('b035-1.jpg')
    run_bulk([row('sku' => 'b035', 'title' => 'Vaseline beads', 'price' => '0.18', 'quantity' => '120')])
    product = written('b035')

    assert_equal 'b035', product.fields['sku'], 'sku must match the filename'
    assert_includes %w[available sold], product.fields['status']
    assert_kind_of Integer, product.fields['quantity']
    assert_operator product.fields['price'], :>, 0
    assert_equal 'buy.stripe.com', URI.parse(product.fields['stripe_url']).host
    assert_equal 'https', URI.parse(product.fields['stripe_url']).scheme
  end

  def test_photos_on_disk_are_referenced_in_order
    photo('gg-0010-2.jpg')
    photo('gg-0010-1.jpg')
    photo('gg-0011-1.jpg') # a different sku, which must not be picked up
    run_bulk([row])

    assert_equal ['/assets/products/gg-0010-1.jpg', '/assets/products/gg-0010-2.jpg'],
                 written('gg-0010').fields['images']
  end

  # The templates skip the gallery when images is absent, so a photoless item still
  # renders — but it must not reference a file that is not in the repo.
  def test_no_images_key_is_written_when_there_are_no_photos
    run_bulk([row])

    assert_nil written('gg-0010').fields['images']
  end

  def test_optional_columns_become_front_matter
    run_bulk([row('category' => 'Beads', 'tags' => 'uv-glow|vaseline',
                  'subtitle' => 'Priced per bead', 'condition' => 'Brand new',
                  'details' => 'Size=6 mm|Glow=Bright green', 'quantity' => '40',
                  'description' => 'A longer description.')])
    fields = written('gg-0010').fields

    assert_equal 'Beads', fields['category']
    assert_equal %w[uv-glow vaseline], fields['tags']
    assert_equal 'Priced per bead', fields['subtitle']
    assert_equal 'Brand new', fields['condition']
    assert_equal [{ 'label' => 'Size', 'value' => '6 mm' },
                  { 'label' => 'Glow', 'value' => 'Bright green' }], fields['details']
    assert_equal 'A longer description.', written('gg-0010').body.strip
  end

  def test_blank_optional_columns_are_left_out_entirely
    run_bulk([row])
    fields = written('gg-0010').fields

    %w[category tags subtitle condition details].each do |key|
      refute fields.key?(key), "#{key} should be absent rather than empty"
    end
    assert_equal '', fields['paypal_url'].to_s
  end

  # A colon in a title is the ordinary case that breaks hand-rolled YAML.
  def test_values_that_would_break_the_front_matter_are_quoted
    run_bulk([row('title' => 'Ring: green, 18 ct', 'condition' => 'Good — he said "mint"')])
    fields = written('gg-0010').fields

    assert_equal 'Ring: green, 18 ct', fields['title']
    assert_equal 'Good — he said "mint"', fields['condition']
  end

  def test_the_body_falls_back_to_the_title_when_no_description_is_given
    run_bulk([row])

    assert_equal 'Uranium glass vase', written('gg-0010').body.strip
  end

  # --- failing partway through ------------------------------------------------

  def test_a_failure_partway_names_what_was_already_listed_and_what_was_not
    stripe = StubStripe.new(fail_at: ['payment_links', 'b036'])
    rows = [row, row('sku' => 'b036', 'quantity' => '10'), row('sku' => 'b037', 'quantity' => '10')]
    status, output = run_bulk(rows, stripe: stripe)

    assert_equal 1, status
    assert_match(/Stopped at b036/, output)
    assert_match(/Listed before the failure: gg-0010/, output)
    assert_match(/Not attempted: b037/, output)
    assert_match(/product left without a file beside it/, output)
  end

  def test_a_failure_partway_keeps_the_files_already_written
    stripe = StubStripe.new(fail_at: ['payment_links', 'b036'])
    run_bulk([row, row('sku' => 'b036', 'quantity' => '10')], stripe: stripe)

    assert_path_exists File.join(@products, 'gg-0010.md'), 'an item already listed keeps its file'
    refute_path_exists File.join(@products, 'b036.md'), 'the failed row must not get a file'
  end

  def test_a_link_returned_without_a_url_is_treated_as_a_failure
    stripe = StubStripe.new
    def stripe.post(path, params, idempotency_key: nil)
      result = super
      path == 'payment_links' ? result.merge('url' => '') : result
    end

    status, output = run_bulk([row], stripe: stripe)

    assert_equal 1, status
    assert_match(/returned no url/, output)
    assert_empty Dir[File.join(@products, '*.md')]
  end
end

class BulkListArgvTest < Minitest::Test
  def test_a_bare_csv_path_previews
    assert_equal [:run, 'batch.csv', false], parse_argv(['batch.csv'])
  end

  def test_apply_is_opt_in
    assert_equal [:run, 'batch.csv', true], parse_argv(['batch.csv', '--apply'])
  end

  def test_help_wins_over_everything
    assert_equal :help, parse_argv(['batch.csv', '--help']).first
  end

  def test_an_unknown_flag_is_not_mistaken_for_a_path
    assert_equal %i[unknown], [parse_argv(['--aply', 'batch.csv']).first]
  end

  def test_two_paths_are_a_usage_error
    assert_equal :usage, parse_argv(['one.csv', 'two.csv']).first
  end

  def test_no_path_is_a_usage_error
    assert_equal :usage, parse_argv([]).first
  end
end
