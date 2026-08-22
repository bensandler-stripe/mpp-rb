# typed: strict
# frozen_string_literal: true

require_relative "types"
require "json"
require "net/http"
require "uri"

module Mpp
  module X402
    # HTTP client for an x402 facilitator `/verify` and `/settle` API.
    #
    # `resolve` accepts:
    #   * a URL string (public / unauthenticated facilitator)
    #   * a config hash (`url:` plus optional `token:`, `headers:`, `create_auth_headers:`)
    #   * any object that responds to `#verify` and `#settle` (e.g. a CDP HTTPFacilitatorClient)
    class Facilitator
      extend T::Sig

      sig { returns(String) }
      attr_reader :base_url

      sig {
        params(
          url: String,
          headers: T.nilable(T::Hash[T.untyped, T.untyped]),
          token: T.nilable(String),
          create_auth_headers: T.untyped
        ).void
      }
      def initialize(url, headers: nil, token: nil, create_auth_headers: nil)
        base = url.to_s
        base = base.chomp("/") while base.end_with?("/")
        @base_url = T.let(base, String)
        Kernel.raise ArgumentError, "x402 exact requires `facilitator`." if @base_url.empty?

        extra = stringify_headers(headers)
        extra["Authorization"] = "Bearer #{token}" if token && !token.to_s.empty?
        @headers = T.let(extra, T::Hash[String, String])
        @create_auth_headers = T.let(create_auth_headers, T.untyped)
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
        cfg = symbolize(config)
        url = cfg[:url] || cfg[:base_url] || cfg[:baseUrl]
        token = cfg[:token] || cfg[:bearer] || cfg[:bearer_token] || cfg[:bearerToken]
        headers = cfg[:headers]
        create_auth_headers = cfg[:create_auth_headers] || cfg[:createAuthHeaders]

        new(
          url.to_s,
          headers: headers,
          token: token&.to_s,
          create_auth_headers: create_auth_headers
        )
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

      sig { params(config: T::Hash[T.untyped, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
      def self.symbolize(config)
        config.each_with_object({}) do |(key, value), acc|
          acc[key.to_sym] = value
        end
      end
      private_class_method :symbolize

      sig { params(headers: T.nilable(T::Hash[T.untyped, T.untyped])).returns(T::Hash[String, String]) }
      def stringify_headers(headers)
        return {} if headers.nil?

        headers.each_with_object({}) do |(key, value), acc|
          acc[key.to_s] = value.to_s
        end
      end

      sig { params(path: String).returns(T::Hash[String, String]) }
      def request_headers(path)
        stringify_headers(@headers).merge(auth_headers_for(path))
      end

      sig { params(path: String).returns(T::Hash[String, String]) }
      def auth_headers_for(path)
        return {} if @create_auth_headers.nil?

        arity = @create_auth_headers.respond_to?(:arity) ? @create_auth_headers.arity : 1
        generated = (arity == 0) ? @create_auth_headers.call : @create_auth_headers.call(path)
        return {} unless generated.is_a?(Hash)

        operation = path.delete_prefix("/")
        keyed = generated[operation] || generated[operation.to_sym]
        stringify_headers(keyed.is_a?(Hash) ? keyed : generated)
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

        parsed = JSON.parse(T.must(response.body))
        Kernel.raise Mpp::VerificationFailedError.new(reason: "facilitator #{path} returned HTTP #{response.code}") unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError
        Kernel.raise Mpp::VerificationFailedError.new(reason: "facilitator #{path} returned invalid JSON")
      end
    end
  end
end
