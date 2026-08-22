# frozen_string_literal: true

require_relative "lib/mpp/version"

Gem::Specification.new do |spec|
  spec.name = "mpp-rb"
  spec.version = Mpp::VERSION
  spec.authors = ["Stripe"]
  spec.summary = "HTTP 402 Payment Authentication for Ruby"
  spec.description = "Ruby SDK for the Machine Payments Protocol (MPP) — an HTTP 402 Payment Authentication scheme."
  spec.homepage = "https://github.com/stripe/mpp-rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3.0"

  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "base64", "~> 0.3"
  spec.add_dependency "keccak", "~> 1.3"

  # keccak is Ethereum Keccak-256 (not SHA3-256) for Tempo attribution memos.
  # Optional deps are autoloaded:
  #   async, async-http  — client + Tempo RPC
  #   eth                — Tempo account signing, EIP-3009 recovery
  #   rlp                — fee payer envelope

  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = "https://github.com/stripe/mpp-rb"
end
