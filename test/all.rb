# frozen_string_literal: true

# The whole suite: `ruby test/all.rb`.
#
# Needs nothing installed — minitest ships with Ruby, so this runs without bundler and
# without the site's gems. CI and the reconciler both call it this way.

require_relative 'test_reconcile_sold'
require_relative 'test_catalogue'
