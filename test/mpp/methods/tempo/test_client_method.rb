# typed: ignore
# frozen_string_literal: true

require "test_helper"

class TestTempoExpectedRecipients < Minitest::Test
  ALLOWED = "0x0000000000000000000000000000000000000001" # same as examples/
  OTHER = "0xabcd"

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
    Struct.new(:address, :type).new("0x0000000000000000000000000000000000000001", "local")
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
end

class TestTempoChainPinning < Minitest::Test
  RECIPIENT = "0x0000000000000000000000000000000000000001"
  SIGNED_TX = "0xdeadbeef"

  def stub_account
    Struct.new(:address, :type).new(RECIPIENT, "local")
  end

  def make_method(chain_id:)
    Mpp::Methods::Tempo::TempoMethod.new(account: stub_account, chain_id: chain_id)
  end

  def make_challenge(chain_id: nil)
    request = {
      "amount" => "1000000",
      "currency" => "USD",
      "recipient" => RECIPIENT
    }
    request["methodDetails"] = {"chainId" => chain_id} if chain_id

    Mpp::Challenge.new(
      id: "test-id",
      method: "tempo",
      intent: "charge",
      request: request,
      realm: "test.example.com"
    )
  end

  # The pin check runs before `build_tempo_transfer`, so stubbing it keeps the
  # positive cases deterministic and network-free while still exercising the pin.
  # `source_chain_id` is the chain the transfer reports (used in the DID);
  # `expected_chain_id` is the resolved pin asserted as passed downstream.
  def with_stubbed_transfer(method, source_chain_id:, expected_chain_id:)
    stub = lambda do |*, **kwargs|
      assert_equal expected_chain_id, kwargs[:expected_chain_id]
      [SIGNED_TX, source_chain_id]
    end
    method.stub(:build_tempo_transfer, stub) { yield }
  end

  def test_rejects_conflicting_chain_id
    method = make_method(chain_id: 42_431)
    challenge = make_challenge(chain_id: 1)

    err = assert_raises(Mpp::Methods::Tempo::TransactionError) do
      method.create_credential(challenge)
    end
    assert_equal "Chain ID mismatch: expected 42431, got 1", err.message
  end

  def test_accepts_matching_chain_id
    method = make_method(chain_id: 42_431)
    challenge = make_challenge(chain_id: 42_431)

    credential = with_stubbed_transfer(method, source_chain_id: 42_431, expected_chain_id: 42_431) do
      method.create_credential(challenge)
    end

    assert_equal "did:pkh:eip155:42431:#{RECIPIENT}", credential.source
  end

  def test_accepts_matching_string_pinned_chain_id
    # chain_id may be configured as a String (e.g. from ENV); it should be
    # normalized before comparison so a matching chain is not rejected.
    method = make_method(chain_id: "42431")
    challenge = make_challenge(chain_id: 42_431)

    credential = with_stubbed_transfer(method, source_chain_id: 42_431, expected_chain_id: 42_431) do
      method.create_credential(challenge)
    end

    assert_equal "did:pkh:eip155:42431:#{RECIPIENT}", credential.source
  end

  def test_unpinned_accepts_any_chain_id
    method = make_method(chain_id: nil)
    challenge = make_challenge(chain_id: 1)

    # chain 1 is unknown to CHAIN_RPC_URLS and no pin is set, so no expected
    # chain is enforced downstream; the transfer's reported chain drives the DID.
    credential = with_stubbed_transfer(method, source_chain_id: 1, expected_chain_id: nil) do
      method.create_credential(challenge)
    end

    assert_equal "did:pkh:eip155:1:#{RECIPIENT}", credential.source
  end

  def test_omitted_challenge_chain_id_uses_pin
    method = make_method(chain_id: 42_431)
    challenge = make_challenge(chain_id: nil)

    credential = with_stubbed_transfer(method, source_chain_id: 42_431, expected_chain_id: 42_431) do
      method.create_credential(challenge)
    end

    assert_equal "did:pkh:eip155:42431:#{RECIPIENT}", credential.source
  end
end
