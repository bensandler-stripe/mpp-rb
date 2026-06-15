# typed: false
# frozen_string_literal: true

module Mpp
  module Methods
    module Tempo
      # EIP-712 proof credentials for zero-amount challenges.
      #
      # Domain: { name: "MPP", version: "2", chainId }
      # Types:  { Proof: [{ name: "challengeId", type: "string" }, { name: "realm", type: "string" }] }
      # Message: { challengeId: <challenge.id>, realm: <challenge.realm> }
      module Proof
        DOMAIN_NAME = "MPP"
        DOMAIN_VERSION = "2"

        # EIP-712 domain separator type hash
        DOMAIN_TYPE_HASH = "EIP712Domain(string name,string version,uint256 chainId)"
        PROOF_TYPE_HASH = "Proof(string challengeId,string realm)"

        module_function

        def keccak256(data)
          Kernel.require "eth"
          Eth::Util.keccak256(data)
        end

        # Compute the EIP-712 domain separator.
        def domain_separator(chain_id)
          keccak256(
            abi_encode(
              keccak256(DOMAIN_TYPE_HASH),
              keccak256(DOMAIN_NAME),
              keccak256(DOMAIN_VERSION),
              uint256(chain_id)
            )
          )
        end

        # Compute the EIP-712 struct hash for Proof(challengeId, realm).
        def struct_hash(challenge_id, realm)
          keccak256(
            abi_encode(
              keccak256(PROOF_TYPE_HASH),
              keccak256(challenge_id),
              keccak256(realm)
            )
          )
        end

        # Compute the full EIP-712 signing hash.
        def signing_hash(chain_id:, challenge_id:, realm:)
          keccak256(
            "\x19\x01".b + domain_separator(chain_id) + struct_hash(challenge_id, realm)
          )
        end

        # Sign a proof credential (client-side).
        def sign(account:, chain_id:, challenge_id:, realm:)
          hash = signing_hash(chain_id: chain_id, challenge_id: challenge_id, realm: realm)
          sig = account.sign_hash(hash)
          "0x#{sig.unpack1("H*")}"
        end

        # Verify a proof credential signature (server-side).
        def verify(address:, chain_id:, challenge_id:, realm:, signature:)
          Kernel.require "eth"

          hash = signing_hash(chain_id: chain_id, challenge_id: challenge_id, realm: realm)
          sig_bytes = [signature.delete_prefix("0x")].pack("H*")

          # Recover the signer address from the signature
          recovered = recover_address(hash, sig_bytes)
          return false unless recovered

          recovered.downcase == address.downcase
        end

        # Construct source DID for proof credentials.
        def source(address:, chain_id:)
          "did:pkh:eip155:#{chain_id}:#{address}"
        end

        # Parse a proof source DID. Returns { address:, chain_id: } or nil.
        def parse_source(source_str)
          match = source_str.match(/\Adid:pkh:eip155:(0|[1-9]\d*):(.+)\z/)
          return nil unless match

          chain_id = Integer(match[1])
          address = match[2]
          return nil unless address.match?(/\A0x[a-fA-F0-9]{40}\z/)

          {address: address, chain_id: chain_id}
        rescue ArgumentError
          nil
        end

        # ABI-encode values (packed 32-byte words).
        def abi_encode(*values)
          values.map { |v|
            case v
            when String
              v.b.rjust(32, "\x00".b)
            when Integer
              uint256(v)
            end
          }.join
        end

        def uint256(value)
          value = Integer(value)
          raise ArgumentError, "uint256 out of range" if value.negative? || value >= (1 << 256)

          [value.to_s(16).rjust(64, "0")].pack("H*")
        end

        def recover_address(hash, sig_bytes)
          Kernel.require "eth"

          return nil unless sig_bytes.bytesize == 65

          sig_hex = "0x#{sig_bytes.unpack1("H*")}"
          # Use raw ecrecover (not personal_recover which adds EIP-191 prefix)
          recovered_key = Eth::Signature.recover(hash, sig_hex)
          Eth::Util.public_key_to_address(recovered_key).to_s
        rescue => _e
          nil
        end
      end
    end
  end
end
