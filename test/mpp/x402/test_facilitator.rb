# frozen_string_literal: true

require "test_helper"
require "json"
require "webmock/minitest"

class TestX402Facilitator < Minitest::Test
  def setup
    @facilitator = Mpp::X402::Facilitator.new("https://facilitator.example")
    @payload = {"x402Version" => 2, "accepted" => {"scheme" => "exact"}}
    @requirements = {"scheme" => "exact", "amount" => "1"}
  end

  def test_verify_posts_expected_body
    stub_request(:post, "https://facilitator.example/verify")
      .with { |request|
        body = JSON.parse(request.body)
        body["x402Version"] == 2 && body["paymentPayload"] == @payload
      }
      .to_return(status: 200, body: {isValid: true, payer: "0xabc"}.to_json)

    result = @facilitator.verify(@payload, @requirements)

    assert_equal true, result["isValid"]
  end

  def test_settle_posts_to_settle
    stub_request(:post, "https://facilitator.example/settle")
      .to_return(status: 200, body: {
        success: true,
        transaction: "0xdead",
        network: "eip155:84532"
      }.to_json)

    result = @facilitator.settle(@payload, @requirements)

    assert_equal true, result["success"]
    assert_equal "0xdead", result["transaction"]
  end

  def test_strips_trailing_slash
    facilitator = Mpp::X402::Facilitator.new("https://facilitator.example/")
    stub_request(:post, "https://facilitator.example/verify")
      .to_return(status: 200, body: {isValid: true}.to_json)

    facilitator.verify(@payload, @requirements)
    assert_requested :post, "https://facilitator.example/verify"
  end

  def test_unauthenticated_url_omits_authorization
    stub_request(:post, "https://facilitator.example/verify")
      .with { |request| request.headers["Authorization"].nil? }
      .to_return(status: 200, body: {isValid: true}.to_json)

    @facilitator.verify(@payload, @requirements)
  end

  def test_token_config_sends_bearer_authorization
    facilitator = Mpp::X402::Facilitator.resolve({
      url: "https://facilitator.stripe.example",
      token: "sk_facilitator_test"
    })
    stub_request(:post, "https://facilitator.stripe.example/verify")
      .with(headers: {"Authorization" => "Bearer sk_facilitator_test"})
      .to_return(status: 200, body: {isValid: true}.to_json)

    facilitator.verify(@payload, @requirements)
    assert_requested :post, "https://facilitator.stripe.example/verify",
      headers: {"Authorization" => "Bearer sk_facilitator_test"}
  end

  def test_static_headers_are_sent
    facilitator = Mpp::X402::Facilitator.new(
      "https://facilitator.example",
      headers: {"X-Api-Key" => "static-key"}
    )
    stub_request(:post, "https://facilitator.example/settle")
      .with(headers: {"X-Api-Key" => "static-key"})
      .to_return(status: 200, body: {success: true, transaction: "0x1"}.to_json)

    facilitator.settle(@payload, @requirements)
  end

  def test_create_auth_headers_receives_path
    paths = []
    facilitator = Mpp::X402::Facilitator.new(
      "https://facilitator.example",
      create_auth_headers: ->(path) {
        paths << path
        {"Authorization" => "Bearer jwt-for-#{path.delete_prefix("/")}"}
      }
    )
    stub_request(:post, "https://facilitator.example/verify")
      .with(headers: {"Authorization" => "Bearer jwt-for-verify"})
      .to_return(status: 200, body: {isValid: true}.to_json)
    stub_request(:post, "https://facilitator.example/settle")
      .with(headers: {"Authorization" => "Bearer jwt-for-settle"})
      .to_return(status: 200, body: {success: true, transaction: "0x1"}.to_json)

    facilitator.verify(@payload, @requirements)
    facilitator.settle(@payload, @requirements)

    assert_equal ["/verify", "/settle"], paths
  end

  def test_create_auth_headers_cdp_nested_shape
    facilitator = Mpp::X402::Facilitator.new(
      "https://facilitator.example",
      create_auth_headers: ->(_path) {
        {
          "verify" => {"Authorization" => "Bearer verify-jwt"},
          "settle" => {"Authorization" => "Bearer settle-jwt"}
        }
      }
    )
    stub_request(:post, "https://facilitator.example/verify")
      .with(headers: {"Authorization" => "Bearer verify-jwt"})
      .to_return(status: 200, body: {isValid: true}.to_json)

    facilitator.verify(@payload, @requirements)
  end

  def test_resolve_passes_through_verify_settle_client
    client = DuckFacilitator.new
    resolved = Mpp::X402::Facilitator.resolve(client)

    assert_same client, resolved
  end

  def test_evm_charge_accepts_duck_typed_facilitator
    client = DuckFacilitator.new
    method = Mpp::Methods::Evm.charge(
      currency: Mpp::Methods::Evm::Assets::BASE_SEPOLIA_USDC,
      recipient: "0x#{"0" * 39}1",
      x402: {facilitator: client}
    )

    assert_same client, method.intents.fetch("charge").facilitator
  end

  def test_evm_charge_accepts_token_config
    method = Mpp::Methods::Evm.charge(
      currency: Mpp::Methods::Evm::Assets::BASE_SEPOLIA_USDC,
      recipient: "0x#{"0" * 39}1",
      x402: {facilitator: {url: "https://facilitator.stripe.example", token: "tok_123"}}
    )
    facilitator = method.intents.fetch("charge").facilitator

    stub_request(:post, "https://facilitator.stripe.example/verify")
      .with(headers: {"Authorization" => "Bearer tok_123"})
      .to_return(status: 200, body: {isValid: true}.to_json)

    facilitator.verify(@payload, @requirements)
  end

  def test_http_error_raises
    stub_request(:post, "https://facilitator.example/verify")
      .to_return(status: 401, body: {error: "unauthorized"}.to_json)

    error = assert_raises(Mpp::VerificationFailedError) do
      @facilitator.verify(@payload, @requirements)
    end
    assert_match(/HTTP 401/, error.message)
  end

  def test_config_requires_url
    error = assert_raises(ArgumentError) do
      Mpp::X402::Facilitator.resolve({token: "tok_123"})
    end
    assert_match(/facilitator/, error.message)
  end

  DuckFacilitator = Struct.new(:calls) do
    def initialize
      super([])
    end

    def verify(payload, requirements)
      calls << [:verify, payload, requirements]
      {"isValid" => true}
    end

    def settle(payload, requirements)
      calls << [:settle, payload, requirements]
      {"success" => true, "transaction" => "0xduck"}
    end
  end
end
