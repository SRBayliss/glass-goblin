# frozen_string_literal: true

# Behaviour tests for scripts/reconcile_sold.rb.
#
# The reconciler rewrites the catalogue unattended and commits the result, so these tests
# gate deployment: .github/workflows/ci.yml must pass before Pages builds, and the
# reconcile workflow runs them before it is allowed to touch a product file.
#
# Stripe is never called — `reconcile` takes the active-link set by injection.

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'

require_relative '../scripts/reconcile_sold'

# A key-shaped string that is deliberately not in any real Stripe key format, so the
# secret scan in test_catalogue.rb cannot trip over this file.
STUB_KEY = 'stripe-key-for-tests'

ACTIVE_LINK = 'https://buy.stripe.com/14A6oJ4Vlell8sC0uj43S00'
DEAD_LINK   = 'https://buy.stripe.com/7sY7sN87x7WX7oyel943S01'

module Fixtures
  module_function

  # Mirrors the real files: aligned inline comments, a nested details: block whose keys
  # must never be mistaken for top-level ones, and a markdown body.
  def one_off(sku: 'gg-9001', status: 'available', quantity: 1, stripe_url: DEAD_LINK, newline: "\n")
    <<~PRODUCT.gsub("\n", newline)
      ---
      sku: #{sku}
      title: Test ring
      price: 32.00                    # GBP — display only
      status: #{status}                    # available | sold
      quantity: #{quantity}
      images:
        - /assets/products/#{sku}-1.jpg
        - /assets/products/#{sku}-2.jpg
      details:
        - label: Materials
          value: Silver
        - label: Piece
          value: One of a kind
      stripe_url: #{stripe_url}
      paypal_url:
      ---
      A description body mentioning status: available in prose, which must survive.
    PRODUCT
  end

  def bead_line(sku: 'b999', stripe_url: ACTIVE_LINK)
    <<~PRODUCT
      ---
      sku: #{sku}
      title: Test beads
      price: 0.25
      status: available
      quantity: 45
      stripe_url: #{stripe_url}
      paypal_url: https://www.paypal.com/ncp/payment/TESTBUTTONID
      ---
      Sold by the bead.
    PRODUCT
  end
end

class ReconcileTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('gg-reconcile')
    @glob = File.join(@dir, '*.md')
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def write(name, contents)
    path = File.join(@dir, name)
    File.binwrite(path, contents)
    path
  end

  def fields(name)
    load_product(File.join(@dir, name)).fields
  end

  def run_reconcile(active:, **options)
    status = nil
    capture_io { status = reconcile(glob: @glob, key: STUB_KEY, active: Set.new(active.map { |u| normalise_url(u) }), **options) }
    status
  end

  # --- normalise_url ---------------------------------------------------------

  def test_normalise_url_ignores_prefill_parameters
    assert_equal normalise_url(DEAD_LINK), normalise_url("#{DEAD_LINK}?prefilled_email=buyer%40example.com")
  end

  def test_normalise_url_ignores_trailing_slash_and_case
    assert_equal normalise_url(DEAD_LINK), normalise_url("#{DEAD_LINK}/")
    assert_equal normalise_url(DEAD_LINK), normalise_url(DEAD_LINK.sub('buy.', 'BUY.'))
  end

  def test_normalise_url_treats_blank_as_absent
    assert_nil normalise_url(nil)
    assert_nil normalise_url('   ')
    assert_nil normalise_url('')
  end

  def test_normalise_url_keeps_distinct_links_distinct
    refute_equal normalise_url(ACTIVE_LINK), normalise_url(DEAD_LINK)
  end

  # --- set_field -------------------------------------------------------------

  def test_set_field_preserves_an_inline_comment_and_its_column
    before = "status: available               # available | sold\n"
    after  = set_field(before, 'status', 'sold')

    assert_includes after, '# available | sold'
    assert_equal before.index('#'), after.index('#'), 'comment should stay in the same column'
    assert_equal 'sold', YAML.safe_load(after)['status']
  end

  def test_set_field_handles_a_field_with_no_comment
    assert_equal "quantity: 0\n", set_field("quantity: 45\n", 'quantity', 0)
  end

  def test_set_field_appends_a_missing_field
    assert_equal "sku: x\nstatus: sold\n", set_field("sku: x\n", 'status', 'sold')
  end

  def test_set_field_ignores_indented_keys
    nested = "details:\n  - label: Status\n    status: nested\nstatus: available\n"
    result = set_field(nested, 'status', 'sold')

    assert_includes result, '    status: nested'
    assert_equal 'sold', YAML.safe_load(result)['status']
  end

  # --- file rewriting --------------------------------------------------------

  def test_marking_sold_leaves_the_rest_of_the_file_alone
    write('gg-9001.md', Fixtures.one_off)
    run_reconcile(active: [ACTIVE_LINK])

    raw = File.binread(File.join(@dir, 'gg-9001.md'))
    assert_equal 'sold', fields('gg-9001.md')['status']
    assert_equal 0, fields('gg-9001.md')['quantity']
    assert_equal 32.0, fields('gg-9001.md')['price']
    assert_equal 2, fields('gg-9001.md')['images'].length
    assert_equal 2, fields('gg-9001.md')['details'].length
    assert_includes raw, 'A description body mentioning status: available in prose'
    assert_equal 2, raw.scan(/^---\s*$/).length
  end

  def test_marking_sold_preserves_crlf_line_endings
    write('gg-9001.md', Fixtures.one_off(newline: "\r\n"))
    run_reconcile(active: [ACTIVE_LINK])

    raw = File.binread(File.join(@dir, 'gg-9001.md'))
    assert_equal 'sold', fields('gg-9001.md')['status']
    refute_includes raw.gsub("\r\n", ''), "\n", 'every line should still end CRLF'
  end

  def test_a_product_with_no_front_matter_is_an_error
    write('broken.md', "no front matter here\n")
    assert_raises(ReconcileError) { run_reconcile(active: [ACTIVE_LINK]) }
  end

  # --- reconcile behaviour ---------------------------------------------------

  def test_a_deactivated_link_marks_the_product_sold
    write('gg-9001.md', Fixtures.one_off)
    write('b999.md', Fixtures.bead_line)

    assert_equal 0, run_reconcile(active: [ACTIVE_LINK])
    assert_equal 'sold', fields('gg-9001.md')['status']
    assert_equal 'available', fields('b999.md')['status'], 'a still-active link must not be touched'
    assert_equal 45, fields('b999.md')['quantity']
  end

  def test_a_dry_run_reports_without_writing
    write('gg-9001.md', Fixtures.one_off)

    out, = capture_io do
      assert_equal 0, reconcile(glob: @glob, key: STUB_KEY, active: Set.new, dry_run: true, allow_empty_active: true)
    end

    assert_includes out, 'gg-9001'
    assert_includes out, 'DRY_RUN'
    assert_equal 'available', fields('gg-9001.md')['status']
  end

  def test_reconciling_twice_changes_nothing_the_second_time
    write('gg-9001.md', Fixtures.one_off)
    run_reconcile(active: [ACTIVE_LINK])
    after_first = File.binread(File.join(@dir, 'gg-9001.md'))

    assert_equal 0, run_reconcile(active: [ACTIVE_LINK])
    assert_equal after_first, File.binread(File.join(@dir, 'gg-9001.md'))
  end

  def test_a_reactivated_link_never_resurrects_a_sold_product
    write('gg-9001.md', Fixtures.one_off(status: 'sold', quantity: 0))

    assert_equal 0, run_reconcile(active: [DEAD_LINK])
    assert_equal 'sold', fields('gg-9001.md')['status']
    assert_equal 0, fields('gg-9001.md')['quantity']
  end

  # Already-sold products drop out before the write, so a shop full of retired items does
  # not get re-marked (and re-reported as a change) on every one of the 96 daily runs.
  def test_an_already_sold_product_is_not_reprocessed
    write('gg-9001.md', Fixtures.one_off(status: 'sold', quantity: 0))
    write('b999.md', Fixtures.bead_line)

    out, = capture_io do
      assert_equal 0, reconcile(glob: @glob, key: STUB_KEY, active: Set.new([normalise_url(ACTIVE_LINK)]))
    end

    assert_includes out, 'no changes'
    refute_includes out, 'gg-9001'
  end

  def test_products_without_a_stripe_url_are_ignored
    write('gg-9002.md', Fixtures.one_off(sku: 'gg-9002', stripe_url: ''))

    assert_equal 0, run_reconcile(active: [ACTIVE_LINK])
    assert_equal 'available', fields('gg-9002.md')['status']
  end

  def test_a_link_committed_with_query_parameters_still_matches
    write('gg-9001.md', Fixtures.one_off(stripe_url: "#{ACTIVE_LINK}?prefilled_email=x%40y.com"))

    assert_equal 0, run_reconcile(active: [ACTIVE_LINK])
    assert_equal 'available', fields('gg-9001.md')['status']
  end

  # --- refusals --------------------------------------------------------------

  # The failure this guards against: a key pointed at the wrong Stripe account returns a
  # successful, empty list, which a naive derive reads as "the whole shop has sold".
  def test_an_empty_active_set_is_refused_and_writes_nothing
    write('gg-9001.md', Fixtures.one_off)
    write('b999.md', Fixtures.bead_line)

    out, = capture_io do
      assert_equal 1, reconcile(glob: @glob, key: STUB_KEY, active: Set.new)
    end

    assert_includes out, 'Refusing to reconcile'
    assert_equal 'available', fields('gg-9001.md')['status']
    assert_equal 'available', fields('b999.md')['status']
  end

  def test_an_empty_active_set_is_honoured_when_explicitly_allowed
    write('gg-9001.md', Fixtures.one_off)
    write('b999.md', Fixtures.bead_line)

    capture_io do
      assert_equal 0, reconcile(glob: @glob, key: STUB_KEY, active: Set.new, allow_empty_active: true)
    end

    assert_equal 'sold', fields('gg-9001.md')['status']
    assert_equal 'sold', fields('b999.md')['status']
    assert_equal 0, fields('b999.md')['quantity']
  end

  def test_an_empty_catalogue_is_not_treated_as_a_refusal
    capture_io { assert_equal 0, reconcile(glob: @glob, key: STUB_KEY, active: Set.new) }
  end

  # Without this the 15-minute cron would mail the operator a failure round the clock
  # until they got round to creating the key.
  def test_a_missing_key_skips_quietly_rather_than_failing
    write('gg-9001.md', Fixtures.one_off)

    out, = capture_io do
      assert_equal 0, reconcile(glob: @glob, key: nil)
    end

    assert_includes out, 'STRIPE_SECRET_KEY is not set'
    assert_equal 'available', fields('gg-9001.md')['status']
  end
end
