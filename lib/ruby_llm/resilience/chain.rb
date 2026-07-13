# frozen_string_literal: true

module RubyLLM
  module Resilience
    # Orchestration: circuit-broken calls and fallback chains.
    #
    # The chain semantics are the part that isn't a textbook breaker:
    #   - steps whose breaker is open are SKIPPED, not attempted
    #   - the first success wins
    #   - if the chain is exhausted and ANY step was skipped-open, raise
    #     BreakerTripped (not the last real error) so callers can distinguish
    #     "the providers are down" (fail closed) from "your request failed"
    module Chain
      module_function

      # Circuit-break a single call. Raises the original error on failure,
      # or BreakerTripped if the circuit is open.
      def run(service)
        breaker = Breaker.new(service)
        raise BreakerTripped, "Circuit open for #{service}" unless breaker.allow_request?

        result = yield
        breaker.record_success
        result
      rescue BreakerTripped
        raise
      rescue StandardError => error
        breaker.record_failure if Resilience.trippable?(error)
        raise
      end

      # Model fallback via the configured map (or an explicit override). The
      # block receives the model to use (primary first; hops on trippable or
      # fallback-class errors). Breaker names come from the service_namer.
      #
      #   Resilience.run_with_model_fallback("claude-haiku-4-5") { |model|
      #     RubyLLM.chat(model: model).ask(prompt)
      #   }
      #
      # The fallback: keyword makes routing per-call configurable:
      #   fallback: :map          — default: use config.fallback_models
      #   fallback: false / nil   — no fallback; primary only
      #   fallback: "model-name"  — explicit hop, ignoring the map
      #   fallback: [ "a", "b" ]  — explicit multi-hop chain
      def run_with_model_fallback(primary_model, fallback: :map, &block)
        namer = Resilience.config.service_namer

        hops =
          case fallback
          when :map       then Resilience.config.fallbacks_for(primary_model)
          when nil, false then []
          else Array(fallback)
          end

        steps = [ primary_model, *hops ].map do |model|
          { service: namer.call(model), model: model.to_s, call: -> { block.call(model) } }
        end

        run_with_fallback(*steps)
      end

      # Try steps in order; each is { service:, call: -> { ... } } (an
      # optional :model key is carried through to on_fallback for context).
      # Every advance past a failed or skipped step fires config.on_fallback
      # with from:, to:, error: — the audit trail.
      def run_with_fallback(*steps)
        raise ArgumentError, "run_with_fallback requires at least one step" if steps.empty?

        last_error = nil
        any_breaker_tripped = false

        steps.each_with_index do |step, index|
          begin
            return run(step[:service]) { step[:call].call }
          rescue BreakerTripped => error
            any_breaker_tripped = true
            last_error = error
          rescue *Resilience.config.resolved_fallback_errors => error
            last_error = error
          end

          next_step = steps[index + 1]
          notify_fallback(step, next_step, last_error) if next_step
        end

        raise BreakerTripped, last_error&.message if any_breaker_tripped
        raise last_error
      end

      # Callback failures must never break the call path.
      def notify_fallback(from, to, error)
        Resilience.config.on_fallback.call(
          from: from.except(:call), to: to.except(:call), error: error
        )
      rescue StandardError
        nil
      end
    end
  end
end
