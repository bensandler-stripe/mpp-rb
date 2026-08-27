# typed: false
# frozen_string_literal: true

module Mpp
  ChallengeEcho = Data.define(
    :id,
    :realm,
    :method,
    :intent,
    :request,
    :expires,
    :digest,
    :opaque,
    :header
  ) do
    def initialize(id:, realm:, method:, intent:, request:, expires: nil, digest: nil, opaque: nil, header: nil)
      super(
        id: id,
        realm: realm,
        method: method,
        intent: intent,
        request: request,
        expires: expires,
        digest: digest,
        opaque: opaque,
        header: Mpp.advertised_credential_header(header)
      )
    end
  end
end
