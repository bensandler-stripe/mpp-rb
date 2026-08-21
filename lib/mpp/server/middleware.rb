# typed: strict
# frozen_string_literal: true

require "stringio"

module Mpp
  module Server
    # Rack middleware that gates endpoints behind payment verification.
    #
    # The pricing proc determines which requests require payment and at what
    # price. It receives the Rack env and must return a charge options hash
    # (with at least :amount) or nil for free endpoints. The pricing proc
    # MUST NOT produce side effects.
    #
    # Payment is verified BEFORE the downstream app runs — if verification
    # fails, the app never executes and a 402 challenge is returned.
    #
    # Example:
    #   use Mpp::Server::Middleware,
    #       handler: my_handler,
    #       pricing: ->(env) { {amount: "1.00"} if env["PATH_INFO"] == "/paid" }
    class Middleware
      extend T::Sig

      sig { params(app: T.untyped, handler: T.untyped, pricing: T.untyped).void }
      def initialize(app, handler:, pricing:)
        @app = T.let(app, T.untyped)
        @handler = T.let(handler, T.untyped)
        @pricing = T.let(pricing, T.untyped)
      end

      sig { params(env: T.untyped).returns(T::Array[T.untyped]) }
      def call(env)
        charge_opts = @pricing.call(env)
        return @app.call(env) unless charge_opts

        authorization = env["HTTP_AUTHORIZATION"]
        accept_payment = env["HTTP_ACCEPT_PAYMENT"]
        body_capture = capture_request_body(env)

        request_body = body_capture&.materialize
        env["rack.input"] = StringIO.new(request_body || "") if body_capture

        result = verify_payment(
          env,
          charge_opts,
          authorization: authorization,
          accept_payment: accept_payment,
          request_body: request_body
        )

        challenge_response = challenge_rack_response(result)
        return challenge_response if challenge_response

        credential, receipt, extra_headers = paid_result(result)
        status, headers, body = @app.call(env)
        headers["Payment-Receipt"] = receipt.to_payment_receipt
        extra_headers.each { |key, value| headers[key] = value unless value.nil? }
        self.class.mark_authorization_bound_response(headers)

        [status, headers, body]
      end

      sig { params(headers: T::Hash[T.untyped, T.untyped], vary: T::Array[String]).void }
      def self.mark_authorization_bound_response(headers, vary: ["Authorization"])
        headers["Cache-Control"] = "no-store"

        vary_values = headers["Vary"].to_s.split(",").map do |value|
          value.strip.downcase
        end
        return if vary_values.include?("*")

        additions = vary.reject { |field| vary_values.include?(field.downcase) }
        return if additions.empty?

        headers["Vary"] = [headers["Vary"], *additions]
          .compact
          .reject(&:empty?)
          .join(", ")
      end

      private

      sig do
        params(
          env: T.untyped,
          charge_opts: T.untyped,
          authorization: T.untyped,
          accept_payment: T.untyped,
          request_body: T.untyped
        ).returns(T.untyped)
      end
      def verify_payment(env, charge_opts, authorization:, accept_payment:, request_body:)
        if @handler.is_a?(Mpp::Server::ComposedHandler)
          return @handler.call(
            authorization: authorization,
            body: request_body,
            accept_payment: accept_payment
          )
        end

        amount = charge_opts[:amount]
        opts = charge_opts.except(:amount, :body)
        opts[:mppx_scope] ||= mppx_scope(env)
        @handler.charge(
          authorization,
          amount,
          **opts,
          body: request_body,
          accept_payment: accept_payment
        )
      end

      sig { params(result: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
      def challenge_rack_response(result)
        if result.is_a?(Mpp::Server::ComposedResult)
          return nil unless result.payment_required?

          resp = result.to_response
          return [resp["status"], resp["headers"], [resp["body"]]]
        end

        return nil unless result.is_a?(Mpp::Challenge)

        resp = if @handler.respond_to?(:challenge_response)
          @handler.challenge_response(result)
        else
          Mpp::Server::Decorator.make_challenge_response(result, @handler.realm)
        end
        [resp["status"], resp["headers"], [resp["body"]]]
      end

      sig { params(result: T.untyped).returns(T::Array[T.untyped]) }
      def paid_result(result)
        if result.is_a?(Mpp::Server::ComposedResult)
          credential, receipt = result.payment
          return [credential, receipt, result.extra_headers]
        end

        credential, receipt = result
        [credential, receipt, {}]
      end

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
