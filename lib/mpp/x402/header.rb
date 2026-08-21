# typed: strict
# frozen_string_literal: true

require_relative "types"
require "base64"
require "json"

module Mpp
  module X402
    # Base64 JSON codecs for x402 v2 headers.
    #
    # x402 uses standard (not url-safe) base64 of JSON, unlike Payment-auth
    # which uses base64url.
    module Header
      extend T::Sig

      module_function

      sig { params(payment_required: T::Hash[T.untyped, T.untyped]).returns(String) }
      def encode_payment_required(payment_required)
        encode_json(payment_required)
      end

      sig { params(value: String).returns(T::Hash[T.untyped, T.untyped]) }
      def decode_payment_required(value)
        parsed = decode_json(value)
        validate_payment_required!(parsed)
        parsed
      end

      sig { params(payment_payload: T::Hash[T.untyped, T.untyped]).returns(String) }
      def encode_payment_signature(payment_payload)
        encode_json(payment_payload)
      end

      sig { params(value: String).returns(T::Hash[T.untyped, T.untyped]) }
      def decode_payment_signature(value)
        parsed = decode_json(value)
        validate_payment_payload!(parsed)
        parsed
      end

      sig { params(settle_response: T::Hash[T.untyped, T.untyped]).returns(String) }
      def encode_payment_response(settle_response)
        encode_json(settle_response)
      end

      sig { params(value: String).returns(T::Hash[T.untyped, T.untyped]) }
      def decode_payment_response(value)
        parsed = decode_json(value)
        validate_settle_response!(parsed)
        parsed
      end

      sig { params(obj: T.untyped).returns(String) }
      def encode_json(obj)
        json = Mpp::Json.compact_encode(obj)
        Base64.strict_encode64(json)
      end

      sig { params(value: String).returns(T::Hash[T.untyped, T.untyped]) }
      def decode_json(value)
        json = decode_base64(value)
        parsed = JSON.parse(json)
        Kernel.raise Mpp::ParseError, "Invalid base64 JSON header." unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError
        Kernel.raise Mpp::ParseError, "Invalid base64 JSON header."
      end

      sig { params(value: String).returns(String) }
      def decode_base64(value)
        Base64.strict_decode64(value)
      rescue ArgumentError
        padded = value + ("=" * ((-value.length) % 4))
        begin
          Base64.urlsafe_decode64(padded)
        rescue ArgumentError
          Kernel.raise Mpp::ParseError, "Invalid base64 JSON header."
        end
      end
      private_class_method :decode_base64

      sig { params(parsed: T::Hash[T.untyped, T.untyped]).void }
      def validate_payment_required!(parsed)
        Kernel.raise Mpp::ParseError, "Invalid base64 JSON header." unless parsed["x402Version"] == VERSION
        accepts = parsed["accepts"]
        Kernel.raise Mpp::ParseError, "Invalid base64 JSON header." unless accepts.is_a?(Array) && !accepts.empty?
        Kernel.raise Mpp::ParseError, "Invalid base64 JSON header." unless parsed["resource"].is_a?(Hash)

        accepts.each { |item| validate_payment_requirements!(item) }
      end
      private_class_method :validate_payment_required!

      sig { params(parsed: T::Hash[T.untyped, T.untyped]).void }
      def validate_payment_payload!(parsed)
        Kernel.raise Mpp::ParseError, "Invalid base64 JSON header." unless parsed["x402Version"] == VERSION
        validate_payment_requirements!(parsed["accepted"])
        payload = parsed["payload"]
        Kernel.raise Mpp::ParseError, "Invalid base64 JSON header." unless payload.is_a?(Hash)
        Kernel.raise Mpp::ParseError, "EVM charge only supports x402 EIP-3009 authorization payloads" unless payload.key?("authorization")
      end
      private_class_method :validate_payment_payload!

      sig { params(parsed: T::Hash[T.untyped, T.untyped]).void }
      def validate_settle_response!(parsed)
        Kernel.raise Mpp::ParseError, "Invalid base64 JSON header." unless parsed.key?("success")
        Kernel.raise Mpp::ParseError, "Invalid base64 JSON header." unless parsed["transaction"].is_a?(String)
        Kernel.raise Mpp::ParseError, "Invalid base64 JSON header." unless parsed["network"].is_a?(String)
      end
      private_class_method :validate_settle_response!

      sig { params(requirements: T.untyped).void }
      def validate_payment_requirements!(requirements)
        Kernel.raise Mpp::ParseError, "Invalid base64 JSON header." unless requirements.is_a?(Hash)
        Kernel.raise Mpp::ParseError, "x402 exact requires scheme \"exact\"" unless requirements["scheme"] == SCHEME_EXACT
        Kernel.raise Mpp::ParseError, "Invalid base64 JSON header." unless requirements["amount"].is_a?(String) && requirements["amount"].match?(/\A\d+\z/)
        Kernel.raise Mpp::ParseError, "Invalid base64 JSON header." unless requirements["asset"].is_a?(String) && !requirements["asset"].empty?
        Kernel.raise Mpp::ParseError, "Invalid EVM CAIP-2 network" unless requirements["network"].is_a?(String) && requirements["network"].start_with?(EVM_NETWORK_PREFIX)
        Kernel.raise Mpp::ParseError, "Invalid base64 JSON header." unless requirements["payTo"].is_a?(String) && !requirements["payTo"].empty?
        extra = requirements["extra"]
        return if extra.nil?

        transfer = extra["assetTransferMethod"]
        Kernel.raise Mpp::ParseError, "x402 exact permit2 signing is not implemented" if transfer == "permit2"
      end
      private_class_method :validate_payment_requirements!
    end
  end
end
