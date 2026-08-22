# frozen_string_literal: true

require "mpp-rb"

module TempoFeepayerExample
  module_function

  def recipient
    ENV.fetch("RECIPIENT_ADDRESS", "0x0000000000000000000000000000000000000001")
  end

  def secret_key
    ENV.fetch("SECRET_KEY", "test-secret")
  end

  def fee_payer_url
    ENV.fetch("FEE_PAYER_URL", "https://sponsor.example.test")
  end

  def fee_payer_token
    ENV.fetch("FEE_PAYER_TOKEN", "test-fee-payer-token")
  end

  def rpc_url
    ENV.fetch("TEMPO_RPC_URL", Mpp::Methods::Tempo::Defaults::TESTNET_RPC_URL)
  end

  def realm
    ENV.fetch("MPP_REALM", "localhost:4567")
  end

  def handler
    Mpp.create(
      method: Mpp::Methods::Tempo.tempo(
        chain_id: Mpp::Methods::Tempo::Defaults::TESTNET_CHAIN_ID,
        currency: Mpp::Methods::Tempo::Defaults::PATH_USD,
        recipient: recipient,
        rpc_url: rpc_url,
        fee_payer: {
          url: fee_payer_url,
          headers: -> { {"Authorization" => "Bearer #{fee_payer_token}"} }
        },
        intents: {"charge" => Mpp::Methods::Tempo::ChargeIntent.new}
      ),
      realm: realm,
      secret_key: secret_key
    )
  end
end
