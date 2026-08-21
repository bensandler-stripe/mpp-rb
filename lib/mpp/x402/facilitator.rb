# typed: strict
# frozen_string_literal: true

require_relative "types"
require "json"
require "net/http"
require "uri"

module Mpp
  module X402
    # HTTP client for an x402 facilitator `/verify` and `/settle` API.
    class Facilitator
      extend T::Sig

      sig { returns(String) }
      attr_reader :base_url

      sig { params(url: String).void }
      def initialize(url)
        @base_url = T.let(url.sub(%r{/+\z}, ""), String)
      end

      sig { params(facilitator: T.untyped).returns(Facilitator) }
      def self.resolve(facilitator)
        return facilitator if facilitator.is_a?(Facilitator)
        return new(facilitator) if facilitator.is_a?(String) && !facilitator.empty?

        Kernel.raise ArgumentError, "x402 exact requires `facilitator`."
      end

      sig do
        params(
          payment_payload: T::Hash[T.untyped, T.untyped],
          payment_requirements: T::Hash[T.untyped, T.untyped]
        ).returns(T::Hash[T.untyped, T.untyped])
      end
      def verify(payment_payload, payment_requirements)
        post("/verify", payment_payload, payment_requirements)
      end

      sig do
        params(
          payment_payload: T::Hash[T.untyped, T.untyped],
          payment_requirements: T::Hash[T.untyped, T.untyped]
        ).returns(T::Hash[T.untyped, T.untyped])
      end
      def settle(payment_payload, payment_requirements)
        post("/settle", payment_payload, payment_requirements)
      end

      private

      sig do
        params(
          path: String,
          payment_payload: T::Hash[T.untyped, T.untyped],
          payment_requirements: T::Hash[T.untyped, T.untyped]
        ).returns(T::Hash[T.untyped, T.untyped])
      end
      def post(path, payment_payload, payment_requirements)
        uri = URI.parse("#{@base_url}#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate({
          "paymentPayload" => payment_payload,
          "paymentRequirements" => payment_requirements,
          "x402Version" => VERSION
        })
        response = http.request(request)
        parsed = JSON.parse(response.body)
        Kernel.raise Mpp::VerificationFailedError.new(reason: "facilitator #{path} returned HTTP #{response.code}") unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError
        Kernel.raise Mpp::VerificationFailedError.new(reason: "facilitator #{path} returned invalid JSON")
      end
    end
  end
end
