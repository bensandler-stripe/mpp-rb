# typed: false
# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "../../http/headers"

module Mpp
  module Methods
    module Tempo
      # HTTP client for a hosted Tempo fee-payer JSON-RPC endpoint.
      #
      # `resolve` accepts:
      #   * a URL string (public / unauthenticated sponsor)
      #   * a config hash (`url:` plus optional `headers:` as a Hash or per-request proc)
      #   * any object that responds to `#cosign`
      class FeePayerClient
        SIGN_METHOD = "eth_signRawTransaction"
        DEFAULT_TIMEOUT = Rpc::DEFAULT_TIMEOUT

        attr_reader :base_url

        def initialize(url, headers: nil)
          @base_url = Mpp::Http::Headers.normalize_base_url(url)
          raise ArgumentError, "fee_payer url is required" if @base_url.empty?

          @headers = headers
        end

        def self.resolve_optional(fee_payer)
          return if fee_payer.nil? || fee_payer == false
          return fee_payer unless hosted_config?(fee_payer)

          resolve(fee_payer)
        end

        def self.resolve(fee_payer)
          return fee_payer if fee_payer.is_a?(FeePayerClient)
          return new(fee_payer) if fee_payer.is_a?(String) && !fee_payer.empty?
          return from_config(fee_payer) if fee_payer.is_a?(Hash)
          return fee_payer if duck_type?(fee_payer)

          raise ArgumentError, "fee_payer must be an Account, URL, {url:, headers:}, or an object that implements #cosign"
        end

        def self.from_config(config)
          cfg = Mpp::Http::Headers.symbolize(config)
          url = cfg[:url] || cfg[:base_url] || cfg[:baseUrl]
          new(url.to_s, headers: cfg[:headers])
        end

        def self.hosted_config?(fee_payer)
          return true if fee_payer.is_a?(FeePayerClient)
          return true if fee_payer.is_a?(String)
          return true if fee_payer.is_a?(Hash)
          return true if duck_type?(fee_payer) && !fee_payer.respond_to?(:sign_hash)

          false
        end

        def self.duck_type?(fee_payer)
          !fee_payer.nil? && fee_payer.respond_to?(:cosign)
        end

        def cosign(raw_tx)
          result = post_rpc(SIGN_METHOD, [raw_tx])
          unless result.is_a?(String) && !result.empty?
            raise Mpp::VerificationFailedError.new(reason: "Fee payer returned no signed transaction")
          end

          result
        end

        private

        def post_rpc(method, params)
          uri = URI.parse(@base_url)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.read_timeout = DEFAULT_TIMEOUT

          request = Net::HTTP::Post.new(uri)
          request["Content-Type"] = "application/json"
          Mpp::Http::Headers.resolve(@headers, "/#{method}").each { |key, value| request[key] = value }
          request.body = JSON.generate({
            "jsonrpc" => "2.0",
            "method" => method,
            "params" => params,
            "id" => 1
          })

          response = http.request(request)
          unless response.is_a?(Net::HTTPSuccess)
            raise Mpp::VerificationFailedError.new(reason: "fee payer returned HTTP #{response.code}")
          end

          body = response.body.to_s
          if body.empty?
            raise Mpp::VerificationFailedError.new(reason: "fee payer returned an empty body")
          end

          parsed = JSON.parse(body)
          unless parsed.is_a?(Hash)
            raise Mpp::VerificationFailedError.new(reason: "fee payer returned JSON that is not an object")
          end
          if parsed.key?("error")
            raise Mpp::VerificationFailedError.new(reason: "fee payer RPC error: #{parsed["error"]}")
          end

          parsed["result"]
        rescue JSON::ParserError
          raise Mpp::VerificationFailedError.new(reason: "fee payer returned invalid JSON")
        rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
          raise Mpp::VerificationFailedError.new(reason: "fee payer request failed: #{e.message}")
        end
      end
    end
  end
end
