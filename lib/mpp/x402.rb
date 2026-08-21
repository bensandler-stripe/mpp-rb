# typed: strict
# frozen_string_literal: true

module Mpp
  module X402
    autoload :Header, "mpp/x402/header"
    autoload :Facilitator, "mpp/x402/facilitator"
    autoload :Server, "mpp/x402/server"
  end
end

require_relative "x402/types"
