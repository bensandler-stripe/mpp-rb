# frozen_string_literal: true

require "test_helper"

class ComposeMockIntent
  attr_reader :name

  def initialize(name: "charge", receipt_method: "tempo")
    @name = name
    @receipt_method = receipt_method
  end

  def verify(_credential, _request)
    Mpp::Receipt.success("0xcomposed", method: @receipt_method)
  end
end

class ComposeMockMethod
  attr_reader :name, :intents, :currency, :recipient, :decimals, :chain_id

  def initialize(name:, currency:, recipient:, decimals: 6, chain_id: nil)
    @name = name
    @currency = currency
    @recipient = recipient
    @decimals = decimals
    @chain_id = chain_id
    @intents = {"charge" => ComposeMockIntent.new(receipt_method: name)}
  end
end

class ComposeAvailableMethod < ComposeMockMethod
  attr_accessor :available
  attr_reader :can_offer_calls, :seen_request, :transform_calls

  def initialize(available:, **kwargs)
    super(**kwargs)
    @available = available
    @can_offer_calls = 0
    @transform_calls = 0
  end

  def can_offer?(request)
    @can_offer_calls += 1
    @seen_request = request
    @available.respond_to?(:call) ? @available.call(request) : @available
  end

  def transform_request(request, _credential)
    @transform_calls += 1
    request.merge("composeAvailability" => "checked")
  end
end

class TestCompose < Minitest::Test
  SECRET = "test-compose-secret"
  REALM = "api.example.com"
  TEMPO_CURRENCY = Mpp::Methods::Tempo::Defaults::PATH_USD
  TEMPO_CURRENCY_B = Mpp::Methods::Tempo::Defaults::USDC
  RECIPIENT = "0x#{"0" * 39}1"

  def setup
    @tempo = ComposeMockMethod.new(name: "tempo", currency: TEMPO_CURRENCY, recipient: RECIPIENT)
    @stripe = ComposeMockMethod.new(name: "stripe", currency: "usd", recipient: "acct_123", decimals: 2)
    @handler = Mpp::Server::MppHandler.new(
      methods: [@tempo, @stripe],
      realm: REALM,
      secret_key: SECRET
    )
  end

  def test_create_rejects_method_and_methods
    assert_raises(ArgumentError) do
      Mpp.create(method: @tempo, methods: [@stripe], secret_key: SECRET, realm: REALM)
    end
  end

  def test_create_rejects_duplicate_method_names
    assert_raises(ArgumentError) do
      Mpp.create(methods: [@tempo, @tempo], secret_key: SECRET, realm: REALM)
    end
  end

  def test_compose_merges_www_authenticate_challenges
    result = @handler.compose(
      [@tempo, {amount: "1.00"}],
      [@stripe, {amount: "1.00"}]
    ).call

    assert result.payment_required?
    assert_equal 2, result.challenges.length
    assert_equal ["tempo", "stripe"], result.challenges.map(&:method)
    response = result.to_response
    www = response["headers"]["WWW-Authenticate"]
    values = Array(www)
    assert_equal 2, values.length
    assert values.all? { |value| value.start_with?("Payment ") }
  end

  def test_compose_accepts_string_keys
    result = @handler.compose(
      ["tempo/charge", {amount: "0.50"}],
      ["stripe/charge", {amount: "0.50"}]
    ).call

    assert_equal ["tempo", "stripe"], result.challenges.map(&:method)
  end

  def test_scoped_offer_preserves_explicit_scope
    offer = @handler.compose([@tempo, {amount: "1.00", mppx_scope: {"resource" => "/configured"}}]).offers.first

    assert_equal({"resource" => "/configured"}, offer.with_scope({"resource" => "/rack"}).options[:mppx_scope])
  end

  def test_compose_dispatches_matching_credential
    composed = @handler.compose(
      [@tempo, {amount: "1.00"}],
      [@stripe, {amount: "1.00"}]
    )
    challenge = composed.call.challenges.find { |item| item.method == "stripe" }
    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"spt" => "spt_test"}
    )

    result = composed.call(authorization: credential.to_authorization)

    refute result.payment_required?
    _cred, receipt = result.payment
    assert_equal "stripe", receipt.method
    assert_equal "success", receipt.status
  end

  def test_compose_disambiguates_same_method_different_currency
    composed = @handler.compose(
      [@tempo, {amount: "1.00", currency: TEMPO_CURRENCY}],
      [@tempo, {amount: "1.00", currency: TEMPO_CURRENCY_B}]
    )
    second = composed.call.challenges[1]
    credential = Mpp::Credential.new(
      challenge: second.to_echo,
      payload: {"type" => "transaction", "signature" => "0xabc"}
    )

    result = composed.call(authorization: credential.to_authorization)

    refute result.payment_required?
    assert_equal TEMPO_CURRENCY_B, second.request["currency"]
  end

  def test_accept_payment_ranks_challenges
    result = @handler.compose(
      [@tempo, {amount: "1.00"}],
      [@stripe, {amount: "1.00"}]
    ).call(accept_payment: "stripe/charge, tempo/charge;q=0.1")

    assert_equal ["stripe", "tempo"], result.challenges.map(&:method)
  end

  def test_accept_payment_q0_filters_method
    result = @handler.compose(
      [@tempo, {amount: "1.00"}],
      [@stripe, {amount: "1.00"}]
    ).call(accept_payment: "tempo/charge, stripe/charge;q=0")

    assert_equal ["tempo"], result.challenges.map(&:method)
  end

  def test_compose_only_advertises_available_offers_with_their_canonical_request
    unavailable = ComposeAvailableMethod.new(
      name: "tempo",
      currency: TEMPO_CURRENCY,
      recipient: RECIPIENT,
      available: false
    )
    available = ComposeAvailableMethod.new(
      name: "stripe",
      currency: "usd",
      recipient: "acct_123",
      decimals: 2,
      available: true
    )
    handler = Mpp::Server::MppHandler.new(methods: [unavailable, available], realm: REALM, secret_key: SECRET)

    result = handler.compose(
      [unavailable, {amount: "1.00"}],
      [available, {amount: "1.00"}]
    ).call

    assert_equal ["stripe"], result.challenges.map(&:method)
    assert_equal 1, unavailable.transform_calls
    assert_equal 1, available.transform_calls
    assert_same available.seen_request, result.challenges.first.request
  end

  def test_availability_does_not_block_issued_credentials_or_direct_charges
    method = ComposeAvailableMethod.new(
      name: "tempo",
      currency: TEMPO_CURRENCY,
      recipient: RECIPIENT,
      available: true
    )
    handler = Mpp::Server::MppHandler.new(methods: [method], realm: REALM, secret_key: SECRET)
    composed = handler.compose([method, {amount: "1.00"}])
    challenge = composed.call.challenges.first
    method.available = false
    credential = Mpp::Credential.new(challenge: challenge.to_echo, payload: {"type" => "transaction"})

    result = composed.call(authorization: credential.to_authorization)

    refute result.payment_required?
    assert_equal 1, method.can_offer_calls

    direct = handler.charge(nil, "1.00")
    assert_instance_of Mpp::Challenge, direct
    assert_equal 1, method.can_offer_calls
  end

  def test_compose_rejects_when_no_offers_are_available
    method = ComposeAvailableMethod.new(
      name: "tempo",
      currency: TEMPO_CURRENCY,
      recipient: RECIPIENT,
      available: false
    )
    handler = Mpp::Server::MppHandler.new(method: method, realm: REALM, secret_key: SECRET)

    error = assert_raises(ArgumentError) { handler.compose([method, {amount: "1.00"}]).call }

    assert_equal "No payment offers are available for this request", error.message
  end

  def test_compose_rejects_non_boolean_offer_availability
    method = ComposeAvailableMethod.new(
      name: "tempo",
      currency: TEMPO_CURRENCY,
      recipient: RECIPIENT,
      available: "sometimes"
    )
    handler = Mpp::Server::MppHandler.new(method: method, realm: REALM, secret_key: SECRET)

    error = assert_raises(ArgumentError) { handler.compose([method, {amount: "1.00"}]).call }

    assert_equal "can_offer? must return true or false", error.message
  end

  def test_compose_propagates_offer_availability_errors
    expected = RuntimeError.new("deposit address unavailable")
    method = ComposeAvailableMethod.new(
      name: "tempo",
      currency: TEMPO_CURRENCY,
      recipient: RECIPIENT,
      available: ->(_request) { raise expected }
    )
    handler = Mpp::Server::MppHandler.new(method: method, realm: REALM, secret_key: SECRET)

    error = assert_raises(RuntimeError) { handler.compose([method, {amount: "1.00"}]).call }

    assert_same expected, error
  end

  def test_implicit_charge_compose_for_multiple_methods
    result = @handler.charge(nil, "1.00")

    assert_instance_of Mpp::Server::ComposedResult, result
    assert result.payment_required?
    assert_equal ["tempo", "stripe"], result.challenges.map(&:method)
  end

  def test_single_method_charge_still_returns_challenge
    handler = Mpp::Server::MppHandler.new(method: @tempo, realm: REALM, secret_key: SECRET)
    result = handler.charge(nil, "1.00")

    assert_instance_of Mpp::Challenge, result
    assert_equal "tempo", result.method
  end

  def test_static_compose_flattens_nested_handlers
    stablecoins = @handler.compose(
      [@tempo, {amount: "1.00", currency: TEMPO_CURRENCY}],
      [@tempo, {amount: "1.00", currency: TEMPO_CURRENCY_B}]
    )
    nested = Mpp::Server.compose(
      stablecoins,
      @handler.compose([@stripe, {amount: "1.00"}])
    )
    result = nested.call

    assert_equal 3, result.challenges.length
    assert_equal ["tempo", "tempo", "stripe"], result.challenges.map(&:method)
  end

  def test_unrecognized_credential_falls_through_to_merged_402
    other = Mpp::Challenge.create(
      secret_key: SECRET,
      realm: REALM,
      method: "lightning",
      intent: "charge",
      request: {"amount" => "1"}
    )
    credential = Mpp::Credential.new(
      challenge: other.to_echo,
      payload: {"type" => "invoice"}
    )
    result = @handler.compose(
      [@tempo, {amount: "1.00"}],
      [@stripe, {amount: "1.00"}]
    ).call(authorization: credential.to_authorization)

    assert result.payment_required?
    assert_equal 2, result.challenges.length
  end

  def test_requires_auth_compose_advertises_and_accepts_payment_authorization
    handler = Mpp::Server::MppHandler.new(
      methods: [@tempo, @stripe],
      realm: REALM,
      secret_key: SECRET,
      requires_auth: true
    )
    composed = handler.compose(
      [@tempo, {amount: "1.00"}],
      [@stripe, {amount: "1.00"}]
    )
    result = composed.call(authorization: "Bearer app-token")

    assert result.payment_required?
    assert result.challenges.all? { |challenge| challenge.header == Mpp::PAYMENT_AUTHORIZATION_HEADER }
    www = Array(result.to_response["headers"]["WWW-Authenticate"])
    assert www.all? { |value| value.include?(%(header="#{Mpp::PAYMENT_AUTHORIZATION_HEADER}")) }

    stripe = result.challenges.find { |challenge| challenge.method == "stripe" }
    credential = Mpp::Credential.new(
      challenge: stripe.to_echo,
      payload: {"spt" => "spt_test"}
    )
    paid = composed.call(
      authorization: "Bearer app-token",
      payment_authorization: credential.to_authorization
    )

    refute paid.payment_required?
    _cred, receipt = paid.payment
    assert_equal "stripe", receipt.method
  end
end
