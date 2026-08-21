# frozen_string_literal: true

require "test_helper"

class TestX402Header < Minitest::Test
  def setup
    @requirements = {
      "amount" => "10000",
      "asset" => Mpp::Methods::Evm::Assets::BASE_SEPOLIA_USDC.address,
      "extra" => {
        "assetTransferMethod" => "eip3009",
        "name" => "USDC",
        "version" => "2"
      },
      "maxTimeoutSeconds" => 300,
      "network" => "eip155:84532",
      "payTo" => format("0x%040d", 1),
      "scheme" => "exact"
    }
    @payment_required = {
      "accepts" => [@requirements],
      "resource" => {"url" => "https://api.example.com/paid"},
      "x402Version" => 2
    }
  end

  def test_round_trips_payment_required
    encoded = Mpp::X402::Header.encode_payment_required(@payment_required)
    decoded = Mpp::X402::Header.decode_payment_required(encoded)

    assert_equal 2, decoded["x402Version"]
    assert_equal "exact", decoded["accepts"][0]["scheme"]
    assert_equal "https://api.example.com/paid", decoded["resource"]["url"]
  end

  def test_round_trips_payment_signature
    payload = {
      "accepted" => @requirements,
      "payload" => {
        "authorization" => {
          "from" => format("0x%040d", 1),
          "nonce" => "0x#{'ab' * 32}",
          "to" => @requirements["payTo"],
          "validAfter" => "0",
          "validBefore" => "9999999999",
          "value" => "10000"
        },
        "signature" => "0x#{'cd' * 65}"
      },
      "resource" => {"url" => "https://api.example.com/paid"},
      "x402Version" => 2
    }
    encoded = Mpp::X402::Header.encode_payment_signature(payload)
    decoded = Mpp::X402::Header.decode_payment_signature(encoded)

    assert_equal "10000", decoded["payload"]["authorization"]["value"]
  end

  def test_rejects_non_v2
    encoded = Mpp::X402::Header.encode_json(@payment_required.merge("x402Version" => 1))
    assert_raises(Mpp::ParseError) { Mpp::X402::Header.decode_payment_required(encoded) }
  end

  def test_rejects_non_exact_scheme
    required = @payment_required.merge(
      "accepts" => [@requirements.merge("scheme" => "upto")]
    )
    encoded = Mpp::X402::Header.encode_json(required)
    error = assert_raises(Mpp::ParseError) { Mpp::X402::Header.decode_payment_required(encoded) }
    assert_match(/exact/, error.message)
  end

  def test_rejects_permit2
    required = @payment_required.merge(
      "accepts" => [@requirements.merge("extra" => {"assetTransferMethod" => "permit2"})]
    )
    encoded = Mpp::X402::Header.encode_json(required)
    error = assert_raises(Mpp::ParseError) { Mpp::X402::Header.decode_payment_required(encoded) }
    assert_match(/permit2/, error.message)
  end

  def test_merge_flattens_accepts_with_same_resource
    first = Mpp::X402::Header.encode_payment_required(@payment_required)
    second_req = @requirements.merge("amount" => "20000")
    second = Mpp::X402::Header.encode_payment_required(
      @payment_required.merge("accepts" => [second_req])
    )
    merged = Mpp::X402::Server.merge_payment_required([first, second])
    decoded = Mpp::X402::Header.decode_payment_required(merged)

    assert_equal ["10000", "20000"], decoded["accepts"].map { |item| item["amount"] }
  end

  def test_merge_rejects_different_resources
    first = Mpp::X402::Header.encode_payment_required(@payment_required)
    other = Mpp::X402::Header.encode_payment_required(
      @payment_required.merge("resource" => {"url" => "https://api.example.com/other"})
    )
    merged = Mpp::X402::Server.merge_payment_required([first, other])
    decoded = Mpp::X402::Header.decode_payment_required(merged)

    assert_match(/different resources/, decoded["error"])
    assert_equal 1, decoded["accepts"].length
  end
end
