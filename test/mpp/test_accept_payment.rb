# frozen_string_literal: true

require "test_helper"

class TestAcceptPayment < Minitest::Test
  ChallengeStub = Struct.new(:method, :intent, :id)

  def test_parse_method_intent_entries
    entries = Mpp::Server::AcceptPayment.parse("tempo/charge, stripe/charge;q=0.8")

    assert_equal "tempo", entries[0][:method]
    assert_equal "charge", entries[0][:intent]
    assert_in_delta 1.0, entries[0][:q]
    assert_equal "stripe", entries[1][:method]
    assert_in_delta 0.8, entries[1][:q]
  end

  def test_parse_wildcards
    entries = Mpp::Server::AcceptPayment.parse("tempo/*, */charge;q=0.5")

    assert_equal "*", entries[0][:intent]
    assert_equal "*", entries[1][:method]
  end

  def test_rank_excludes_q0_and_prefers_higher_q
    tempo = ChallengeStub.new("tempo", "charge", "t")
    stripe = ChallengeStub.new("stripe", "charge", "s")
    ranked = Mpp::Server::AcceptPayment.rank(
      [stripe, tempo],
      Mpp::Server::AcceptPayment.parse("tempo/charge, stripe/charge;q=0")
    )

    assert_equal [tempo], ranked
  end

  def test_specific_opt_out_overrides_wildcard
    tempo = ChallengeStub.new("tempo", "charge", "t")
    stripe = ChallengeStub.new("stripe", "charge", "s")
    ranked = Mpp::Server::AcceptPayment.rank(
      [tempo, stripe],
      Mpp::Server::AcceptPayment.parse("*/charge, tempo/charge;q=0")
    )

    assert_equal [stripe], ranked
  end

  def test_apply_returns_all_when_header_invalid_or_empty_match
    offers = [ChallengeStub.new("tempo", "charge", "t")]

    assert_equal offers, Mpp::Server::AcceptPayment.apply(offers, nil)
    assert_equal offers, Mpp::Server::AcceptPayment.apply(offers, "not-a-header")
    assert_equal offers, Mpp::Server::AcceptPayment.apply(offers, "stripe/charge")
  end

  def test_parse_rejects_empty_header
    assert_raises(ArgumentError) { Mpp::Server::AcceptPayment.parse("  ") }
  end
end
