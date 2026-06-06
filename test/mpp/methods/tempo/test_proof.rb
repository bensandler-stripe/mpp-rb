# frozen_string_literal: true

require "test_helper"

# Tests for EIP-712 Tempo proof credentials (zero-amount wallet-ownership proofs).
# The signed typed data binds both the challenge id AND the server realm, and the
# wallet is bound via the recovered signer matching the credential source address.
class TestTempoProof < Minitest::Test
  Proof = Mpp::Methods::Tempo::Proof

  # Well-known test private keys (deterministic addresses).
  KEY_A = "0x4c0883a69102937d6231471b5dbb6204fe512961708279f01a7f7e1df7a8b9e2"
  KEY_B = "0x4646464646464646464646464646464646464646464646464646464646464646"

  CHAIN_ID = 1
  CHALLENGE_ID = "ch_test_123"
  REALM = "api.example.com"

  def setup
    @eth_available = begin
      require "eth"
      true
    rescue LoadError
      false
    end
  end

  def account(key)
    Mpp::Methods::Tempo::Account.from_key(key)
  end

  # --- ABI conformance (the create-intent/challenge ABI fixture) ---

  def test_domain_version_is_2
    assert_equal "2", Proof::DOMAIN_VERSION
  end

  def test_proof_type_hash_binds_challenge_id_and_realm
    assert_equal "Proof(string challengeId,string realm)", Proof::PROOF_TYPE_HASH
  end

  # --- source DID (wallet binding carrier) ---

  def test_source_did_construction
    source = Proof.source(address: "0xAbC0000000000000000000000000000000000001", chain_id: 8453)
    assert_equal "did:pkh:eip155:8453:0xAbC0000000000000000000000000000000000001", source
  end

  def test_parse_source_valid
    parsed = Proof.parse_source("did:pkh:eip155:1:0xAbC0000000000000000000000000000000000001")
    assert_equal 1, parsed[:chain_id]
    assert_equal "0xAbC0000000000000000000000000000000000001", parsed[:address]
  end

  def test_parse_source_rejects_malformed
    assert_nil Proof.parse_source("not-a-did")
    assert_nil Proof.parse_source("did:pkh:eip155:1:0xshort")
    assert_nil Proof.parse_source("did:pkh:eip155:01:0xAbC0000000000000000000000000000000000001")
    assert_nil Proof.parse_source("did:pkh:other:1:0xAbC0000000000000000000000000000000000001")
  end

  # --- sign / verify round trip ---

  def test_sign_verify_round_trip
    skip "eth gem not available" unless @eth_available

    acct = account(KEY_A)
    sig = Proof.sign(account: acct, chain_id: CHAIN_ID, challenge_id: CHALLENGE_ID, realm: REALM)

    assert Proof.verify(
      address: acct.address,
      chain_id: CHAIN_ID,
      challenge_id: CHALLENGE_ID,
      realm: REALM,
      signature: sig
    )
  end

  # --- realm binding ---

  def test_verify_rejects_realm_mismatch
    skip "eth gem not available" unless @eth_available

    acct = account(KEY_A)
    sig = Proof.sign(account: acct, chain_id: CHAIN_ID, challenge_id: CHALLENGE_ID, realm: REALM)

    refute Proof.verify(
      address: acct.address,
      chain_id: CHAIN_ID,
      challenge_id: CHALLENGE_ID,
      realm: "evil.example.com",
      signature: sig
    )
  end

  # --- wallet binding ---

  def test_verify_rejects_wrong_address
    skip "eth gem not available" unless @eth_available

    acct = account(KEY_A)
    other = account(KEY_B)
    sig = Proof.sign(account: acct, chain_id: CHAIN_ID, challenge_id: CHALLENGE_ID, realm: REALM)

    refute Proof.verify(
      address: other.address,
      chain_id: CHAIN_ID,
      challenge_id: CHALLENGE_ID,
      realm: REALM,
      signature: sig
    )
  end

  # --- challenge id binding ---

  def test_verify_rejects_challenge_id_mismatch
    skip "eth gem not available" unless @eth_available

    acct = account(KEY_A)
    sig = Proof.sign(account: acct, chain_id: CHAIN_ID, challenge_id: CHALLENGE_ID, realm: REALM)

    refute Proof.verify(
      address: acct.address,
      chain_id: CHAIN_ID,
      challenge_id: "ch_other",
      realm: REALM,
      signature: sig
    )
  end

  # --- chain id binding ---

  def test_verify_rejects_chain_id_mismatch
    skip "eth gem not available" unless @eth_available

    acct = account(KEY_A)
    sig = Proof.sign(account: acct, chain_id: CHAIN_ID, challenge_id: CHALLENGE_ID, realm: REALM)

    refute Proof.verify(
      address: acct.address,
      chain_id: 999,
      challenge_id: CHALLENGE_ID,
      realm: REALM,
      signature: sig
    )
  end

  # --- uint256 encoding (domain chainId) regression ---

  def test_uint256_handles_values_above_64_bits
    skip "eth gem not available" unless @eth_available

    # A chain id larger than 2**64 must not silently truncate; sign/verify must round-trip.
    big_chain = (1 << 200) + 7
    acct = account(KEY_A)
    sig = Proof.sign(account: acct, chain_id: big_chain, challenge_id: CHALLENGE_ID, realm: REALM)

    assert Proof.verify(address: acct.address, chain_id: big_chain, challenge_id: CHALLENGE_ID, realm: REALM, signature: sig)
    refute Proof.verify(address: acct.address, chain_id: big_chain + 1, challenge_id: CHALLENGE_ID, realm: REALM, signature: sig)
  end

  # --- server-side verify path (ChargeIntent#verify -> verify_proof) ---

  def server_proof_credential(realm:, signed_realm:, chain_id: 4217, challenge_id: "ch_srv_1")
    acct = account(KEY_A)
    sig = Proof.sign(account: acct, chain_id: chain_id, challenge_id: challenge_id, realm: signed_realm)
    Mpp::Credential.new(
      challenge: Mpp::ChallengeEcho.new(
        id: challenge_id, realm: realm, method: "tempo", intent: "charge", request: ""
      ),
      payload: {"type" => "proof", "signature" => sig},
      source: Proof.source(address: acct.address, chain_id: chain_id)
    )
  end

  def zero_amount_request
    {"amount" => "0", "currency" => "0x00", "recipient" => "0x01"}
  end

  def test_server_verify_proof_round_trip
    skip "eth gem not available" unless @eth_available

    intent = Mpp::Methods::Tempo::ChargeIntent.new
    credential = server_proof_credential(realm: REALM, signed_realm: REALM)

    receipt = intent.verify(credential, zero_amount_request)
    assert_equal "ch_srv_1", receipt.reference
  end

  def test_server_verify_proof_rejects_realm_mismatch
    skip "eth gem not available" unless @eth_available

    intent = Mpp::Methods::Tempo::ChargeIntent.new
    # Signed for a different realm than the challenge echo claims.
    credential = server_proof_credential(realm: REALM, signed_realm: "evil.example.com")

    err = assert_raises(Mpp::VerificationError) do
      intent.verify(credential, zero_amount_request)
    end
    assert_match(/does not match source/, err.message)
  end

  def test_server_verify_proof_rejects_nonzero_amount
    skip "eth gem not available" unless @eth_available

    intent = Mpp::Methods::Tempo::ChargeIntent.new
    credential = server_proof_credential(realm: REALM, signed_realm: REALM)

    err = assert_raises(Mpp::VerificationError) do
      intent.verify(credential, {"amount" => "100", "currency" => "0x00", "recipient" => "0x01"})
    end
    assert_match(/zero-amount/, err.message)
  end

  # --- end-to-end through the client method (proves realm wiring) ---

  def test_client_create_credential_proof_mode_binds_realm
    skip "eth gem not available" unless @eth_available

    acct = account(KEY_A)
    method = Mpp::Methods::Tempo::TempoMethod.new(account: acct, chain_id: CHAIN_ID)

    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: REALM,
      method: "tempo",
      intent: "charge",
      request: {"amount" => "0", "currency" => "0x00", "recipient" => "0x01", "methodDetails" => {}},
      expires: (Time.now.utc + 300).strftime("%Y-%m-%dT%H:%M:%S.%LZ")
    )

    credential = method.create_credential(challenge, mode: :proof)

    assert_equal "proof", credential.payload["type"]
    source = Proof.parse_source(credential.source)
    assert_equal acct.address.downcase, source[:address].downcase

    # Verifies only with the real challenge realm, not a forged one.
    assert Proof.verify(
      address: source[:address],
      chain_id: CHAIN_ID,
      challenge_id: challenge.id,
      realm: challenge.realm,
      signature: credential.payload["signature"]
    )
    refute Proof.verify(
      address: source[:address],
      chain_id: CHAIN_ID,
      challenge_id: challenge.id,
      realm: "evil.example.com",
      signature: credential.payload["signature"]
    )
  end
end
