# frozen_string_literal: true

require "test_helper"

class TestTempoTransaction < Minitest::Test
  FakeAccount = Struct.new(:address, :signature) do
    def sign_hash(_digest)
      signature || ("\x33" * 64 + "\x1b")
    end
  end

  CURRENCY = "0x20c0000000000000000000000000000000000000"
  DISALLOWED_FEE_TOKEN = "0x20c0000000000000000000000000000000000001"
  RECIPIENT = "0x742d35Cc6634c0532925a3b844bC9e7595F8fE00"
  ACCOUNT = "0x1234567890abcdef1234567890abcdef12345678"

  def test_build_signed_transfer_requires_eth_and_rlp
    original_require = Kernel.method(:require)
    Kernel.stub(:require, lambda { |name|
      raise LoadError, "cannot load such file -- #{name}" if %w[eth rlp].include?(name)

      original_require.call(name)
    }) do
      error = assert_raises(LoadError) do
        Mpp::Methods::Tempo::Transaction.build_signed_transfer(
          account: FakeAccount.new("0x1234567890abcdef1234567890abcdef12345678"),
          chain_id: 42_431,
          gas_limit: 1_000_000,
          gas_price: 1,
          nonce: 0,
          nonce_key: 0,
          currency: CURRENCY,
          transfer_data: "0xa9059cbb" + ("0" * 128),
          awaiting_fee_payer: false
        )
      end

      assert_includes error.message, "eth gem"
    end
  end

  def test_signed_transfer_places_sender_signature_in_final_envelope
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    raw_tx, chain_id = Mpp::Methods::Tempo::Transaction.build_signed_transfer(
      account: FakeAccount.new(ACCOUNT, "\x11" * 64 + "\x1b"),
      chain_id: 42_431,
      gas_limit: 1_000_000,
      gas_price: 1,
      nonce: 0,
      nonce_key: 0,
      currency: CURRENCY,
      transfer_data: transfer_data,
      awaiting_fee_payer: false
    )

    assert_equal 42_431, chain_id
    decoded = decode_raw_tx(raw_tx, 0x76)

    assert_equal 14, decoded.length
    assert_equal CURRENCY.downcase.delete_prefix("0x"), decoded[10].unpack1("H*")
    assert_equal "", decoded[11]
    assert_equal [], decoded[12]
    assert_equal "\x11" * 64 + "\x00", decoded[13]
  end

  def test_awaiting_fee_payer_builds_decodable_0x78_envelope
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    raw_tx, = Mpp::Methods::Tempo::Transaction.build_signed_transfer(
      account: FakeAccount.new(ACCOUNT, "\x22" * 64 + "\x1c"),
      chain_id: 42_431,
      gas_limit: 1_000_000,
      gas_price: 1,
      nonce: 0,
      nonce_key: (1 << 256) - 1,
      currency: CURRENCY,
      transfer_data: transfer_data,
      valid_before: 9_999_999_999,
      awaiting_fee_payer: true
    )

    decoded = decode_raw_tx(raw_tx, 0x78)

    assert_equal 14, decoded.length
    assert_equal "", decoded[10]
    assert_equal ACCOUNT.downcase.delete_prefix("0x"), decoded[11].unpack1("H*")
    assert_equal [], decoded[12]
    assert_equal "\x22" * 64 + "\x01", decoded[13]
  end

  def test_fee_payer_signature_encodes_as_tuple_in_field_11
    skip "rlp gem not available" unless rlp_available?

    tx = Mpp::Methods::Tempo::Transaction::SignedTransaction.new(
      chain_id: 42_431,
      max_priority_fee_per_gas: 1,
      max_fee_per_gas: 1,
      gas_limit: 1_000_000,
      calls: [Mpp::Methods::Tempo::Transaction::Call.new(to: CURRENCY, value: 0, data: transfer_data)],
      access_list: [],
      nonce_key: 0,
      nonce: 0,
      valid_before: nil,
      valid_after: nil,
      fee_token: CURRENCY,
      sender_signature: "\x44" * 64 + "\x1b",
      fee_payer_signature: "\x55" * 64 + "\x1c",
      sender_address: ACCOUNT,
      tempo_authorization_list: [],
      key_authorization: nil
    )

    decoded = RLP.decode(tx.encoded_2718[1..])

    assert_equal 14, decoded.length
    assert_equal ["\x01", "\x55" * 32, "\x55" * 32], decoded[11]
    assert_equal [], decoded[12]
    assert_equal "\x44" * 64 + "\x00", decoded[13]
  end

  def test_charge_intent_cosigns_awaiting_fee_payer_envelope
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    payer = Mpp::Methods::Tempo::Account.from_key("0x#{"11" * 32}")
    fee_payer = Mpp::Methods::Tempo::Account.from_key("0x#{"22" * 32}")
    raw_tx, = Mpp::Methods::Tempo::Transaction.build_signed_transfer(
      account: payer,
      chain_id: 42_431,
      gas_limit: 1_000_000,
      gas_price: 1,
      nonce: 0,
      nonce_key: (1 << 256) - 1,
      currency: CURRENCY,
      transfer_data: transfer_data,
      valid_before: Time.now.to_i + 60,
      awaiting_fee_payer: true
    )
    intent = Mpp::Methods::Tempo::ChargeIntent.new
    Mpp::Methods::Tempo.tempo(intents: {"charge" => intent}, fee_payer: fee_payer)

    signed_raw, = intent.send(:cosign_as_fee_payer, raw_tx, CURRENCY)
    decoded = decode_raw_tx(signed_raw, 0x76)

    assert_equal CURRENCY.downcase.delete_prefix("0x"), decoded[10].unpack1("H*")
    assert_equal 3, decoded[11].length
    assert_equal 65, decoded[13].bytesize
  end

  def test_charge_intent_cosigns_fee_payer_envelope_with_access_list
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    payer = Mpp::Methods::Tempo::Account.from_key("0x#{"11" * 32}")
    fee_payer = Mpp::Methods::Tempo::Account.from_key("0x#{"22" * 32}")
    access_list = [[pack_hex(CURRENCY), [pack_hex("0x#{"00" * 32}")]]]
    tx = Mpp::Methods::Tempo::Transaction::SignedTransaction.new(
      chain_id: 42_431,
      max_priority_fee_per_gas: 1,
      max_fee_per_gas: 1,
      gas_limit: 1_000_000,
      calls: [Mpp::Methods::Tempo::Transaction::Call.new(to: CURRENCY, value: 0, data: transfer_data)],
      access_list: access_list,
      nonce_key: (1 << 256) - 1,
      nonce: 0,
      valid_before: Time.now.to_i + 60,
      valid_after: nil,
      fee_token: nil,
      sender_signature: nil,
      fee_payer_signature: Mpp::Methods::Tempo::Transaction::EMPTY_SIGNATURE,
      sender_address: payer.address,
      tempo_authorization_list: [],
      key_authorization: nil
    )
    sender_signature = payer.sign_hash(tx.signature_hash)
    raw_tx = "0x#{Mpp::Methods::Tempo::FeePayer.encode(tx.with(sender_signature: sender_signature)).unpack1("H*")}"
    intent = Mpp::Methods::Tempo::ChargeIntent.new
    Mpp::Methods::Tempo.tempo(intents: {"charge" => intent}, fee_payer: fee_payer)

    signed_raw, payload = intent.send(:cosign_as_fee_payer, raw_tx, CURRENCY)
    decoded = decode_raw_tx(signed_raw, 0x76)

    assert_equal access_list, decoded[5]
    assert_equal 3, decoded[11].length
    assert_equal 65, decoded[13].bytesize

    # The simulated tx must carry the same access list as the broadcast tx.
    sim_access_list = payload.dig("blockStateCalls", 0, "calls", 0, "accessList")
    assert_equal CURRENCY.downcase, sim_access_list.dig(0, "address").downcase
    assert_equal ["0x#{"00" * 32}"], sim_access_list.dig(0, "storageKeys")
  end

  def test_charge_intent_rejects_tempo_authorization_list
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    payer = Mpp::Methods::Tempo::Account.from_key("0x#{"11" * 32}")
    fee_payer = Mpp::Methods::Tempo::Account.from_key("0x#{"22" * 32}")
    tx = Mpp::Methods::Tempo::Transaction::SignedTransaction.new(
      chain_id: 42_431,
      max_priority_fee_per_gas: 1,
      max_fee_per_gas: 1,
      gas_limit: 1_000_000,
      calls: [Mpp::Methods::Tempo::Transaction::Call.new(to: CURRENCY, value: 0, data: transfer_data)],
      access_list: [],
      nonce_key: (1 << 256) - 1,
      nonce: 0,
      valid_before: Time.now.to_i + 60,
      valid_after: nil,
      fee_token: nil,
      sender_signature: nil,
      fee_payer_signature: Mpp::Methods::Tempo::Transaction::EMPTY_SIGNATURE,
      sender_address: payer.address,
      tempo_authorization_list: [[pack_hex(CURRENCY)]],
      key_authorization: nil
    )
    sender_signature = payer.sign_hash(tx.signature_hash)
    raw_tx = "0x#{Mpp::Methods::Tempo::FeePayer.encode(tx.with(sender_signature: sender_signature)).unpack1("H*")}"
    intent = Mpp::Methods::Tempo::ChargeIntent.new
    Mpp::Methods::Tempo.tempo(intents: {"charge" => intent}, fee_payer: fee_payer)

    error = assert_raises(Mpp::VerificationError) do
      intent.send(:cosign_as_fee_payer, raw_tx, CURRENCY)
    end
    assert_includes error.message, "tempo_authorization_list"
  end

  def test_charge_intent_rejects_key_authorization
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    payer = Mpp::Methods::Tempo::Account.from_key("0x#{"11" * 32}")
    fee_payer = Mpp::Methods::Tempo::Account.from_key("0x#{"22" * 32}")
    tx = Mpp::Methods::Tempo::Transaction::SignedTransaction.new(
      chain_id: 42_431,
      max_priority_fee_per_gas: 1,
      max_fee_per_gas: 1,
      gas_limit: 1_000_000,
      calls: [Mpp::Methods::Tempo::Transaction::Call.new(to: CURRENCY, value: 0, data: transfer_data)],
      access_list: [],
      nonce_key: (1 << 256) - 1,
      nonce: 0,
      valid_before: Time.now.to_i + 60,
      valid_after: nil,
      fee_token: nil,
      sender_signature: nil,
      fee_payer_signature: Mpp::Methods::Tempo::Transaction::EMPTY_SIGNATURE,
      sender_address: payer.address,
      tempo_authorization_list: [],
      key_authorization: RLP.encode([pack_hex(CURRENCY)])
    )
    sender_signature = payer.sign_hash(tx.signature_hash)
    raw_tx = "0x#{Mpp::Methods::Tempo::FeePayer.encode(tx.with(sender_signature: sender_signature)).unpack1("H*")}"
    intent = Mpp::Methods::Tempo::ChargeIntent.new
    Mpp::Methods::Tempo.tempo(intents: {"charge" => intent}, fee_payer: fee_payer)

    error = assert_raises(Mpp::VerificationError) do
      intent.send(:cosign_as_fee_payer, raw_tx, CURRENCY)
    end
    assert_includes error.message, "key_authorization"
  end

  def test_charge_intent_rejects_non_allowlisted_fee_token
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    payer = Mpp::Methods::Tempo::Account.from_key("0x#{"11" * 32}")
    fee_payer = Mpp::Methods::Tempo::Account.from_key("0x#{"22" * 32}")
    raw_tx, = Mpp::Methods::Tempo::Transaction.build_signed_transfer(
      account: payer,
      chain_id: 42_431,
      gas_limit: 1_000_000,
      gas_price: 1,
      nonce: 0,
      nonce_key: (1 << 256) - 1,
      currency: CURRENCY,
      transfer_data: transfer_data,
      valid_before: Time.now.to_i + 60,
      awaiting_fee_payer: true
    )
    intent = Mpp::Methods::Tempo::ChargeIntent.new
    Mpp::Methods::Tempo.tempo(
      intents: {"charge" => intent},
      fee_payer: fee_payer,
      fee_payer_allowed_fee_tokens: [CURRENCY]
    )

    error = assert_raises(Mpp::VerificationError) do
      intent.send(:cosign_as_fee_payer, raw_tx, DISALLOWED_FEE_TOKEN)
    end
    assert_includes error.message, "not allowed by fee payer policy"
  end

  def test_charge_intent_default_allowlist_rejects_non_default_fee_token
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    payer = Mpp::Methods::Tempo::Account.from_key("0x#{"11" * 32}")
    fee_payer = Mpp::Methods::Tempo::Account.from_key("0x#{"22" * 32}")
    raw_tx, = Mpp::Methods::Tempo::Transaction.build_signed_transfer(
      account: payer,
      chain_id: 42_431,
      gas_limit: 1_000_000,
      gas_price: 1,
      nonce: 0,
      nonce_key: (1 << 256) - 1,
      currency: CURRENCY,
      transfer_data: transfer_data,
      valid_before: Time.now.to_i + 60,
      awaiting_fee_payer: true
    )
    intent = Mpp::Methods::Tempo::ChargeIntent.new
    Mpp::Methods::Tempo.tempo(intents: {"charge" => intent}, fee_payer: fee_payer)

    error = assert_raises(Mpp::VerificationError) do
      intent.send(:cosign_as_fee_payer, raw_tx, DISALLOWED_FEE_TOKEN)
    end
    assert_includes error.message, "not allowed by fee payer policy"
  end

  # The simulate payload must target the co-signed tx: the recovered sender as
  # `from`, the sponsor fields the node needs (feeToken, feePayerSignature), the
  # payment calls, the expiring nonceKey, the validity window, and validation off.
  def test_cosign_returns_simulate_payload_with_sponsor_abi
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    _intent, payload, payer = cosign_fixture
    tx_request = payload.dig("blockStateCalls", 0, "calls", 0)

    assert_equal false, payload["validation"]
    assert_equal "0x76", tx_request["type"]
    # `from` must be the sender recovered from the co-signed tx.
    assert_equal payer.address.downcase, tx_request["from"].downcase
    assert_equal CURRENCY.downcase, tx_request["feeToken"].downcase
    assert tx_request["feePayerSignature"].is_a?(Hash), "feePayerSignature must be present"
    assert tx_request["nonceKey"].start_with?("0x"), "nonceKey must be a hex quantity"
    assert tx_request["validBefore"].start_with?("0x"), "validBefore must be present"
    # Single call is carried via the top-level to/value/input shorthand (not the
    # `calls` array) to avoid the node injecting a phantom CREATE call after it.
    assert_nil tx_request["calls"]
    assert_equal CURRENCY.downcase, tx_request["to"].downcase
    assert_equal "0x0", tx_request["value"]
    assert tx_request["input"].start_with?("0xa9059cbb"), "input must be the transfer calldata"
  end

  # A reverting simulation must block the broadcast so we never pay gas for a
  # failing transaction.
  def test_simulate_before_broadcast_rejects_revert
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    intent, payload = cosign_fixture
    revert = {"blocks" => [{"calls" => [{"status" => "0x0", "error" => {"message" => "execution reverted"}}]}]}

    error = Mpp::Methods::Tempo::Rpc.stub(:call, ->(_url, method, _params) {
      assert_equal "tempo_simulateV1", method
      revert
    }) do
      assert_raises(Mpp::VerificationError) do
        intent.send(:simulate_before_broadcast, payload, "https://rpc.example.test")
      end
    end
    assert_includes error.message, "would revert"
    assert_includes error.message, "execution reverted"
  end

  # A successful simulation must let the broadcast proceed.
  def test_simulate_before_broadcast_accepts_success
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    intent, payload = cosign_fixture
    success = {"blocks" => [{"calls" => [{"status" => "0x1"}]}]}

    Mpp::Methods::Tempo::Rpc.stub(:call, ->(_url, _method, _params) { success }) do
      assert_nil intent.send(:simulate_before_broadcast, payload, "https://rpc.example.test")
    end
  end

  # If the simulation RPC itself errors, fail closed.
  def test_simulate_before_broadcast_fails_closed_on_rpc_error
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    intent, payload = cosign_fixture

    error = Mpp::Methods::Tempo::Rpc.stub(:call, ->(_url, _method, _params) { raise "node unavailable" }) do
      assert_raises(Mpp::VerificationError) do
        intent.send(:simulate_before_broadcast, payload, "https://rpc.example.test")
      end
    end
    assert_includes error.message, "Pre-broadcast simulation failed"
  end

  private

  # Co-sign an awaiting-fee-payer envelope; returns [intent, simulate_payload, payer].
  def cosign_fixture
    payer = Mpp::Methods::Tempo::Account.from_key("0x#{"11" * 32}")
    fee_payer = Mpp::Methods::Tempo::Account.from_key("0x#{"22" * 32}")
    raw_tx, = Mpp::Methods::Tempo::Transaction.build_signed_transfer(
      account: payer,
      chain_id: 42_431,
      gas_limit: 1_000_000,
      gas_price: 1,
      nonce: 0,
      nonce_key: (1 << 256) - 1,
      currency: CURRENCY,
      transfer_data: transfer_data,
      valid_before: Time.now.to_i + 60,
      awaiting_fee_payer: true
    )
    intent = Mpp::Methods::Tempo::ChargeIntent.new(rpc_url: "https://rpc.example.test")
    Mpp::Methods::Tempo.tempo(intents: {"charge" => intent}, fee_payer: fee_payer)

    _signed_raw, payload = intent.send(:cosign_as_fee_payer, raw_tx, CURRENCY)
    [intent, payload, payer]
  end

  def transfer_data
    to_padded = RECIPIENT.delete_prefix("0x").downcase.rjust(64, "0")
    amount_padded = 1_000_000.to_s(16).rjust(64, "0")
    "0xa9059cbb#{to_padded}#{amount_padded}"
  end

  def decode_raw_tx(raw_tx, prefix)
    bytes = [raw_tx.delete_prefix("0x")].pack("H*")

    assert_equal prefix, bytes.getbyte(0)
    RLP.decode(bytes[1..])
  end

  def pack_hex(value)
    [value.delete_prefix("0x")].pack("H*")
  end

  def eth_and_rlp_available?
    require "eth"
    rlp_available?
  rescue LoadError
    false
  end

  def rlp_available?
    require "rlp"
    true
  rescue LoadError
    false
  end
end
