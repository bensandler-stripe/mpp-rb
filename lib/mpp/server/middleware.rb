# typed: strict
# frozen_string_literal: true

module Mpp
  module Server
    # Rack middleware that intercepts requests requiring payment.
    #
    # The downstream app signals payment is needed by setting env["mpp.charge"]
    # to a hash with at least :amount, and optionally :currency, :recipient,
    # :description, :expires, etc.
    #
    # Example:
    #   use Mpp::Server::Middleware, handler: my_handler
    #
    #   # In your app:
    #   env["mpp.charge"] = { amount: "1.00" }
    class Middleware
      extend T::Sig

      sig { params(app: T.untyped, handler: Mpp::Server::MppHandler).void }
      def initialize(app, handler:)
        @app = T.let(app, T.untyped)
        @handler = T.let(handler, Mpp::Server::MppHandler)
      end

      sig { params(env: T.untyped).returns(T::Array[T.untyped]) }
      def call(env)
        authorization = env["HTTP_AUTHORIZATION"]
        request_body = read_request_body(env)
        status, headers, body = @app.call(env)

        charge_opts = env["mpp.charge"]
        return [status, headers, body] unless charge_opts

        amount = charge_opts[:amount]
        opts = charge_opts.except(:amount, :body)

        result = @handler.charge(authorization, amount, **opts, body: request_body)

        if result.is_a?(Mpp::Challenge)
          resp = Mpp::Server::Decorator.make_challenge_response(result, @handler.realm)
          return [resp["status"], resp["headers"], [resp["body"]]]
        end

        _credential, receipt = result
        headers["Payment-Receipt"] = receipt.to_payment_receipt
        self.class.mark_authorization_bound_response(headers)

        [status, headers, body]
      end

      sig { params(headers: T::Hash[T.untyped, T.untyped]).void }
      def self.mark_authorization_bound_response(headers)
        headers["Cache-Control"] = "no-store"

        vary_values = headers["Vary"].to_s.split(",").map do |value|
          value.strip.downcase
        end
        return if vary_values.include?("*") || vary_values.include?("authorization")

        headers["Vary"] = [headers["Vary"], "Authorization"]
          .compact
          .reject(&:empty?)
          .join(", ")
      end

      private

      sig { params(env: T.untyped).returns(T.nilable(String)) }
      def read_request_body(env)
        input = env["rack.input"]
        return nil unless input&.respond_to?(:read)

        body = T.let(input.read || "", String)
        input.rewind if input.respond_to?(:rewind)
        body.empty? ? nil : body
      end
    end
  end
end
