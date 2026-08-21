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
end
