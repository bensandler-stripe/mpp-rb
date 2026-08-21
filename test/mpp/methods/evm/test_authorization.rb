# frozen_string_literal: true

require "test_helper"

class TestEvmAuthorization < Minitest::Test
  def test_challenge_hash_is_keccak_of_id_and_realm
    skip "eth gem is not available" unless eth_available?

    challenge = Mpp::Challenge.create(
      secret_key: "secret",
      realm: "api.example.com",
      method: "evm",
      intent: "charge",
      request: {"amount" => "1"}
    )
    digest = Mpp::Methods::Evm::Authorization.challenge_hash(challenge)

    assert_match(/\A0x[a-f0-9]{64}\z/, digest)
    expected = Eth::Util.keccak256("#{challenge.id}#{challenge.realm}")
    assert_equal "0x#{expected.unpack1("H*")}", digest
  end

  def test_checksum_address_round_trips_known_usdc
    address = Mpp::Methods::Evm::Assets::BASE_USDC.address
    checksummed = Mpp::Methods::Evm::Authorization.checksum_address(address.downcase)

    if eth_available?
      assert_equal address, checksummed
    else
      assert_equal address.downcase, checksummed.downcase
    end
  end

  private

  def eth_available?
    require "eth"
    true
  rescue LoadError, Gem::MissingSpecError
    false
  end
end
