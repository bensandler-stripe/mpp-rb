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
  REALM = "api.example.com"
  CHALLENGE_ID = "challenge-123"

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

    signed_raw = intent.send(:cosign_as_fee_payer, raw_tx, CURRENCY)
    decoded = decode_raw_tx(signed_raw, 0x76)

    assert_equal CURRENCY.downcase.delete_prefix("0x"), decoded[10].unpack1("H*")
    assert_equal 3, decoded[11].length
    assert_equal 65, decoded[13].bytesize
  end

  def test_charge_intent_rejects_fee_payer_envelope_with_access_list
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    payer = Mpp::Methods::Tempo::Account.from_key("0x#{"11" * 32}")
    fee_payer = Mpp::Methods::Tempo::Account.from_key("0x#{"22" * 32}")
    raw_tx = build_fee_payer_envelope(
      payer: payer,
      access_list: [[pack_hex(CURRENCY), [pack_hex("0x#{"00" * 32}")]]]
    )
    intent = Mpp::Methods::Tempo::ChargeIntent.new
    Mpp::Methods::Tempo.tempo(intents: {"charge" => intent}, fee_payer: fee_payer)

    error = assert_raises(Mpp::VerificationError) do
      intent.send(:cosign_as_fee_payer, raw_tx, CURRENCY, request: charge_request)
    end

    assert_includes error.message, "access list is not allowed"
  end

  def test_charge_intent_rejects_fee_payer_envelope_above_gas_policy
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    raw_tx = build_fee_payer_envelope(gas_limit: 2_000_001)
    intent = configured_fee_payer_intent

    error = assert_raises(Mpp::VerificationError) do
      intent.send(:cosign_as_fee_payer, raw_tx, CURRENCY, request: charge_request)
    end

    assert_includes error.message, "gas limit exceeds sponsor policy"
  end

  def test_charge_intent_rejects_fee_payer_envelope_above_fee_policy
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    raw_tx = build_fee_payer_envelope(max_fee_per_gas: 100_000_000_001)
    intent = configured_fee_payer_intent

    error = assert_raises(Mpp::VerificationError) do
      intent.send(:cosign_as_fee_payer, raw_tx, CURRENCY, request: charge_request)
    end

    assert_includes error.message, "max fee per gas exceeds sponsor policy"
  end

  def test_charge_intent_rejects_fee_payer_envelope_above_priority_fee_policy
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    raw_tx = build_fee_payer_envelope(
      max_priority_fee_per_gas: 50_000_000_001,
      max_fee_per_gas: 60_000_000_000
    )
    intent = configured_fee_payer_intent

    error = assert_raises(Mpp::VerificationError) do
      intent.send(:cosign_as_fee_payer, raw_tx, CURRENCY, request: charge_request)
    end

    assert_includes error.message, "max priority fee per gas exceeds sponsor policy"
  end

  def test_charge_intent_rejects_fee_payer_envelope_above_validity_window
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    raw_tx = build_fee_payer_envelope(valid_before: Time.now.to_i + (15 * 60) + 1)
    intent = configured_fee_payer_intent

    error = assert_raises(Mpp::VerificationError) do
      intent.send(:cosign_as_fee_payer, raw_tx, CURRENCY, request: charge_request)
    end

    assert_includes error.message, "validity window exceeds sponsor policy"
  end

  def test_charge_intent_rejects_fee_payer_envelope_with_extra_call
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    payment_call = Mpp::Methods::Tempo::Transaction::Call.new(to: CURRENCY, value: 0, data: transfer_data)
    raw_tx = build_fee_payer_envelope(calls: [payment_call, payment_call])
    intent = configured_fee_payer_intent

    error = assert_raises(Mpp::VerificationError) do
      intent.send(:cosign_as_fee_payer, raw_tx, CURRENCY, request: charge_request)
    end

    assert_includes error.message, "contains unauthorized extra calls"
  end

  def test_charge_intent_cosigns_fee_payer_envelope_with_challenge_bound_memo
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    raw_tx = build_fee_payer_envelope(
      calls: [Mpp::Methods::Tempo::Transaction::Call.new(to: CURRENCY, value: 0, data: transfer_with_memo_data)]
    )
    intent = configured_fee_payer_intent

    signed_raw = intent.send(
      :cosign_as_fee_payer,
      raw_tx,
      CURRENCY,
      request: charge_request,
      challenge: charge_challenge
    )
    decoded = decode_raw_tx(signed_raw, 0x76)

    assert_equal CURRENCY.downcase.delete_prefix("0x"), decoded[10].unpack1("H*")
    assert_equal 3, decoded[11].length
  end

  def test_charge_intent_rejects_fee_payer_envelope_with_plain_transfer
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    raw_tx = build_fee_payer_envelope
    intent = configured_fee_payer_intent

    error = assert_raises(Mpp::VerificationError) do
      intent.send(
        :cosign_as_fee_payer,
        raw_tx,
        CURRENCY,
        request: charge_request,
        challenge: charge_challenge
      )
    end

    assert_includes error.message, "no matching payment call found"
  end

  def test_charge_intent_rejects_fee_payer_envelope_with_wrong_challenge_memo
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    memo = Mpp::Methods::Tempo::Attribution.encode(
      server_id: REALM,
      challenge_id: "other-challenge"
    )
    raw_tx = build_fee_payer_envelope(
      calls: [
        Mpp::Methods::Tempo::Transaction::Call.new(
          to: CURRENCY,
          value: 0,
          data: transfer_with_memo_data(memo: memo)
        )
      ]
    )
    intent = configured_fee_payer_intent

    error = assert_raises(Mpp::VerificationError) do
      intent.send(
        :cosign_as_fee_payer,
        raw_tx,
        CURRENCY,
        request: charge_request,
        challenge: charge_challenge
      )
    end

    assert_includes error.message, "no matching payment call found"
  end

  def test_charge_intent_rejects_fee_payer_envelope_with_wrong_chain_id
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    raw_tx = build_fee_payer_envelope(
      chain_id: 4217,
      calls: [Mpp::Methods::Tempo::Transaction::Call.new(to: CURRENCY, value: 0, data: transfer_with_memo_data)]
    )
    intent = configured_fee_payer_intent

    error = assert_raises(Mpp::VerificationError) do
      intent.send(
        :cosign_as_fee_payer,
        raw_tx,
        CURRENCY,
        request: charge_request,
        challenge: charge_challenge
      )
    end

    assert_includes error.message, "chain ID does not match request"
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

  private

  def configured_fee_payer_intent
    intent = Mpp::Methods::Tempo::ChargeIntent.new
    fee_payer = Mpp::Methods::Tempo::Account.from_key("0x#{"22" * 32}")
    Mpp::Methods::Tempo.tempo(intents: {"charge" => intent}, fee_payer: fee_payer)
    intent
  end

  def charge_request
    Mpp::Methods::Tempo::Schemas::ChargeRequest.from_hash(
      "amount" => "1000000",
      "currency" => CURRENCY,
      "recipient" => RECIPIENT,
      "methodDetails" => {"feePayer" => true, "chainId" => 42_431}
    )
  end

  def charge_challenge
    Mpp::ChallengeEcho.new(
      id: CHALLENGE_ID,
      realm: REALM,
      method: "tempo",
      intent: "charge",
      request: ""
    )
  end

  def build_fee_payer_envelope(
    payer: Mpp::Methods::Tempo::Account.from_key("0x#{"11" * 32}"),
    chain_id: 42_431,
    max_priority_fee_per_gas: 1,
    max_fee_per_gas: 1,
    gas_limit: 1_000_000,
    calls: [Mpp::Methods::Tempo::Transaction::Call.new(to: CURRENCY, value: 0, data: transfer_data)],
    access_list: [],
    nonce_key: (1 << 256) - 1,
    valid_before: Time.now.to_i + 60,
    fee_token: nil
  )
    tx = Mpp::Methods::Tempo::Transaction::SignedTransaction.new(
      chain_id: chain_id,
      max_priority_fee_per_gas: max_priority_fee_per_gas,
      max_fee_per_gas: max_fee_per_gas,
      gas_limit: gas_limit,
      calls: calls,
      access_list: access_list,
      nonce_key: nonce_key,
      nonce: 0,
      valid_before: valid_before,
      valid_after: nil,
      fee_token: fee_token,
      sender_signature: nil,
      fee_payer_signature: Mpp::Methods::Tempo::Transaction::EMPTY_SIGNATURE,
      sender_address: payer.address,
      tempo_authorization_list: [],
      key_authorization: nil
    )
    sender_signature = payer.sign_hash(tx.signature_hash)
    "0x#{Mpp::Methods::Tempo::FeePayer.encode(tx.with(sender_signature: sender_signature)).unpack1("H*")}"
  end

  def transfer_data
    to_padded = RECIPIENT.delete_prefix("0x").downcase.rjust(64, "0")
    amount_padded = 1_000_000.to_s(16).rjust(64, "0")
    "0xa9059cbb#{to_padded}#{amount_padded}"
  end

  def transfer_with_memo_data(memo: nil)
    memo ||= Mpp::Methods::Tempo::Attribution.encode(
      server_id: REALM,
      challenge_id: CHALLENGE_ID
    )
    to_padded = RECIPIENT.delete_prefix("0x").downcase.rjust(64, "0")
    amount_padded = 1_000_000.to_s(16).rjust(64, "0")
    memo_clean = memo.delete_prefix("0x").downcase
    "0x95777d59#{to_padded}#{amount_padded}#{memo_clean}"
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
