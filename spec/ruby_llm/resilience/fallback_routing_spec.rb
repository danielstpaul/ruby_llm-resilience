# frozen_string_literal: true

RSpec.describe "configurable fallback routing" do
  let(:resilience) { RubyLLM::Resilience }

  before do
    resilience.configure do |c|
      c.provider_resolver = ->(_model) { "anthropic" }
      c.fallback_models = {
        "claude-haiku-4-5" => "claude-sonnet-4-6",                          # one hop (string)
        "gemini-flaky"     => [ "claude-sonnet-4-6", "claude-opus-4-7" ]    # multi-hop (array)
      }
    end
  end

  describe "multi-hop maps" do
    it "walks the array in order until a hop succeeds" do
      models_seen = []
      result = resilience.run_with_model_fallback("gemini-flaky") do |model|
        models_seen << model
        raise RubyLLM::OverloadedError unless model == "claude-opus-4-7"

        "ok-on-#{model}"
      end
      expect(models_seen).to eq(%w[gemini-flaky claude-sonnet-4-6 claude-opus-4-7])
      expect(result).to eq("ok-on-claude-opus-4-7")
    end

    it "still supports plain-string map values (one hop)" do
      models_seen = []
      resilience.run_with_model_fallback("claude-haiku-4-5") do |model|
        models_seen << model
        raise RubyLLM::ServerError if model == "claude-haiku-4-5"

        "ok"
      end
      expect(models_seen).to eq(%w[claude-haiku-4-5 claude-sonnet-4-6])
    end
  end

  describe "per-call fallback: override" do
    it "fallback: false disables the map — primary only" do
      models_seen = []
      expect do
        resilience.run_with_model_fallback("claude-haiku-4-5", fallback: false) do |model|
          models_seen << model
          raise RubyLLM::ServerError
        end
      end.to raise_error(RubyLLM::ServerError)
      expect(models_seen).to eq(%w[claude-haiku-4-5])
    end

    it "fallback: <model> overrides the map with an explicit hop" do
      models_seen = []
      resilience.run_with_model_fallback("claude-haiku-4-5", fallback: "claude-opus-4-7") do |model|
        models_seen << model
        raise RubyLLM::ServerError if model == "claude-haiku-4-5"

        "ok"
      end
      expect(models_seen).to eq(%w[claude-haiku-4-5 claude-opus-4-7])
    end

    it "fallback: <array> gives an explicit multi-hop chain" do
      models_seen = []
      resilience.run_with_model_fallback("claude-haiku-4-5",
                                         fallback: %w[claude-sonnet-4-6 claude-opus-4-7]) do |model|
        models_seen << model
        raise RubyLLM::OverloadedError unless model == "claude-opus-4-7"

        "ok"
      end
      expect(models_seen.length).to eq(3)
    end

    it "expresses the variant→control pattern in one call (the Orbit deleter)" do
      # A variant on gemini falls back to its control's model cross-provider —
      # previously 25 lines of app code, now one explicit kwarg.
      models_seen = []
      resilience.run_with_model_fallback("gemini-flaky", fallback: "claude-sonnet-4-6") do |model|
        models_seen << model
        raise Faraday::TimeoutError if model == "gemini-flaky"

        "control-served"
      end
      expect(models_seen).to eq(%w[gemini-flaky claude-sonnet-4-6])
    end
  end

  describe "on_fallback audit trail" do
    let(:events) { [] }

    before do
      resilience.reset_configuration!
      resilience.configure do |c|
        c.provider_resolver = ->(_m) { "anthropic" }
        c.fallback_models = { "claude-haiku-4-5" => "claude-sonnet-4-6" }
        c.on_fallback = ->(from:, to:, error:) { events << { from: from, to: to, error: error.class } }
      end
    end

    it "fires on each advance with from/to context (no :call leakage)" do
      resilience.run_with_model_fallback("claude-haiku-4-5") do |model|
        raise RubyLLM::OverloadedError if model == "claude-haiku-4-5"

        "ok"
      end

      expect(events.length).to eq(1)
      expect(events.first[:from]).to eq(service: "api:anthropic:haiku", model: "claude-haiku-4-5")
      expect(events.first[:to]).to eq(service: "api:anthropic:sonnet", model: "claude-sonnet-4-6")
      expect(events.first[:error]).to eq(RubyLLM::OverloadedError)
      expect(events.first[:from]).not_to have_key(:call)
    end

    it "fires when a step is SKIPPED because its breaker is open" do
      breaker = RubyLLM::Resilience::Breaker.new("api:anthropic:haiku")
      resilience.config.failure_threshold.times { breaker.record_failure }

      resilience.run_with_model_fallback("claude-haiku-4-5") { |_model| "ok" }

      expect(events.length).to eq(1)
      expect(events.first[:error]).to eq(RubyLLM::Resilience::BreakerTripped)
    end

    it "does not fire when the first step succeeds" do
      resilience.run_with_model_fallback("claude-haiku-4-5") { |_model| "ok" }
      expect(events).to be_empty
    end

    it "does not fire past the last step (nothing to advance to)" do
      expect do
        resilience.run_with_model_fallback("claude-haiku-4-5") do |_model|
          raise RubyLLM::ServerError
        end
      end.to raise_error(RubyLLM::ServerError)
      expect(events.length).to eq(1) # haiku→sonnet only; no event after sonnet fails
    end

    it "never lets a raising on_fallback break the chain" do
      resilience.reset_configuration!
      resilience.configure do |c|
        c.provider_resolver = ->(_m) { "anthropic" }
        c.fallback_models = { "claude-haiku-4-5" => "claude-sonnet-4-6" }
        c.on_fallback = ->(from:, to:, error:) { raise "telemetry down" }
      end

      result = resilience.run_with_model_fallback("claude-haiku-4-5") do |model|
        raise RubyLLM::ServerError if model == "claude-haiku-4-5"

        "still-ok"
      end
      expect(result).to eq("still-ok")
    end
  end
end
