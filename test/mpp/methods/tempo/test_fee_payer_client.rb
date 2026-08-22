# frozen_string_literal: true

require "test_helper"
require "json"
require "webmock/minitest"

class TestTempoFeePayerClient < Minitest::Test
  RAW_TX = "0xabcdef1234567890"
  SIGNED_TX = "0xsignedabcdef"

  def test_url_string_posts_eth_sign_raw_transaction
    client = Mpp::Methods::Tempo::FeePayerClient.resolve("https://sponsor.example.test")
    stub_request(:post, "https://sponsor.example.test/")
      .with { |request|
        body = JSON.parse(request.body)
        body["method"] == "eth_signRawTransaction" && body["params"] == [RAW_TX]
      }
      .to_return(status: 200, body: {jsonrpc: "2.0", result: SIGNED_TX, id: 1}.to_json)

    assert_equal SIGNED_TX, client.cosign(RAW_TX)
  end

  def test_static_headers_are_sent
    client = Mpp::Methods::Tempo::FeePayerClient.resolve({
      url: "https://sponsor.example.test",
      headers: {"X-Api-Key" => "static-key"}
    })
    stub_request(:post, "https://sponsor.example.test/")
      .with(headers: {"X-Api-Key" => "static-key"})
      .to_return(status: 200, body: {result: SIGNED_TX}.to_json)

    client.cosign(RAW_TX)
    assert_requested :post, "https://sponsor.example.test/",
      headers: {"X-Api-Key" => "static-key"}
  end

  def test_header_proc_sends_bearer_authorization
    client = Mpp::Methods::Tempo::FeePayerClient.resolve({
      url: "https://sponsor.example.test",
      headers: -> { {"Authorization" => "Bearer tok_123"} }
    })
    stub_request(:post, "https://sponsor.example.test/")
      .with(headers: {"Authorization" => "Bearer tok_123"})
      .to_return(status: 200, body: {result: SIGNED_TX}.to_json)

    client.cosign(RAW_TX)
  end

  def test_header_proc_receives_rpc_method
    paths = []
    client = Mpp::Methods::Tempo::FeePayerClient.new(
      "https://sponsor.example.test",
      headers: ->(path) {
        paths << path
        {"Authorization" => "Bearer jwt"}
      }
    )
    stub_request(:post, "https://sponsor.example.test/")
      .to_return(status: 200, body: {result: SIGNED_TX}.to_json)

    client.cosign(RAW_TX)

    assert_equal ["/eth_signRawTransaction"], paths
  end

  def test_resolve_passes_through_cosign_client
    duck = DuckFeePayer.new
    resolved = Mpp::Methods::Tempo::FeePayerClient.resolve(duck)

    assert_same duck, resolved
  end

  def test_tempo_accepts_url_and_headers
    method = Mpp::Methods::Tempo.tempo(
      recipient: "0x#{"0" * 39}1",
      fee_payer: {
        url: "https://sponsor.example.test",
        headers: -> { {"Authorization" => "Bearer tok_123"} }
      },
      intents: {"charge" => Mpp::Methods::Tempo::ChargeIntent.new}
    )

    assert_instance_of Mpp::Methods::Tempo::FeePayerClient, method.fee_payer
    assert_equal "https://sponsor.example.test", method.fee_payer.base_url
  end

  def test_tempo_keeps_local_account_fee_payer
    account = Mpp::Methods::Tempo::Account.from_key("0x#{"11" * 32}")
    method = Mpp::Methods::Tempo.tempo(
      recipient: "0x#{"0" * 39}1",
      fee_payer: account,
      intents: {"charge" => Mpp::Methods::Tempo::ChargeIntent.new}
    )

    assert_same account, method.fee_payer
  end

  def test_http_error_raises
    client = Mpp::Methods::Tempo::FeePayerClient.new("https://sponsor.example.test")
    stub_request(:post, "https://sponsor.example.test/")
      .to_return(status: 401, body: {error: "unauthorized"}.to_json)

    error = assert_raises(Mpp::VerificationFailedError) do
      client.cosign(RAW_TX)
    end
    assert_match(/HTTP 401/, error.message)
  end

  def test_rpc_error_raises
    client = Mpp::Methods::Tempo::FeePayerClient.new("https://sponsor.example.test")
    stub_request(:post, "https://sponsor.example.test/")
      .to_return(status: 200, body: {error: {message: "rejected"}}.to_json)

    error = assert_raises(Mpp::VerificationFailedError) do
      client.cosign(RAW_TX)
    end
    assert_match(/RPC error/, error.message)
  end

  def test_empty_result_raises
    client = Mpp::Methods::Tempo::FeePayerClient.new("https://sponsor.example.test")
    stub_request(:post, "https://sponsor.example.test/")
      .to_return(status: 200, body: {result: nil}.to_json)

    error = assert_raises(Mpp::VerificationFailedError) do
      client.cosign(RAW_TX)
    end
    assert_match(/no signed transaction/, error.message)
  end

  def test_config_requires_url
    error = assert_raises(ArgumentError) do
      Mpp::Methods::Tempo::FeePayerClient.resolve({headers: {"Authorization" => "Bearer x"}})
    end
    assert_match(/url is required/, error.message)
  end

  DuckFeePayer = Struct.new(:calls) do
    def initialize
      super([])
    end

    def cosign(raw_tx)
      calls << raw_tx
      "0xcosigned"
    end
  end
end
