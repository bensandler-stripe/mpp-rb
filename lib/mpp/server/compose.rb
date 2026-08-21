# typed: true
# frozen_string_literal: true

require_relative "result"
require_relative "accept_payment"

module Mpp
  module Server
    extend T::Sig

    # A configured payment offer: a method plus per-request charge options.
    class ComposeOffer
      extend T::Sig

      sig { returns(T.untyped) }
      attr_reader :method

      sig { returns(T::Hash[Symbol, T.untyped]) }
      attr_reader :options

      sig { params(handler: T.untyped, method: T.untyped, options: T::Hash[T.untyped, T.untyped]).void }
      def initialize(handler, method, options)
        @handler = T.let(handler, T.untyped)
        @method = T.let(method, T.untyped)
        @options = T.let(symbolize(options), T::Hash[Symbol, T.untyped])
        amount = @options[:amount]
        Kernel.raise ArgumentError, "compose entry requires amount:" if amount.nil? || amount.to_s.empty?
      end

      sig { returns(String) }
      def intent_name
        "charge"
      end

      sig { returns(String) }
      def key
        "#{@method.name}/#{intent_name}"
      end

      sig { returns(T::Hash[String, T.untyped]) }
      def canonical_request
        @canonical_request ||= @handler.build_charge_request(@method, amount, **charge_kwargs)
      end

      sig { params(authorization: T.nilable(String), body: T.untyped).returns(T.untyped) }
      def verify(authorization: nil, body: nil)
        @handler.charge_one(
          @method,
          authorization,
          amount,
          body: body,
          **charge_kwargs
        )
      end

      sig { params(body: T.untyped).returns(Mpp::Challenge) }
      def challenge(body: nil)
        result = verify(body: body)
        return result if result.is_a?(Mpp::Challenge)

        Kernel.raise "expected a challenge from unpaid offer #{key}"
      end

      private

      sig { returns(String) }
      def amount
        @options[:amount].to_s
      end

      REQUEST_OPTION_KEYS = [:body, :accept_payment, :authorization].freeze

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def charge_kwargs
        @options.except(:amount, *REQUEST_OPTION_KEYS)
      end

      sig { params(options: T::Hash[T.untyped, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
      def symbolize(options)
        options.each_with_object({}) do |(key, value), acc|
          acc[key.to_sym] = value
        end
      end
    end

    # Combines multiple method offers into a single callable that presents
    # every method via multiple WWW-Authenticate headers.
    class ComposedHandler
      extend T::Sig

      sig { returns(T.untyped) }
      attr_reader :handler

      sig { returns(T::Array[ComposeOffer]) }
      attr_reader :offers

      sig { params(handler: T.untyped, offers: T::Array[ComposeOffer]).void }
      def initialize(handler:, offers:)
        Kernel.raise ArgumentError, "compose() requires at least one entry" if offers.empty?

        @handler = T.let(handler, T.untyped)
        @offers = T.let(offers, T::Array[ComposeOffer])
      end

      sig { params(handler: T.untyped, entries: T::Array[T.untyped]).returns(ComposedHandler) }
      def self.from_entries(handler, entries)
        new(handler: handler, offers: entries.map { |entry| offer_from_entry(handler, entry) })
      end

      # Flatten nested compositions into a single handler.
      sig { params(handlers: T::Array[T.untyped]).returns(ComposedHandler) }
      def self.compose(handlers)
        Kernel.raise ArgumentError, "compose() requires at least one handler" if handlers.empty?

        offers = handlers.flat_map do |value|
          if value.is_a?(ComposedHandler)
            value.offers
          elsif value.respond_to?(:offers)
            value.offers
          else
            Kernel.raise ArgumentError, "compose() expected a ComposedHandler, got #{value.class}"
          end
        end
        new(handler: handlers.first.handler, offers: offers)
      end

      sig do
        params(
          authorization: T.nilable(String),
          body: T.untyped,
          accept_payment: T.nilable(String)
        ).returns(ComposedResult)
      end
      def call(authorization: nil, body: nil, accept_payment: nil)
        dispatched = dispatch_authorization(authorization, body: body)
        return dispatched if dispatched

        merge_challenges(body: body, accept_payment: accept_payment)
      end

      private

      sig { params(handler: T.untyped, entry: T.untyped).returns(ComposeOffer) }
      def self.offer_from_entry(handler, entry)
        unless entry.is_a?(Array) && entry.length == 2
          Kernel.raise ArgumentError, "compose() entries must be [method, options] tuples"
        end

        method_ref, options = entry
        options = {} if options.nil?
        unless options.is_a?(Hash)
          Kernel.raise ArgumentError, "compose() options must be a Hash"
        end

        ComposeOffer.new(handler, handler.resolve_method(method_ref), options)
      end
      private_class_method :offer_from_entry

      sig { params(authorization: T.nilable(String), body: T.untyped).returns(T.nilable(ComposedResult)) }
      def dispatch_authorization(authorization, body:)
        return nil if authorization.nil? || authorization.strip.empty?

        payment = Mpp::Server::Verify.extract_payment_scheme(authorization)
        return nil unless payment

        begin
          credential = Mpp::Credential.from_authorization(payment)
        rescue Mpp::ParseError
          return nil
        end

        offer = matching_offer(credential)
        return nil unless offer

        wrap_offer_result(offer.verify(authorization: authorization, body: body))
      end

      sig { params(credential: Mpp::Credential).returns(T.nilable(ComposeOffer)) }
      def matching_offer(credential)
        echo = credential.challenge
        echo_request = decode_echo_request(echo)
        return nil if echo_request.nil?

        candidates = @offers.select do |offer|
          offer.method.name == echo.method && offer.intent_name == echo.intent
        end
        return nil if candidates.empty?

        exact = candidates.select { |offer| offer.canonical_request == echo_request }
        exact.first || candidates.first
      end

      sig { params(echo: T.untyped).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
      def decode_echo_request(echo)
        return {} if echo.request.nil? || echo.request.empty?

        Mpp::Parsing.b64_decode(echo.request)
      rescue Mpp::ParseError
        nil
      end

      sig { params(result: T.untyped).returns(ComposedResult) }
      def wrap_offer_result(result)
        if result.is_a?(Mpp::Challenge)
          return ComposedResult.payment_required([result], realm: @handler.realm)
        end

        credential, receipt = result
        ComposedResult.paid(credential, receipt, realm: @handler.realm)
      end

      sig { params(body: T.untyped, accept_payment: T.nilable(String)).returns(ComposedResult) }
      def merge_challenges(body:, accept_payment:)
        challenges = @offers.map { |offer| offer.challenge(body: body) }
        ranked = AcceptPayment.apply(challenges, accept_payment)
        ComposedResult.payment_required(ranked, realm: @handler.realm)
      end
    end

    sig { params(handlers: T.untyped).returns(ComposedHandler) }
    def self.compose(*handlers)
      ComposedHandler.compose(handlers)
    end
  end
end
