# typed: strict
# frozen_string_literal: true

module Mpp
  BASE_URI = "https://paymentauth.org/problems"

  # Parse error for malformed payment headers.
  class ParseError < StandardError; end

  # Base verification error.
  class VerificationError < StandardError; end

  # Retryable verification error for transactions that were accepted but not mined yet.
  class TransactionPendingError < VerificationError; end

  # Base class for all payment-related errors with RFC 9457 support.
  class PaymentError < StandardError
    extend T::Sig

    sig { params(subclass: T::Class[T.anything]).returns(T.untyped) }
    def self.inherited(subclass)
      super
      return if subclass.instance_variable_defined?(:@_mpp_configured)

      subclass.instance_variable_set(:@_mpp_configured, true)
      name = subclass.name&.split("::")&.last || "PaymentError"
      unless subclass.instance_variable_defined?(:@type)
        subclass.instance_variable_set(:@type,
          "#{BASE_URI}/#{to_slug(name)}")
      end
      subclass.instance_variable_set(:@title, to_title(name)) unless subclass.instance_variable_defined?(:@title)
      subclass.instance_variable_set(:@status, 402) unless subclass.instance_variable_defined?(:@status)
      subclass.instance_variable_set(:@hint, nil) unless subclass.instance_variable_defined?(:@hint)
    end

    class << self
      extend T::Sig

      sig { returns(T.nilable(Integer)) }
      attr_reader :status

      sig { returns(T.nilable(String)) }
      attr_reader :type

      sig { returns(T.nilable(String)) }
      attr_reader :title

      sig { returns(T.nilable(String)) }
      attr_reader :hint

      private

      sig { params(name: String).returns(String) }
      def to_slug(name)
        name.sub(/Error$/, "").gsub(/(?<=[a-z0-9])(?=[A-Z])/, "-").downcase
      end

      sig { params(name: String).returns(String) }
      def to_title(name)
        name.sub(/Error$/, "").gsub(/(?<=[a-z0-9])(?=[A-Z])/, " ")
      end
    end

    @status = T.let(402, Integer)
    @type = T.let("#{BASE_URI}/payment-error", String)
    @title = T.let("Payment Error", String)
    @hint = T.let(nil, T.nilable(String))

    sig { returns(T.untyped) }
    def status = self.class.status
    sig { returns(T.untyped) }
    def type = self.class.type
    sig { returns(T.untyped) }
    def title = self.class.title
    sig { returns(T.untyped) }
    def hint = self.class.hint

    # Convert to RFC 9457 Problem Details format.
    sig { params(challenge_id: T.untyped).returns(T::Hash[T.untyped, T.untyped]) }
    def to_problem_details(challenge_id: nil)
      details = {
        "type" => type,
        "title" => title,
        "status" => status,
        "detail" => message
      }
      details["hint"] = hint if hint
      details["challengeId"] = challenge_id if challenge_id
      details
    end
  end

  # Default hint messages for payment errors.
  module Hints
    PAYMENT_REQUIRED = "Use a supported wallet to pay for this resource using one of the supported " \
      "payment methods returned in the WWW-Authenticate header. See https://mpp.dev/tools/wallet.md"
    MALFORMED_CREDENTIAL = "Use a supported wallet to construct valid credentials for one of the supported " \
      "payment methods returned in the WWW-Authenticate header. See https://mpp.dev/tools/wallet.md"
    METHOD_UNSUPPORTED = PAYMENT_REQUIRED
  end

  class PaymentRequiredError < PaymentError
    extend T::Sig

    @hint = T.let(Hints::PAYMENT_REQUIRED, T.nilable(String))

    sig { params(realm: T.untyped, description: T.untyped).void }
    def initialize(realm: nil, description: nil)
      parts = ["Payment is required"]
      parts << "for \"#{realm}\"" if realm
      parts << "(#{description})" if description
      super("#{parts.join(" ")}.")
    end
  end

  class MalformedCredentialError < PaymentError
    extend T::Sig

    @hint = T.let(Hints::MALFORMED_CREDENTIAL, T.nilable(String))

    sig { params(reason: T.untyped).void }
    def initialize(reason: nil)
      msg = reason ? "Credential is malformed: #{reason}." : "Credential is malformed."
      super(msg)
    end
  end

  class InvalidChallengeError < PaymentError
    extend T::Sig

    sig { params(challenge_id: T.untyped, reason: T.untyped).void }
    def initialize(challenge_id: nil, reason: nil)
      id_part = challenge_id ? " \"#{challenge_id}\"" : ""
      reason_part = reason ? ": #{reason}" : ""
      super("Challenge#{id_part} is invalid#{reason_part}.")
    end
  end

  class VerificationFailedError < PaymentError
    extend T::Sig

    sig { params(reason: T.untyped).void }
    def initialize(reason: nil)
      msg = reason ? "Payment verification failed: #{reason}." : "Payment verification failed."
      super(msg)
    end
  end

  class PaymentExpiredError < PaymentError
    extend T::Sig

    sig { params(expires: T.untyped).void }
    def initialize(expires: nil)
      msg = expires ? "Payment expired at #{expires}." : "Payment has expired."
      super(msg)
    end
  end

  class InvalidPayloadError < PaymentError
    extend T::Sig

    sig { params(reason: T.untyped).void }
    def initialize(reason: nil)
      msg = reason ? "Credential payload is invalid: #{reason}." : "Credential payload is invalid."
      super(msg)
    end
  end

  class BadRequestError < PaymentError
    extend T::Sig

    @status = T.let(400, Integer)

    sig { params(reason: T.untyped).void }
    def initialize(reason: nil)
      msg = reason ? "Bad request: #{reason}." : "Bad request."
      super(msg)
    end
  end

  class PaymentInsufficientError < PaymentError
    extend T::Sig

    sig { params(reason: T.untyped).void }
    def initialize(reason: nil)
      msg = reason ? "Payment insufficient: #{reason}." : "Payment amount is insufficient."
      super(msg)
    end
  end

  class PaymentMethodUnsupportedError < PaymentError
    extend T::Sig

    @status = T.let(400, Integer)
    @type = T.let("#{BASE_URI}/method-unsupported", String)
    @title = T.let("Method Unsupported", String)
    @hint = T.let(Hints::METHOD_UNSUPPORTED, T.nilable(String))

    sig { params(method: T.untyped).void }
    def initialize(method: nil)
      msg = method ? "Payment method \"#{method}\" is not supported." : "Payment method is not supported."
      super(msg)
    end
  end

  class PaymentActionRequiredError < PaymentError
    extend T::Sig

    sig { params(reason: T.untyped).void }
    def initialize(reason: nil)
      msg = reason ? "Payment requires action: #{reason}." : "Payment requires action."
      super(msg)
    end
  end
end
