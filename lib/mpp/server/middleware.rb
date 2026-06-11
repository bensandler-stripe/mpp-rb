# typed: strict
# frozen_string_literal: true

require "stringio"

module Mpp
  module Server
    # Rack middleware that intercepts requests requiring payment.
    #
    # The downstream app signals payment is needed by setting env["mpp.charge"]
    # to a hash with at least :amount, and optionally :currency, :recipient,
    # :description, :expires, etc.
    #
    # Example:
    #   use Mpp::Server::Middleware, handler: my_handler
    #
    #   # In your app:
    #   env["mpp.charge"] = { amount: "1.00" }
    class Middleware
      extend T::Sig

      sig { params(app: T.untyped, handler: Mpp::Server::MppHandler).void }
      def initialize(app, handler:)
        @app = T.let(app, T.untyped)
        @handler = T.let(handler, Mpp::Server::MppHandler)
      end

      sig { params(env: T.untyped).returns(T::Array[T.untyped]) }
      def call(env)
        authorization = env["HTTP_AUTHORIZATION"]
        body_capture = capture_request_body(env)
        status, headers, body = @app.call(env)

        charge_opts = env["mpp.charge"]
        return [status, headers, body] unless charge_opts

        request_body = body_capture&.materialize
        env["rack.input"] = StringIO.new(request_body || "") if body_capture

        amount = charge_opts[:amount]
        opts = charge_opts.except(:amount, :body)
        opts[:mppx_scope] ||= mppx_scope(env)

        result = @handler.charge(authorization, amount, **opts, body: request_body)

        if result.is_a?(Mpp::Challenge)
          resp = Mpp::Server::Decorator.make_challenge_response(result, @handler.realm)
          return [resp["status"], resp["headers"], [resp["body"]]]
        end

        _credential, receipt = result
        headers["Payment-Receipt"] = receipt.to_payment_receipt
        self.class.mark_authorization_bound_response(headers)

        [status, headers, body]
      end

      sig { params(headers: T::Hash[T.untyped, T.untyped]).void }
      def self.mark_authorization_bound_response(headers)
        headers["Cache-Control"] = "no-store"

        vary_values = headers["Vary"].to_s.split(",").map do |value|
          value.strip.downcase
        end
        return if vary_values.include?("*") || vary_values.include?("authorization")

        headers["Vary"] = [headers["Vary"], "Authorization"]
          .compact
          .reject(&:empty?)
          .join(", ")
      end

      private

      sig { params(env: T.untyped).returns(T.nilable(RackInputCapture)) }
      def capture_request_body(env)
        input = env["rack.input"]
        return nil unless input&.respond_to?(:read)

        capture = RackInputCapture.new(input)
        env["rack.input"] = capture
        capture
      end

      sig { params(env: T.untyped).returns(T::Hash[String, String]) }
      def mppx_scope(env)
        scope = T.let({}, T::Hash[String, String])
        route = env["action_dispatch.route_uri_pattern"] || env["sinatra.route"] || env["roda.route"]
        route = route.split(" ", 2).last if route.is_a?(String) && route.match?(/\A[A-Z]+\s+/)
        scope["route"] = route if route.is_a?(String) && !route.empty?
        path = env["PATH_INFO"]
        scope["resource"] = path if path.is_a?(String) && !path.empty?
        query = env["QUERY_STRING"]
        scope["query"] = query if query.is_a?(String) && !query.empty?
        scope
      end

      class RackInputCapture
        extend T::Sig

        sig { params(input: T.untyped).void }
        def initialize(input)
          @input = T.let(input, T.untyped)
          @buffer = T.let(+"".b, String)
        end

        sig { params(args: T.untyped).returns(T.untyped) }
        def read(*args)
          chunk = @input.read(*args)
          @buffer << chunk.b if chunk && !chunk.empty?
          chunk
        end

        sig { params(args: T.untyped).returns(T.untyped) }
        def gets(*args)
          chunk = @input.gets(*args)
          @buffer << chunk.b if chunk && !chunk.empty?
          chunk
        end

        sig { params(block: T.nilable(T.proc.params(chunk: T.untyped).void)).returns(T.untyped) }
        def each(&block)
          return enum_for(:each) unless block

          @input.each do |chunk|
            @buffer << chunk.b if chunk && !chunk.empty?
            block.call(chunk)
          end
        end

        sig { returns(T.untyped) }
        def rewind
          @input.rewind if @input.respond_to?(:rewind)
          @buffer = +"".b
        end

        sig { returns(T.untyped) }
        def close
          @input.close if @input.respond_to?(:close)
        end

        sig { returns(T.nilable(String)) }
        def materialize
          read
          @buffer.empty? ? nil : @buffer.dup
        end
      end
    end
  end
end
