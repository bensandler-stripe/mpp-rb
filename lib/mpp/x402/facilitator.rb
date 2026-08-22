# typed: strict
# frozen_string_literal: true

require_relative "types"
require_relative "../http/headers"
require "json"
require "net/http"
require "uri"

module Mpp
  module X402
    # HTTP client for an x402 facilitator `/verify` and `/settle` API.
    #
    # `resolve` accepts:
    #   * a URL string (public / unauthenticated facilitator)
    #   * a config hash (`url:` plus optional `headers:` as a Hash or per-request proc)
    #   * any object that responds to `#verify` and `#settle` (e.g. a CDP HTTPFacilitatorClient)
    class Facilitator
      extend T::Sig

      sig { returns(String) }
      attr_reader :base_url

      sig {
        params(
          url: String,
          headers: T.untyped
        ).void
      }
      def initialize(url, headers: nil)
        @base_url = T.let(Mpp::Http::Headers.normalize_base_url(url), String)
        Kernel.raise ArgumentError, "x402 exact requires `facilitator`." if @base_url.empty?

        @headers = T.let(headers, T.untyped)
      end

      sig { params(facilitator: T.untyped).returns(T.untyped) }
      def self.resolve(facilitator)
        return facilitator if facilitator.is_a?(Facilitator)
        return new(facilitator) if facilitator.is_a?(String) && !facilitator.empty?
        return from_config(facilitator) if facilitator.is_a?(Hash)
        return facilitator if duck_type?(facilitator)

        Kernel.raise ArgumentError, "x402 exact requires `facilitator`."
      end

      sig { params(config: T::Hash[T.untyped, T.untyped]).returns(Facilitator) }
      def self.from_config(config)
        cfg = Mpp::Http::Headers.symbolize(config)
        url = cfg[:url] || cfg[:base_url] || cfg[:baseUrl]

        new(url.to_s, headers: cfg[:headers])
      end

      sig { params(facilitator: T.untyped).returns(T::Boolean) }
      def self.duck_type?(facilitator)
        !facilitator.nil? && facilitator.respond_to?(:verify) && facilitator.respond_to?(:settle)
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

      sig { params(path: String).returns(T::Hash[String, String]) }
      def request_headers(path)
        Mpp::Http::Headers.resolve(@headers, path)
      end

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
        request_headers(path).each { |key, value| request[key] = value }
        request.body = JSON.generate({
          "paymentPayload" => payment_payload,
          "paymentRequirements" => payment_requirements,
          "x402Version" => VERSION
        })
        response = http.request(request)
        unless response.is_a?(Net::HTTPSuccess)
          Kernel.raise Mpp::VerificationFailedError.new(reason: "facilitator #{path} returned HTTP #{response.code}")
        end

        body = response.body.to_s
        if body.empty?
          Kernel.raise Mpp::VerificationFailedError.new(reason: "facilitator #{path} returned an empty body")
        end

        parsed = JSON.parse(body)
        unless parsed.is_a?(Hash)
          Kernel.raise Mpp::VerificationFailedError.new(reason: "facilitator #{path} returned JSON that is not an object")
        end

        parsed
      rescue JSON::ParserError
        Kernel.raise Mpp::VerificationFailedError.new(reason: "facilitator #{path} returned invalid JSON")
      end
    end
  end
end
