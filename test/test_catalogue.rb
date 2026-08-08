# frozen_string_literal: true

# Validates the committed catalogue and guards the security rules from
# .plans/ecommerce-integration-v1.md. These run before Pages deploys, so a malformed
# product file or a leaked key fails the build instead of going live.
#
# The reconciler parses and rewrites these same files, so a shape it cannot handle is
# caught here rather than by a cron run at 3am.

require 'minitest/autorun'

require_relative '../scripts/reconcile_sold'

class CatalogueTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  # gg-0001 carries a PayPal link as a deliberate demo of the one-off PayPal path, kept
  # while the shop is a test demo. See .docs/shop-runbook.md — it goes Stripe-only at
  # go-live. Anything else appearing here means the policy has been broken by accident.
  ONE_OFF_PAYPAL_EXCEPTIONS = %w[gg-0001].freeze

  def products
    @products ||= Dir[File.join(ROOT, '_products', '*.md')].sort.map { |path| load_product(path) }
  end

  def each_product
    refute_empty products, 'the catalogue should not be empty'
    products.each { |product| yield product, File.basename(product.path) }
  end

  def test_every_product_has_the_fields_the_templates_and_reconciler_rely_on
    each_product do |product, name|
      %w[sku title price status quantity].each do |field|
        refute_nil product.fields[field], "#{name} is missing #{field}"
      end
    end
  end

  def test_the_sku_matches_the_filename
    each_product do |product, name|
      assert_equal File.basename(name, '.md'), product.fields['sku'],
                   "#{name}: sku and filename must match — the runbook and image names key off it"
    end
  end

  def test_status_is_one_of_the_two_values_the_templates_understand
    each_product do |product, name|
      assert_includes %w[available sold], product.fields['status'], "#{name} has an unusable status"
    end
  end

  def test_quantity_is_a_whole_number_that_is_not_negative
    each_product do |product, name|
      quantity = product.fields['quantity']
      assert_kind_of Integer, quantity, "#{name}: quantity should be a whole number"
      assert_operator quantity, :>=, 0, "#{name}: quantity cannot be negative"
    end
  end

  def test_a_sold_product_has_no_stock_left
    each_product do |product, name|
      next unless product.fields['status'] == 'sold'

      assert_equal 0, product.fields['quantity'], "#{name} is sold but still claims stock"
    end
  end

  def test_prices_are_positive_numbers
    each_product do |product, name|
      price = product.fields['price']
      assert_kind_of Numeric, price, "#{name}: price should be a number, not a string with a currency symbol"
      assert_operator price, :>, 0, "#{name}: price should be above zero"
    end
  end

  def test_every_referenced_image_exists
    each_product do |product, name|
      Array(product.fields['images']).each do |image|
        path = File.join(ROOT, image.to_s.sub(%r{\A/}, ''))
        assert File.file?(path), "#{name} references #{image}, which is not in the repo"
      end
    end
  end

  def test_payment_links_point_at_the_providers_over_https
    hosts = { 'stripe_url' => 'buy.stripe.com', 'paypal_url' => 'www.paypal.com' }

    each_product do |product, name|
      hosts.each do |field, host|
        url = product.fields[field].to_s.strip
        next if url.empty?

        uri = URI.parse(url)
        assert_equal 'https', uri.scheme, "#{name}: #{field} must be https (C2)"
        assert_equal host, uri.host, "#{name}: #{field} should be a #{host} link"
      end
    end
  end

  # One unique unit live on two independent checkouts can be bought on both before either
  # self-closes. One provider per one-off removes that race at the root.
  def test_one_off_items_are_stripe_only
    each_product do |product, name|
      next unless product.fields['quantity'].to_i <= 1 && product.fields['status'] == 'available'
      next if ONE_OFF_PAYPAL_EXCEPTIONS.include?(product.fields['sku'])

      assert_empty product.fields['paypal_url'].to_s.strip,
                   "#{name} is a one-off with a PayPal link — cross-provider oversell risk"
    end
  end
end

class SecretsTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  TEXT_FILES = /\.(md|markdown|ya?ml|html|js|json|rb|scss|css|txt|webmanifest)\z|\A\.[^.]+\z/

  # Each pattern requires a key-length body, not just a prefix, so the runbooks can name
  # what a key looks like without tripping this. Written as alternations rather than plain
  # literals for the same reason — this file is tracked and would otherwise match itself.
  SECRET_PATTERNS = [
    /\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}/, # Stripe secret and restricted keys
    /\bwhsec_[A-Za-z0-9]{16,}/,                   # Stripe webhook signing secret
    /#{'-' * 5}BEGIN [A-Z ]*PRIVATE KEY/          # PEM private key, e.g. the reconciler App's
  ].freeze

  # Only the Payment Link URL is ever committed; the secret key lives in an Actions
  # secret and nowhere else (L2 in the plan).
  def test_no_provider_secret_is_committed
    tracked = `git -C "#{ROOT}" ls-files`.split("\n")
    refute_empty tracked, 'expected to be running inside a git checkout'

    offenders = tracked.select { |file| file.match?(TEXT_FILES) }.select do |file|
      path = File.join(ROOT, file)
      next false unless File.file?(path)

      contents = File.read(path, encoding: 'BINARY')
      SECRET_PATTERNS.any? { |pattern| contents.match?(pattern) }
    end

    assert_empty offenders, 'a provider secret looks committed — rotate it at the provider, then remove it'
  end
end
