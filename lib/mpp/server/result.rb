# typed: strict
# frozen_string_literal: true

module Mpp
  module Server
    # Result of a composed (or multi-method) payment verification.
    #
    # Either a 402 with one or more Challenges, or a verified payment.
    class ComposedResult
      extend T::Sig

      sig { returns(Integer) }
      attr_reader :status

      sig { returns(T::Array[Mpp::Challenge]) }
      attr_reader :challenges

      sig { returns(T.untyped) }
      attr_reader :credential

      sig { returns(T.nilable(Mpp::Receipt)) }
      attr_reader :receipt

      sig { returns(T::Hash[String, T.untyped]) }
      attr_reader :extra_headers

      sig { returns(String) }
      attr_reader :realm

      sig do
        params(
          status: Integer,
          realm: String,
          challenges: T::Array[Mpp::Challenge],
          credential: T.untyped,
          receipt: T.nilable(Mpp::Receipt),
          extra_headers: T::Hash[String, T.untyped]
        ).void
      end
      def initialize(status:, realm:, challenges: [], credential: nil, receipt: nil, extra_headers: {})
        @status = T.let(status, Integer)
        @realm = T.let(realm, String)
        @challenges = T.let(challenges, T::Array[Mpp::Challenge])
        @credential = T.let(credential, T.untyped)
        @receipt = T.let(receipt, T.nilable(Mpp::Receipt))
        @extra_headers = T.let(extra_headers, T::Hash[String, T.untyped])
      end

      sig do
        params(
          challenges: T::Array[Mpp::Challenge],
          realm: String,
          extra_headers: T::Hash[String, T.untyped]
        ).returns(ComposedResult)
      end
      def self.payment_required(challenges, realm:, extra_headers: {})
        new(status: 402, realm: realm, challenges: challenges, extra_headers: extra_headers)
      end

      sig do
        params(
          credential: T.untyped,
          receipt: Mpp::Receipt,
          realm: String,
          extra_headers: T::Hash[String, T.untyped]
        ).returns(ComposedResult)
      end
      def self.paid(credential, receipt, realm:, extra_headers: {})
        new(status: 200, realm: realm, credential: credential, receipt: receipt, extra_headers: extra_headers)
      end

      sig { returns(T::Boolean) }
      def payment_required?
        @status == 402
      end

      # Returns [credential, receipt] for a successful payment.
      sig { returns(T::Array[T.untyped]) }
      def payment
        Kernel.raise ArgumentError, "payment is not available for a 402 response" if payment_required?

        [@credential, @receipt]
      end

      sig { returns(T.nilable(String)) }
      def payment_response
        value = @extra_headers["PAYMENT-RESPONSE"]
        value.is_a?(String) ? value : nil
      end

      # Render a 402 challenge response hash, including extra x402 headers.
      sig { returns(T::Hash[T.untyped, T.untyped]) }
      def to_response
        Kernel.raise ArgumentError, "to_response is only valid for 402 results" unless payment_required?

        Decorator.make_challenge_response(@challenges, @realm, extra_headers: @extra_headers)
      end
    end
  end
end
