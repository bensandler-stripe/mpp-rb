# typed: strict
# frozen_string_literal: true

require "json"

module Mpp
  module Server
    module Decorator
      extend T::Sig

      module_function

      # Build a 402 response for one or more payment challenges with RFC 9457
      # problem details. Extra headers (e.g. PAYMENT-REQUIRED) are merged in.
      sig do
        params(
          challenge: T.untyped,
          realm: T.untyped,
          extra_headers: T::Hash[T.untyped, T.untyped]
        ).returns(T::Hash[T.untyped, T.untyped])
      end
      def make_challenge_response(challenge, realm, extra_headers: {})
        challenges = challenge.is_a?(Array) ? challenge : [challenge]
        Kernel.raise ArgumentError, "at least one challenge is required" if challenges.empty?

        first = challenges.first
        error = Mpp::PaymentRequiredError.new(realm: realm, description: first.description)
        body = JSON.generate(error.to_problem_details(challenge_id: first.id))
        www = challenges.map { |item| item.to_www_authenticate(realm) }

        headers = {
          "WWW-Authenticate" => ((www.length == 1) ? www.first : www),
          "Cache-Control" => "no-store",
          "Content-Type" => "application/problem+json"
        }
        extra_headers.each do |key, value|
          next if value.nil?

          headers[key] = value
        end
        Mpp::Server::Middleware.mark_authorization_bound_response(
          headers,
          vary: extra_headers.key?("PAYMENT-REQUIRED") ? ["Authorization", "PAYMENT-SIGNATURE"] : ["Authorization"]
        )
        {
          "_mpp_challenge" => true,
          "status" => 402,
          "headers" => headers,
          "body" => body
        }
      end
    end
  end
end
