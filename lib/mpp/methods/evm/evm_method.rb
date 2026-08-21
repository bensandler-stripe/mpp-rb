# typed: false
# frozen_string_literal: true

module Mpp
  module Methods
    module Evm
      # EVM payment method. Speaks native Payment-auth and x402 exact.
      class EvmMethod
        attr_reader :name, :currency, :recipient, :decimals, :chain_id, :authorization, :x402
        attr_accessor :intents

        def initialize(currency:, recipient:, decimals:, chain_id:, authorization:, x402:)
          @name = "evm"
          @currency = Authorization.checksum_address(currency)
          @recipient = Authorization.checksum_address(recipient)
          @decimals = decimals
          @chain_id = chain_id
          @authorization = authorization
          @x402 = x402
          @intents = {}
        end

        def transform_request(request, _credential)
          method_details = request.fetch("methodDetails", {})
          method_details = {} unless method_details.is_a?(Hash)

          method_details["chainId"] = @chain_id
          method_details["credentialTypes"] = ["authorization"]
          request.merge("methodDetails" => method_details, "currency" => @currency, "recipient" => @recipient)
        end

        def payment_requirements(request)
          charge_intent.payment_requirements(request)
        end

        def x402_matches?(payload, request)
          accepted = payload["accepted"]
          return false unless accepted.is_a?(Hash)

          Mpp::X402::Server.canonical_equal?(accepted, payment_requirements(request))
        end

        def decorate_challenge(headers, challenge, url: nil, http_method: nil, request: nil)
          return headers if url.nil? || url.empty?

          requirements = payment_requirements(request || challenge.request)
          extensions = Mpp::X402::Server.route_extensions(challenge, http_method)
          body = Mpp::X402::Server.payment_required_body(
            requirements: requirements,
            resource_url: url,
            extensions: extensions,
            error: "#{Mpp::X402::PAYMENT_SIGNATURE_HEADER} header is required"
          )
          headers["PAYMENT-REQUIRED"] = Mpp::X402::Header.encode_payment_required(body)
          headers
        end

        def decorate_receipt(headers, receipt, credential, payment_signature: nil)
          return headers if payment_signature.nil? || payment_signature.empty?

          payload = credential.payload
          request = decode_request(credential)
          chain_id = request.dig("methodDetails", "chainId") || @chain_id
          headers["PAYMENT-RESPONSE"] = Mpp::X402::Header.encode_payment_response({
            "network" => "eip155:#{chain_id}",
            "payer" => payload["from"],
            "success" => true,
            "transaction" => receipt.reference
          })
          headers
        end

        def bind_x402_credential(payment_signature, challenge:, request:, url:, body:, http_method: nil)
          payment_payload = Mpp::X402::Header.decode_payment_signature(payment_signature)
          requirements = payment_requirements(request)
          authorization = Mpp::X402::Server.bind_credential(
            payment_payload: payment_payload,
            requirements: requirements,
            resource_url: url,
            challenge: challenge,
            body: body,
            route_binding: @x402[:route_binding],
            http_method: http_method
          )
          echo = challenge.to_echo
          Mpp::Credential.new(
            challenge: echo,
            payload: authorization.merge("_x402" => true),
            source: source_for(authorization["from"])
          )
        end

        private

        def charge_intent
          intent = @intents["charge"]
          raise ArgumentError, "evm method is missing charge intent" unless intent

          intent
        end

        def decode_request(credential)
          echo = credential.challenge
          return {} if echo.request.nil? || echo.request.empty?

          Mpp::Parsing.b64_decode(echo.request)
        rescue Mpp::ParseError
          {}
        end

        def source_for(address)
          "did:pkh:eip155:#{@chain_id}:#{Authorization.checksum_address(address)}"
        end
      end
    end
  end
end
