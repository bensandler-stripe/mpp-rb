# typed: strict
# frozen_string_literal: true

require "openssl"
require "base64"

module Mpp
  extend T::Sig

  module_function

  # RFC 9110 token used as an HTTP field name.
  HTTP_HEADER_NAME_RE = T.let(/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/, Regexp)

  # Generate HMAC-SHA256 challenge ID per spec.
  #
  # HMAC input format: realm|method|intent|request_b64|expires|digest|opaque_b64
  # Challenges that advertise a credential header insert it immediately before
  # the final opaque slot. Authorization is the implicit default and is never
  # included, preserving the legacy binding.
  # Output: base64url(HMAC-SHA256(secret_key, input))
  sig { params(secret_key: T.untyped, realm: T.untyped, method: T.untyped, intent: T.untyped, request: T.untyped, expires: T.untyped, digest: T.untyped, opaque: T.untyped, header: T.untyped).returns(String) }
  def generate_challenge_id(secret_key:, realm:, method:, intent:, request:, expires: nil, digest: nil, opaque: nil, header: nil)
    request_json = Json.compact_encode(request)
    request_b64 = b64url_encode(request_json)

    opaque_b64 = if opaque
      opaque_json = Json.compact_encode(opaque)
      b64url_encode(opaque_json)
    else
      ""
    end

    hmac_input = [
      realm,
      method,
      intent,
      request_b64,
      expires || "",
      digest || ""
    ]
    advertised = advertised_credential_header(header)
    hmac_input << advertised if advertised
    hmac_input << opaque_b64
    hmac_input = hmac_input.join("|")

    mac = OpenSSL::HMAC.digest("SHA256", secret_key.encode(Encoding::UTF_8), hmac_input.encode(Encoding::UTF_8))
    Base64.urlsafe_encode64(mac, padding: false)
  end

  # True when the credential header is omitted or is the implicit Authorization default.
  sig { params(header: T.untyped).returns(T::Boolean) }
  def default_credential_header?(header)
    header.nil? || header.to_s.empty? || header.to_s.casecmp(AUTHORIZATION_HEADER).zero?
  end

  # Returns an advertised credential header, or nil for the Authorization default.
  sig { params(header: T.untyped).returns(T.nilable(String)) }
  def advertised_credential_header(header)
    return nil if default_credential_header?(header)

    name = header.to_s
    Kernel.raise ArgumentError, "Invalid HTTP header name" unless HTTP_HEADER_NAME_RE.match?(name)
    name
  end

  # Encode string to base64url without padding.
  sig { params(data: T.untyped).returns(String) }
  def b64url_encode(data)
    Base64.urlsafe_encode64(data.encode(Encoding::UTF_8), padding: false)
  end

  # Encode bytes to base64url without padding.
  sig { params(data: String).returns(String) }
  def b64url_encode_bytes(data)
    Base64.urlsafe_encode64(data, padding: false)
  end
end
