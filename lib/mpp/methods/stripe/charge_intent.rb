# typed: false
# frozen_string_literal: true

require "time"

module Mpp
  module Methods
    module Stripe
      # Server-side charge intent that verifies payment via Stripe PaymentIntents.
      # Requires the `stripe` gem.
      class ChargeIntent
        attr_reader :name

        def initialize(secret_key:, api_base: Defaults::STRIPE_API_BASE)
          @name = "charge"
          @secret_key = secret_key
          @api_base = api_base
        end

        def verify(credential, request)
          # Check challenge expiry
          challenge_expires = credential.challenge.expires
          if challenge_expires
            expires = Time.iso8601(challenge_expires.gsub("Z", "+00:00"))
            raise Mpp::VerificationError, "Request has expired" if expires < Time.now.utc
          end

          payload_data = credential.payload
          unless payload_data.is_a?(Hash) && payload_data.key?("spt")
            raise Mpp::VerificationError, "Invalid credential payload: missing spt"
          end

          spt = payload_data["spt"]
          external_id = payload_data["externalId"]

          method_details = request["methodDetails"]
          method_details = {} unless method_details.is_a?(Hash)

          # Enforce the payment method types allowlist from the challenge
          payment_method_types = method_details["paymentMethodTypes"]
          unless payment_method_types.is_a?(Array) &&
              payment_method_types.any? &&
              payment_method_types.all? { |type| type.is_a?(String) && !type.empty? }
            raise Mpp::VerificationError, "Invalid or missing methodDetails.paymentMethodTypes"
          end

          # Build PaymentIntent params
          params = {
            amount: Integer(request["amount"]),
            currency: request["currency"],
            shared_payment_granted_token: spt,
            confirm: true,
            payment_method_types: payment_method_types
          }

          # Include metadata from methodDetails if present
          if method_details["metadata"].is_a?(Hash)
            params[:metadata] = method_details["metadata"].transform_values(&:to_s)
          end

          # Create PaymentIntent via Stripe SDK
          begin
            Kernel.require "stripe"
          rescue LoadError
            raise "stripe gem is required for Stripe charge verification. Install with: gem install stripe"
          end

          begin
            client = ::Stripe::StripeClient.new(@secret_key)
            result = client.v1.payment_intents.create(params)
          rescue => e
            raise Mpp::VerificationError, e.message
          end

          # https://docs.stripe.com/error-low-level#idempotency
          if result.respond_to?(:last_response) &&
              result.last_response&.headers&.[]("idempotent-replayed") == "true"
            raise Mpp::VerificationError, "Payment has already been processed."
          end

          pi_id = result.id
          status = result.status

          if status == "requires_action"
            raise Mpp::PaymentActionRequiredError.new(reason: "PaymentIntent #{pi_id} requires action")
          end

          unless status == "succeeded"
            raise Mpp::VerificationError, "PaymentIntent #{pi_id} has status: #{status}"
          end

          Mpp::Receipt.success(pi_id, method: "stripe", external_id: external_id)
        end
      end
    end
  end
end
