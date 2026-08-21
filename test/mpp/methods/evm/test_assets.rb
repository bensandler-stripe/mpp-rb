# frozen_string_literal: true

require "test_helper"

class TestEvmAssets < Minitest::Test
  def test_known_base_sepolia_usdc
    asset = Mpp::Methods::Evm::Assets::BASE_SEPOLIA_USDC

    assert_match(/\A0x[0-9a-fA-F]{40}\z/, asset.address)
    assert_equal 6, asset.decimals
    assert_equal 84532, asset.chain_id
    assert_equal "eip155:84532", asset.network
  end

  def test_resolve_known_asset
    resolved = Mpp::Methods::Evm::Assets.resolve(Mpp::Methods::Evm::Assets::BASE_USDC)

    assert_equal 8453, resolved[:chain_id]
    assert_equal 6, resolved[:decimals]
    assert_equal "USD Coin", resolved[:authorization]["name"]
    assert_equal "2", resolved[:authorization]["version"]
  end

  def test_resolve_raw_address_requires_metadata
    raw = format("0x%040d", 3)
    assert_raises(ArgumentError) do
      Mpp::Methods::Evm::Assets.resolve(raw)
    end

    resolved = Mpp::Methods::Evm::Assets.resolve(
      raw,
      chain_id: 8453,
      decimals: 6,
      authorization: {name: "USD Coin", version: "2"}
    )
    assert_equal 8453, resolved[:chain_id]
  end
end
