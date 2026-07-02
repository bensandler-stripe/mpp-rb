# frozen_string_literal: true

require "test_helper"

class TestErrors < Minitest::Test
  def test_payment_error_base
    error = Mpp::PaymentError.new("test error")

    assert_equal 402, error.status
    assert_equal "https://paymentauth.org/problems/payment-error", error.type
    assert_equal "Payment Error", error.title
  end

  def test_payment_required_error
    error = Mpp::PaymentRequiredError.new(realm: "api.example.com")

    assert_equal 402, error.status
    assert_equal "https://paymentauth.org/problems/payment-required", error.type
    assert_equal "Payment Required", error.title
    assert_includes error.message, "api.example.com"
  end

  def test_malformed_credential_error
    error = Mpp::MalformedCredentialError.new(reason: "bad base64")

    assert_equal 402, error.status
    assert_includes error.message, "bad base64"
  end

  def test_invalid_challenge_error
    error = Mpp::InvalidChallengeError.new(challenge_id: "abc123", reason: "expired")

    assert_includes error.message, "abc123"
    assert_includes error.message, "expired"
  end

  def test_bad_request_error_status
    error = Mpp::BadRequestError.new(reason: "invalid params")

    assert_equal 400, error.status
  end

  def test_method_unsupported_error
    error = Mpp::PaymentMethodUnsupportedError.new(method: "bitcoin")

    assert_equal 400, error.status
    assert_equal "https://paymentauth.org/problems/method-unsupported", error.type
    assert_equal "Method Unsupported", error.title
    assert_includes error.message, "bitcoin"
  end

  def test_to_problem_details
    error = Mpp::PaymentRequiredError.new(realm: "api.example.com")
    details = error.to_problem_details

    assert_equal "https://paymentauth.org/problems/payment-required", details["type"]
    assert_equal "Payment Required", details["title"]
    assert_equal 402, details["status"]
    assert details.key?("detail")
    assert_equal Mpp::Hints::PAYMENT_REQUIRED, details["hint"]
  end

  def test_to_problem_details_with_challenge_id
    error = Mpp::VerificationFailedError.new(reason: "bad sig")
    details = error.to_problem_details(challenge_id: "ch_123")

    assert_equal "ch_123", details["challengeId"]
    refute details.key?("hint"), "errors without a default hint should not include hint in problem details"
  end

  def test_verification_error
    error = Mpp::VerificationError.new("payment failed")

    assert_equal "payment failed", error.message
  end

  def test_parse_error
    error = Mpp::ParseError.new("bad header")

    assert_equal "bad header", error.message
  end

  def test_payment_required_error_has_hint
    error = Mpp::PaymentRequiredError.new
    assert_equal Mpp::Hints::PAYMENT_REQUIRED, error.hint
  end

  def test_malformed_credential_error_has_hint
    error = Mpp::MalformedCredentialError.new
    assert_equal Mpp::Hints::MALFORMED_CREDENTIAL, error.hint
  end

  def test_method_unsupported_error_has_hint
    error = Mpp::PaymentMethodUnsupportedError.new
    assert_equal Mpp::Hints::METHOD_UNSUPPORTED, error.hint
  end

  def test_other_errors_have_no_hint
    error = Mpp::VerificationFailedError.new
    assert_nil error.hint

    error2 = Mpp::InvalidChallengeError.new
    assert_nil error2.hint
  end

  def test_hint_included_in_problem_details_when_present
    error = Mpp::MalformedCredentialError.new(reason: "bad encoding")
    details = error.to_problem_details

    assert_equal Mpp::Hints::MALFORMED_CREDENTIAL, details["hint"]
  end

  def test_hint_excluded_from_problem_details_when_nil
    error = Mpp::PaymentExpiredError.new
    details = error.to_problem_details

    refute details.key?("hint")
  end

  def test_all_error_types_have_correct_slugs
    assert_equal "https://paymentauth.org/problems/payment-required", Mpp::PaymentRequiredError.type
    assert_equal "https://paymentauth.org/problems/malformed-credential", Mpp::MalformedCredentialError.type
    assert_equal "https://paymentauth.org/problems/invalid-challenge", Mpp::InvalidChallengeError.type
    assert_equal "https://paymentauth.org/problems/verification-failed", Mpp::VerificationFailedError.type
    assert_equal "https://paymentauth.org/problems/payment-expired", Mpp::PaymentExpiredError.type
    assert_equal "https://paymentauth.org/problems/invalid-payload", Mpp::InvalidPayloadError.type
    assert_equal "https://paymentauth.org/problems/payment-insufficient", Mpp::PaymentInsufficientError.type
    assert_equal "https://paymentauth.org/problems/payment-action-required", Mpp::PaymentActionRequiredError.type
  end
end
