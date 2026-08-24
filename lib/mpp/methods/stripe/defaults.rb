# typed: strict
# frozen_string_literal: true

module Mpp
  module Methods
    module Stripe
      module Defaults
        STRIPE_API_BASE = "https://api.stripe.com"
        MACHINE_PAYMENTS_API_VERSION = "2026-07-29.preview"
        DEFAULT_CURRENCY = "usd"
        DEFAULT_DECIMALS = 2
      end
    end
  end
end
