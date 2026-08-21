# typed: strict
# frozen_string_literal: true

module Mpp
  module X402
    VERSION = 2
    PAYMENT_METHOD = "evm"
    EXACT_INTENT = "charge"
    SCHEME_EXACT = "exact"
    ASSET_TRANSFER_EIP3009 = "eip3009"
    EVM_NETWORK_PREFIX = "eip155:"
    SYNTHETIC_CHALLENGE_ID_PREFIX = "x402:"

    PAYMENT_REQUIRED_HEADER = "PAYMENT-REQUIRED"
    PAYMENT_SIGNATURE_HEADER = "PAYMENT-SIGNATURE"
    PAYMENT_RESPONSE_HEADER = "PAYMENT-RESPONSE"

    MPPX_EXTENSION_KEY = "mppx"

    MPPX_ROUTE_BINDING_SCHEMA = T.let({
      "additionalProperties" => false,
      "properties" => {
        "_mppx_scope" => {"type" => "string"},
        "digest" => {"type" => "string"},
        "method" => {"type" => "string"},
        "nonce" => {"type" => "string"},
        "opaque" => {"type" => "string"}
      },
      "required" => ["method"],
      "type" => "object"
    }.freeze, T::Hash[String, T.untyped])
  end
end
