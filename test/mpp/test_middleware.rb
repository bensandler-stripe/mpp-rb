# frozen_string_literal: true

require "test_helper"
require "stringio"

class TestMiddleware < Minitest::Test
  def setup
    @secret_key = "test-middleware-secret"
    @realm = "api.example.com"
  end

  def test_passes_through_when_no_charge
    app = ->(_env) { [200, {"Content-Type" => "text/plain"}, ["OK"]] }
    middleware = Mpp::Server::Middleware.new(app, handler: mock_handler)

    status, headers, body = middleware.call(minimal_env)

    assert_equal 200, status
    assert_equal ["OK"], body
    assert_equal "text/plain", headers["Content-Type"]
  end

  def test_returns_402_when_charge_requested_without_auth
    app = lambda { |env|
      env["mpp.charge"] = {amount: "1.00"}
      [200, {}, ["OK"]]
    }
    middleware = Mpp::Server::Middleware.new(app, handler: mock_handler)

    status, headers, _body = middleware.call(minimal_env)

    assert_equal 402, status
    assert headers.key?("WWW-Authenticate")
    assert_equal "application/problem+json", headers["Content-Type"]
    assert_equal "no-store", headers["Cache-Control"]
    assert_vary_authorization headers
  end

  def test_attaches_receipt_on_successful_payment
    # Build a valid credential from a challenge
    handler = mock_handler
    challenge = handler.charge(nil, "1.00")
    assert_instance_of Mpp::Challenge, challenge

    # Build a valid credential
    echo = challenge.to_echo
    credential = Mpp::Credential.new(
      challenge: echo,
      payload: {"type" => "test", "data" => "ok"}
    )
    auth_header = credential.to_authorization

    app = lambda { |env|
      env["mpp.charge"] = {amount: "1.00"}
      [200, {}, ["OK"]]
    }
    middleware = Mpp::Server::Middleware.new(app, handler: handler)

    env = minimal_env.merge("HTTP_AUTHORIZATION" => auth_header)
    status, headers, body = middleware.call(env)

    assert_equal 200, status
    assert headers.key?("Payment-Receipt")
    assert_equal "no-store", headers["Cache-Control"]
    assert_vary_authorization headers
    assert_equal ["OK"], body
  end

  def test_rejects_paid_retry_with_tampered_body_digest
    handler = mock_handler
    app = lambda { |env|
      env["mpp.charge"] = {amount: "1.00"}
      env["rack.input"].read
      [200, {}, ["OK"]]
    }
    middleware = Mpp::Server::Middleware.new(app, handler: handler)

    status, headers, _body = middleware.call(
      minimal_env.merge("rack.input" => StringIO.new("{\"query\":\"paid\"}"))
    )
    assert_equal 402, status

    challenge = Mpp::Challenge.from_www_authenticate(headers["WWW-Authenticate"])
    assert_equal Mpp::BodyDigest.compute("{\"query\":\"paid\"}"), challenge.digest
    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"type" => "test", "data" => "ok"}
    )

    status, headers, _body = middleware.call(
      minimal_env.merge(
        "HTTP_AUTHORIZATION" => credential.to_authorization,
        "rack.input" => StringIO.new("{\"query\":\"tampered\"}")
      )
    )

    assert_equal 402, status
    refute headers.key?("Payment-Receipt")
    replacement = Mpp::Challenge.from_www_authenticate(headers["WWW-Authenticate"])
    assert_equal Mpp::BodyDigest.compute("{\"query\":\"tampered\"}"), replacement.digest
  end

  def test_accepts_paid_retry_with_matching_body_digest
    handler = mock_handler
    app = lambda { |env|
      env["mpp.charge"] = {amount: "1.00"}
      [200, {}, [env["rack.input"].read]]
    }
    middleware = Mpp::Server::Middleware.new(app, handler: handler)

    body = "{\"query\":\"paid\"}"
    status, headers, _response_body = middleware.call(
      minimal_env.merge("rack.input" => StringIO.new(body))
    )
    assert_equal 402, status

    challenge = Mpp::Challenge.from_www_authenticate(headers["WWW-Authenticate"])
    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"type" => "test", "data" => "ok"}
    )

    status, headers, response_body = middleware.call(
      minimal_env.merge(
        "HTTP_AUTHORIZATION" => credential.to_authorization,
        "rack.input" => StringIO.new(body)
      )
    )

    assert_equal 200, status
    assert headers.key?("Payment-Receipt")
    assert_equal [body], response_body
  end

  def test_preserves_non_rewindable_request_body_for_app
    handler = mock_handler
    seen_body = nil
    app = lambda { |env|
      env["mpp.charge"] = {amount: "1.00"}
      seen_body = env["rack.input"].read
      [200, {}, [env["rack.input"].read]]
    }
    middleware = Mpp::Server::Middleware.new(app, handler: handler)
    body = "{\"query\":\"paid\"}"

    status, _headers, _response_body = middleware.call(
      minimal_env.merge("rack.input" => NonRewindableInput.new(body))
    )

    assert_equal 402, status
    assert_equal body, seen_body
  end

  private

  def minimal_env
    {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => "/resource"
    }
  end

  def assert_vary_authorization(headers)
    vary_fields = headers.fetch("Vary", "").split(",").map do |field|
      field.strip.downcase
    end
    assert_includes vary_fields, "authorization"
  end

  def mock_handler
    verify_fn = lambda { |credential, _request|
      Mpp::Receipt.success("ref-#{credential.challenge.id[0..7]}")
    }
    intent = Mpp::Server::FunctionalIntent.new("charge", &verify_fn)

    stub_method = Object.new
    stub_method.define_singleton_method(:name) { "tempo" }
    stub_method.define_singleton_method(:intents) { {"charge" => intent} }
    stub_method.define_singleton_method(:currency) { "0x20c0000000000000000000000000000000000000" }
    stub_method.define_singleton_method(:recipient) { "0x1234567890abcdef1234567890abcdef12345678" }
    stub_method.define_singleton_method(:decimals) { 6 }

    Mpp::Server::MppHandler.new(
      method: stub_method,
      realm: @realm,
      secret_key: @secret_key
    )
  end

  class NonRewindableInput
    def initialize(body)
      @input = StringIO.new(body)
    end

    def read(*args)
      @input.read(*args)
    end
  end
end
