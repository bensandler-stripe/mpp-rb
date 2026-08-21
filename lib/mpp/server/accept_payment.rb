# typed: strict
# frozen_string_literal: true

module Mpp
  module Server
    # Parse, format, and rank the Accept-Payment client-preference header.
    #
    # Syntax mirrors HTTP content negotiation: `method/intent[;q=value]`,
    # comma-separated. Wildcards (`*` / `tempo/*` / `*/charge`) are allowed.
    # Entries with q=0 are excluded. If the header is empty, invalid, or
    # filters out every offer, the original offer list is returned.
    module AcceptPayment
      extend T::Sig

      TOKEN_RE = /\A(?:\*|[a-z0-9-]+)\z/
      ENTRY_RE = %r{\A(?<method>[^/;\s]+|\*)\s*/\s*(?<intent>[^/;\s]+|\*)(?<params>(?:\s*;\s*.+)?)\z}
      PARAM_RE = /\A(?<name>[A-Za-z0-9_-]+)\s*=\s*(?<value>\S+)\z/
      QVALUE_RE = /\A(?:0(?:\.\d{0,3})?|1(?:\.0{0,3})?)\z/

      Entry = T.type_alias { T::Hash[Symbol, T.untyped] }

      module_function

      # Parse an Accept-Payment header. Raises ArgumentError on malformed input.
      sig { params(header: String).returns(T::Array[Entry]) }
      def parse(header)
        parts = header.split(",").map(&:strip).reject(&:empty?)
        Kernel.raise ArgumentError, "Accept-Payment header is empty." if parts.empty?

        parts.each_with_index.map { |part, index| parse_entry(part, index) }
      end

      # Filter and reorder offers by Accept-Payment. Returns `offers` unchanged
      # when the header is missing, malformed, or matches nothing.
      sig { params(offers: T::Array[T.untyped], header: T.nilable(String)).returns(T::Array[T.untyped]) }
      def apply(offers, header)
        return offers if header.nil? || header.strip.empty?

        begin
          preferences = parse(header)
        rescue ArgumentError
          return offers
        end

        ranked = rank(offers, preferences)
        ranked.empty? ? offers : ranked
      end

      # Order offers by the best matching client preference.
      # More specific matches win before comparing q-values.
      sig { params(offers: T::Array[T.untyped], preferences: T::Array[Entry]).returns(T::Array[T.untyped]) }
      def rank(offers, preferences)
        scored = []
        offers.each_with_index do |offer, index|
          match = best_match(offer, preferences)
          next unless match && T.unsafe(match[:q]) > 0

          scored << {match: match, offer: offer, index: index}
        end

        scored.sort_by! { |row| [-T.unsafe(row[:match][:q]), T.unsafe(row[:index])] }
        scored.map { |row| row[:offer] }
      end

      sig { params(value: T.untyped).returns(String) }
      def key_of(value)
        method, intent = method_intent(value)
        Kernel.raise ArgumentError, "Missing payment method name." if method.empty?

        "#{method}/#{intent}"
      end

      sig { params(part: String, index: Integer).returns(Entry) }
      def parse_entry(part, index)
        match = ENTRY_RE.match(part)
        Kernel.raise ArgumentError, "Invalid Accept-Payment entry: #{part}" unless match

        method = T.must(match[:method])
        intent = T.must(match[:intent])
        assert_token!(method, "method")
        assert_token!(intent, "intent")

        q = 1.0
        split_parameters(match[:params]).each do |param|
          next if param.empty?

          parameter_match = PARAM_RE.match(param)
          Kernel.raise ArgumentError, "Invalid Accept-Payment parameter: #{param}" unless parameter_match

          next unless parameter_match[:name] == "q"

          q = parse_header_q(T.must(parameter_match[:value]), %(Accept-Payment entry "#{part}"))
        end

        {method: method, intent: intent, q: q, index: index}
      end
      private_class_method :parse_entry

      sig { params(offer: T.untyped, preferences: T::Array[Entry]).returns(T.nilable(Entry)) }
      def best_match(offer, preferences)
        method, intent = method_intent(offer)
        best = T.let(nil, T.nilable(Entry))

        preferences.each do |preference|
          next unless matches?(method, intent, preference)

          candidate = preference.merge(specificity: specificity(preference))
          if better_match?(candidate, best)
            best = candidate
          end
        end

        best
      end
      private_class_method :best_match

      sig { params(candidate: Entry, best: T.nilable(Entry)).returns(T::Boolean) }
      def better_match?(candidate, best)
        return true if best.nil?
        return true if T.unsafe(candidate[:specificity]) > T.unsafe(best[:specificity])
        return true if T.unsafe(candidate[:specificity]) == T.unsafe(best[:specificity]) &&
          T.unsafe(candidate[:q]) > T.unsafe(best[:q])
        return true if T.unsafe(candidate[:specificity]) == T.unsafe(best[:specificity]) &&
          T.unsafe(candidate[:q]) == T.unsafe(best[:q]) &&
          T.unsafe(candidate[:index]) < T.unsafe(best[:index])

        false
      end
      private_class_method :better_match?

      sig { params(method: String, intent: String, preference: Entry).returns(T::Boolean) }
      def matches?(method, intent, preference)
        (preference[:method] == "*" || preference[:method] == method) &&
          (preference[:intent] == "*" || preference[:intent] == intent)
      end
      private_class_method :matches?

      sig { params(preference: Entry).returns(Integer) }
      def specificity(preference)
        ((preference[:method] == "*") ? 0 : 1) + ((preference[:intent] == "*") ? 0 : 1)
      end
      private_class_method :specificity

      sig { params(offer: T.untyped).returns([String, String]) }
      def method_intent(offer)
        if offer.is_a?(Hash)
          [(offer[:method] || offer["method"]).to_s, (offer[:intent] || offer["intent"]).to_s]
        else
          [offer.method.to_s, offer.intent.to_s]
        end
      end
      private_class_method :method_intent

      sig { params(value: T.nilable(String)).returns(T::Array[String]) }
      def split_parameters(value)
        return [] if value.nil? || value.empty?

        value.split(";").map(&:strip).reject(&:empty?)
      end
      private_class_method :split_parameters

      sig { params(value: String, context: String).returns(Float) }
      def parse_header_q(value, context)
        unless QVALUE_RE.match?(value)
          Kernel.raise ArgumentError, "Invalid q-value for #{context}. Expected an HTTP qvalue."
        end

        assert_q(Kernel.Float(value), context)
      end
      private_class_method :parse_header_q

      sig { params(value: Float, context: String).returns(Float) }
      def assert_q(value, context)
        Kernel.raise ArgumentError, "Invalid q-value for #{context}. Expected a value between 0 and 1." if value.negative? || value > 1

        rounded = (value * 1000).round
        if (value * 1000 - rounded).abs > 1e-9
          Kernel.raise ArgumentError, "Invalid q-value for #{context}. Expected at most 3 decimal places."
        end

        rounded / 1000.0
      end
      private_class_method :assert_q

      sig { params(value: String, label: String).void }
      def assert_token!(value, label)
        return if TOKEN_RE.match?(value)

        Kernel.raise ArgumentError, "Invalid Accept-Payment #{label}: #{value}"
      end
      private_class_method :assert_token!
    end
  end
end
