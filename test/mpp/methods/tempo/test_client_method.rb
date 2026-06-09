# typed: ignore
# frozen_string_literal: true

require "test_helper"

class TestTempoExpectedRecipients < Minitest::Test
  ALLOWED = "0x0000000000000000000000000000000000000001" # same as examples/
  OTHER = "0xabcd"
  CURRENCY = "0x20c0000000000000000000000000000000000000"

  def make_method(expected_recipients:)
    Mpp::Methods::Tempo::TempoMethod.new(
      account: stub_account,
      expected_recipients: expected_recipients
    )
  end

  def make_challenge(recipient:, splits: nil)
    request = {
      "amount" => "1000000",
      "currency" => "USD",
      "recipient" => recipient
    }
    request["methodDetails"] = {"splits" => splits} if splits

    Mpp::Challenge.new(
      id: "test-id",
      method: "tempo",
      intent: "charge",
      request: request,
      realm: "test.example.com"
    )
  end

  def stub_account
    Struct.new(:address, :type) do
      def sign_hash(_digest)
        "\x33" * 64 + "\x1b"
      end
    end.new("0x0000000000000000000000000000000000000001", "local")
  end

  def test_rejects_unexpected_recipient
    method = make_method(expected_recipients: [ALLOWED])
    challenge = make_challenge(recipient: OTHER)

    err = assert_raises(ArgumentError) do
      method.create_credential(challenge)
    end
    assert_equal "Unexpected recipient: #{OTHER}", err.message
  end

  def test_allows_expected_recipient
    method = make_method(expected_recipients: [ALLOWED])
    challenge = make_challenge(recipient: ALLOWED)

    # Should pass recipient validation — no ArgumentError about unexpected recipient
    err = assert_raises(Exception) { method.create_credential(challenge) }
    refute_match(/Unexpected recipient/, err.message)
  end

  def test_expected_recipients_case_insensitive
    method = make_method(expected_recipients: [ALLOWED.downcase])
    challenge = make_challenge(recipient: ALLOWED.upcase)

    err = assert_raises(Exception) { method.create_credential(challenge) }
    refute_match(/Unexpected recipient/, err.message)
  end

  def test_rejects_unexpected_split_recipient
    method = make_method(expected_recipients: [ALLOWED])
    challenge = make_challenge(
      recipient: ALLOWED,
      splits: [{"recipient" => OTHER, "amount" => "500000"}]
    )

    err = assert_raises(ArgumentError) do
      method.create_credential(challenge)
    end
    assert_equal "Unexpected split recipient: #{OTHER}", err.message
  end

  def test_allows_expected_split_recipients
    method = make_method(expected_recipients: [ALLOWED, OTHER])
    challenge = make_challenge(
      recipient: ALLOWED,
      splits: [{"recipient" => OTHER, "amount" => "500000"}]
    )

    err = assert_raises(Exception) { method.create_credential(challenge) }
    refute_match(/Unexpected.*recipient/, err.message)
  end

  def test_skips_validation_when_no_allowlist
    method = Mpp::Methods::Tempo::TempoMethod.new(account: stub_account)
    challenge = make_challenge(recipient: OTHER)

    err = assert_raises(Exception) { method.create_credential(challenge) }
    refute_match(/Unexpected recipient/, err.message)
  end

  def test_awaiting_fee_payer_caps_gas_price_to_policy
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    method = Mpp::Methods::Tempo::TempoMethod.new(account: stub_account)
    Mpp::Methods::Tempo::Rpc.stub(:get_tx_params, [42_431, 0, 60_000_000_000]) do
      Mpp::Methods::Tempo::Rpc.stub(:estimate_gas, 21_000) do
        raw_tx, = method.send(
          :build_tempo_transfer,
          amount: 1_000_000,
          currency: CURRENCY,
          recipient: ALLOWED,
          memo: "0x#{"11" * 32}",
          rpc_url: "http://localhost:8545",
          expected_chain_id: 42_431,
          awaiting_fee_payer: true
        )

        decoded = decode_raw_tx(raw_tx, 0x78)

        assert_equal 50_000_000_000, int_value(decoded[1])
        assert_equal 60_000_000_000, int_value(decoded[2])
      end
    end
  end

  def eth_and_rlp_available?
    require "eth"
    require "rlp"
    true
  rescue LoadError
    false
  end

  def decode_raw_tx(raw_tx, prefix)
    require "rlp"

    bytes = [raw_tx.delete_prefix("0x")].pack("H*")
    assert_equal prefix, bytes.getbyte(0)
    RLP.decode(bytes[1..])
  end

  def int_value(value)
    return value if value.is_a?(Integer)
    return 0 if value.nil? || value == ""

    value.unpack1("H*").to_i(16)
  end
end
