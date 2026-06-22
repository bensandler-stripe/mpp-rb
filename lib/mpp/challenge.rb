# typed: true
# frozen_string_literal: true

require_relative "challenge_id"
require_relative "secure_compare"
require_relative "json"

module Mpp
  Challenge = Data.define(
    :id,
    :method,
    :intent,
    :request,
    :realm,
    :request_b64,
    :digest,
    :expires,
    :description,
    :opaque
  ) do
    def initialize(id:, method:, intent:, request:, realm: "", request_b64: "", digest: nil, expires: nil,
      description: nil, opaque: nil)
      super
    end

    # Create a Challenge with an HMAC-bound ID.
    def self.create(secret_key:, realm:, method:, intent:, request:, expires: nil, digest: nil, description: nil,
      meta: nil)
      challenge_id = Mpp.generate_challenge_id(
        secret_key: secret_key,
        realm: realm,
        method: method,
        intent: intent,
        request: request,
        expires: expires,
        digest: digest,
        opaque: meta
      )
      request_json = Mpp::Json.compact_encode(request)
      request_b64 = Mpp.b64url_encode(request_json)

      new(
        id: challenge_id,
        method: method,
        intent: intent,
        request: request,
        realm: realm,
        request_b64: request_b64,
        digest: digest,
        expires: expires,
        description: description,
        opaque: meta
      )
    end

    # Parse a Challenge from a WWW-Authenticate header value.
    def self.from_www_authenticate(header)
      Mpp::Parsing.parse_www_authenticate(header)
    end

    # Split a merged WWW-Authenticate header value into the individual
    # `Payment ...` challenge chunks it contains, handling RFC 9110 §11.6.1
    # comma-separated authentication schemes. Returns the raw chunk strings so
    # callers can parse each challenge independently; a malformed chunk then
    # does not prevent the remaining chunks from being considered.
    def self.www_authenticate_chunks(header)
      payment_scheme_indices(header).map do |start_idx|
        # End each chunk at the next scheme boundary of any kind, so an
        # interleaved non-Payment scheme (e.g. "Payment ..., Bearer ...,
        # Payment ...") is not folded into the preceding Payment challenge.
        end_idx = next_auth_scheme_index(header, start_idx + "Payment".length) || header.length
        T.must(header[start_idx...end_idx]).sub(/,\s*$/, "")
      end
    end

    # Parse every Payment challenge from a merged WWW-Authenticate header.
    # Raises Mpp::ParseError on the first malformed chunk; callers that need to
    # tolerate a malformed challenge among valid ones should iterate
    # `www_authenticate_chunks` and parse each chunk independently instead.
    def self.from_www_authenticate_list(header)
      www_authenticate_chunks(header).map { |chunk| from_www_authenticate(chunk) }
    end

    def self.payment_scheme_indices(header)
      indices = []
      each_auth_scheme_index(header) do |index, scheme|
        indices << index if scheme.casecmp("Payment").zero?
      end
      indices
    end

    def self.next_auth_scheme_index(header, offset)
      each_auth_scheme_index(header, offset) do |index, _scheme|
        return index
      end
      nil
    end

    def self.each_auth_scheme_index(header, offset = 0)
      in_quote = T.let(false, T::Boolean)
      escaped = T.let(false, T::Boolean)
      i = offset

      while i < header.length
        char = T.must(header[i])

        if in_quote
          if escaped
            escaped = false
          elsif char == "\\"
            escaped = true
          elsif char == "\""
            in_quote = false
          end
          i += 1
          next
        end

        if char == "\""
          in_quote = true
          i += 1
          next
        end

        if scheme_boundary?(header, i)
          match = T.must(header[i..]).match(/\A([A-Za-z][A-Za-z0-9._~+\/-]*)\s+/)
          # An auth-param permits OWS around "=" (key\s*=\s*value), so a token
          # followed by whitespace then "=" is a parameter, not a new scheme.
          if match && header[i + T.must(match[0]).length] != "="
            yield i, T.must(match[1])
            i += T.must(match[0]).length
            next
          end
        end

        i += 1
      end
    end

    def self.scheme_boundary?(header, index)
      previous = T.must(header[0...index]).rstrip
      # Start of the header, including the case where only optional whitespace
      # (RFC 9110 OWS) precedes the first scheme; otherwise a scheme is a
      # boundary only immediately after a comma separating two schemes.
      return true if previous.empty?

      previous.end_with?(",")
    end

    # Serialize to a WWW-Authenticate header value.
    def to_www_authenticate(realm)
      Mpp::Parsing.format_www_authenticate(self, realm)
    end

    # Verify the challenge ID matches the expected HMAC.
    def verify(secret_key, realm)
      expected_id = Mpp.generate_challenge_id(
        secret_key: secret_key,
        realm: realm,
        method: method,
        intent: intent,
        request: request,
        expires: expires,
        digest: digest,
        opaque: opaque
      )
      Mpp.secure_compare(id, expected_id)
    end

    # Create a ChallengeEcho for use in credentials.
    def to_echo
      opaque_b64 = nil
      if opaque
        opaque_json = Mpp::Json.compact_encode(opaque)
        opaque_b64 = Mpp.b64url_encode(opaque_json)
      end

      ChallengeEcho.new(
        id: id,
        realm: realm,
        method: method,
        intent: intent,
        request: request_b64,
        expires: expires,
        digest: digest,
        opaque: opaque_b64
      )
    end
  end
end
