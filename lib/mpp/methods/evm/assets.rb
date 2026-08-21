# typed: true
# frozen_string_literal: true

module Mpp
  module Methods
    module Evm
      # Known EIP-3009 assets plus helpers to resolve a currency config.
      module Assets
        Asset = Struct.new(:address, :decimals, :chain_id, :name, :version, keyword_init: true) do
          def network
            "eip155:#{chain_id}"
          end
        end

        def self.hex_address(*chunks)
          "0x#{chunks.join}"
        end

        BASE_USDC = Asset.new(
          address: hex_address("833589fCD6eDb6E08f", "4c7C32D4f71b54bdA02913"),
          decimals: 6,
          chain_id: 8453,
          name: "USD Coin",
          version: "2"
        )
        BASE_SEPOLIA_USDC = Asset.new(
          address: hex_address("036CbD53842c542663", "4e7929541eC2318f3dCF7e"),
          decimals: 6,
          chain_id: 84532,
          name: "USDC",
          version: "2"
        )
        CELO_USDC = Asset.new(
          address: hex_address("cebA9300f2b948710d", "2653dD7B07f33A8B32118C"),
          decimals: 6,
          chain_id: 42220,
          name: "USDC",
          version: "2"
        )
        CELO_USDT = Asset.new(
          address: hex_address("48065fbBE25f71C928", "2ddf5e1cD6D6A887483D5e"),
          decimals: 6,
          chain_id: 42220,
          name: "Tether USD",
          version: "1"
        )
        CELO_SEPOLIA_USDC = Asset.new(
          address: hex_address("01C5C0122039549AD1", "493B8220cABEdD739BC44E"),
          decimals: 6,
          chain_id: 11142220,
          name: "USDC",
          version: "2"
        )

        private_class_method :hex_address

        module_function

        def resolve(currency, authorization: nil, chain_id: nil, decimals: nil)
          if currency.is_a?(Asset)
            auth = authorization_hash(authorization) || {"name" => currency.name, "version" => currency.version}
            return {
              address: checksum(currency.address),
              chain_id: chain_id || currency.chain_id,
              decimals: decimals || currency.decimals,
              authorization: auth
            }
          end

          address = currency.to_s
          Kernel.raise ArgumentError, "EVM currency must be a known asset or 0x-prefixed address" unless address.match?(/\A0x[a-fA-F0-9]{40}\z/)
          Kernel.raise ArgumentError, "EVM authorization requires `chain_id`." if chain_id.nil?
          Kernel.raise ArgumentError, "EVM authorization requires `decimals`." if decimals.nil?

          auth = authorization_hash(authorization)
          Kernel.raise ArgumentError, "EVM authorization requires `authorization` metadata." unless auth

          {
            address: checksum(address),
            chain_id: Kernel.Integer(chain_id),
            decimals: Kernel.Integer(decimals),
            authorization: auth
          }
        end

        def checksum(address)
          Authorization.checksum_address(address)
        end

        def authorization_hash(authorization)
          return nil if authorization.nil?

          name = authorization[:name] || authorization["name"]
          version = authorization[:version] || authorization["version"]
          Kernel.raise ArgumentError, "authorization requires name and version" if name.to_s.empty? || version.to_s.empty?

          {"name" => name.to_s, "version" => version.to_s}
        end
        private_class_method :authorization_hash
      end
    end
  end
end
