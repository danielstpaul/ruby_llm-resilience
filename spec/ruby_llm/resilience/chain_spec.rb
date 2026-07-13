# frozen_string_literal: true

RSpec.describe RubyLLM::Resilience::Chain do
  let(:resilience) { RubyLLM::Resilience }
  let(:threshold) { resilience.config.failure_threshold }

  def trip!(service)
    breaker = RubyLLM::Resilience::Breaker.new(service)
    threshold.times { breaker.record_failure }
  end

  describe ".run" do
    it "returns the block result and records success" do
      expect(resilience.run("api:x") { 42 }).to eq(42)
    end

    it "raises BreakerTripped without calling the block when open" do
      trip!("api:x")
      called = false
      expect { resilience.run("api:x") { called = true } }
        .to raise_error(RubyLLM::Resilience::BreakerTripped, /api:x/)
      expect(called).to be(false)
    end

    it "re-raises the original error" do
      expect { resilience.run("api:x") { raise RubyLLM::ServerError, "boom" } }
        .to raise_error(RubyLLM::ServerError, "boom")
    end

    it "counts trippable errors toward the threshold" do
      threshold.times do
        expect { resilience.run("api:x") { raise RubyLLM::RateLimitError } }
          .to raise_error(RubyLLM::RateLimitError)
      end
      expect(RubyLLM::Resilience::Breaker.new("api:x").state).to eq(:open)
    end

    it "does NOT count client errors (4xx) toward the threshold" do
      (threshold * 2).times do
        expect { resilience.run("api:x") { raise RubyLLM::BadRequestError } }
          .to raise_error(RubyLLM::BadRequestError)
      end
      expect(RubyLLM::Resilience::Breaker.new("api:x").state).to eq(:closed)
    end

    it "does NOT count programming errors toward the threshold" do
      (threshold * 2).times do
        expect { resilience.run("api:x") { raise NoMethodError, "bug" } }
          .to raise_error(NoMethodError)
      end
      expect(RubyLLM::Resilience::Breaker.new("api:x").state).to eq(:closed)
    end

    it "preserves the failure count across interleaved non-trippable errors" do
      (threshold - 1).times do
        expect { resilience.run("api:x") { raise RubyLLM::ServerError } }
          .to raise_error(RubyLLM::ServerError)
      end
      expect { resilience.run("api:x") { raise RubyLLM::BadRequestError } }
        .to raise_error(RubyLLM::BadRequestError)

      expect(RubyLLM::Resilience::Breaker.new("api:x").failure_count).to eq(threshold - 1)
    end
  end

  describe ".run_with_fallback" do
    it "returns the first successful step" do
      result = resilience.run_with_fallback(
        { service: "api:a", call: -> { "from-a" } },
        { service: "api:b", call: -> { "from-b" } }
      )
      expect(result).to eq("from-a")
    end

    it "falls through to the next step on fallback-class errors" do
      result = resilience.run_with_fallback(
        { service: "api:a", call: -> { raise RubyLLM::ServerError } },
        { service: "api:b", call: -> { "from-b" } }
      )
      expect(result).to eq("from-b")
    end

    it "falls through on ModelNotFoundError (new-model rollout window)" do
      result = resilience.run_with_fallback(
        { service: "api:a", call: -> { raise RubyLLM::ModelNotFoundError } },
        { service: "api:b", call: -> { "from-b" } }
      )
      expect(result).to eq("from-b")
    end

    it "skips steps whose breaker is open without calling them" do
      trip!("api:a")
      a_called = false
      result = resilience.run_with_fallback(
        { service: "api:a", call: -> { a_called = true } },
        { service: "api:b", call: -> { "from-b" } }
      )
      expect(a_called).to be(false)
      expect(result).to eq("from-b")
    end

    it "raises BreakerTripped when exhausted and ANY step was skipped-open" do
      trip!("api:a")
      expect do
        resilience.run_with_fallback(
          { service: "api:a", call: -> { "never" } },
          { service: "api:b", call: -> { raise RubyLLM::ServerError, "real" } }
        )
      end.to raise_error(RubyLLM::Resilience::BreakerTripped)
    end

    it "raises the last real error when exhausted with no breaker involvement" do
      expect do
        resilience.run_with_fallback(
          { service: "api:a", call: -> { raise RubyLLM::ServerError, "first" } },
          { service: "api:b", call: -> { raise RubyLLM::OverloadedError, "last" } }
        )
      end.to raise_error(RubyLLM::OverloadedError, "last")
    end

    it "propagates non-fallback errors immediately (bugs are not fallbacks)" do
      b_called = false
      expect do
        resilience.run_with_fallback(
          { service: "api:a", call: -> { raise ArgumentError, "bug" } },
          { service: "api:b", call: -> { b_called = true } }
        )
      end.to raise_error(ArgumentError, "bug")
      expect(b_called).to be(false)
    end

    it "requires at least one step" do
      expect { resilience.run_with_fallback }.to raise_error(ArgumentError)
    end
  end

  describe ".run_with_model_fallback" do
    before do
      RubyLLM::Resilience.reset_configuration!
      RubyLLM::Resilience.configure do |c|
        c.fallback_models = { "claude-haiku-4-5" => "claude-sonnet-4-6" }
        c.provider_resolver = ->(_model) { "anthropic" }
      end
    end

    it "yields the primary model first" do
      models_seen = []
      resilience.run_with_model_fallback("claude-haiku-4-5") do |model|
        models_seen << model
        "ok"
      end
      expect(models_seen).to eq([ "claude-haiku-4-5" ])
    end

    it "hops ONCE to the mapped fallback model on trippable errors" do
      models_seen = []
      result = resilience.run_with_model_fallback("claude-haiku-4-5") do |model|
        models_seen << model
        raise RubyLLM::OverloadedError if model == "claude-haiku-4-5"

        "recovered-on-#{model}"
      end
      expect(models_seen).to eq([ "claude-haiku-4-5", "claude-sonnet-4-6" ])
      expect(result).to eq("recovered-on-claude-sonnet-4-6")
    end

    it "routes primary and fallback through their own tier breakers" do
      resilience.run_with_model_fallback("claude-haiku-4-5") do |model|
        raise RubyLLM::OverloadedError if model == "claude-haiku-4-5"

        "ok"
      end
      expect(RubyLLM::Resilience::Breaker.new("api:anthropic:haiku").failure_count).to eq(1)
      expect(RubyLLM::Resilience::Breaker.new("api:anthropic:sonnet").failure_count).to eq(0)
    end

    it "runs a single step when the model has no fallback entry" do
      expect do
        resilience.run_with_model_fallback("claude-opus-unmapped") do |_model|
          raise RubyLLM::ServerError, "no escape"
        end
      end.to raise_error(RubyLLM::ServerError, "no escape")
    end
  end

  describe "custom error lists" do
    it "honours configured trippable_errors instead of defaults" do
      custom = Class.new(StandardError)
      RubyLLM::Resilience.reset_configuration!
      RubyLLM::Resilience.configure { |c| c.trippable_errors = [ custom ] }

      expect(resilience.trippable?(custom.new)).to be(true)
      expect(resilience.trippable?(RubyLLM::ServerError.new)).to be(false)
    end
  end
end
