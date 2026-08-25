# typed: strict
# frozen_string_literal: true

module Mpp
  module Server
    # Method interface (duck type):
    #   name       -> String
    #   intents    -> Hash[String, Intent]
    #   create_credential(challenge) -> Credential
    #   on_payment_success -> optional callable receiving a payment.success payload

    module MethodHelper
      extend T::Sig

      module_function

      # Transform request using method's transform_request if available.
      sig { params(method: T.untyped, request: T::Hash[String, T.untyped], credential: T.untyped).returns(T::Hash[String, T.untyped]) }
      def transform_request(method, request, credential)
        if method.respond_to?(:transform_request)
          method.transform_request(request, credential)
        else
          request
        end
      end

      # Check whether a method should be advertised for a canonical request.
      # This only governs composing new 402 offers, never credential redemption.
      sig { params(method: T.untyped, request: T::Hash[String, T.untyped]).returns(T::Boolean) }
      def can_offer?(method, request)
        return true unless method.respond_to?(:can_offer?)

        available = method.can_offer?(request)
        unless available == true || available == false
          Kernel.raise ArgumentError, "can_offer? must return true or false"
        end

        available
      end
    end
  end
end
