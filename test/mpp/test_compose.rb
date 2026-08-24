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
end
