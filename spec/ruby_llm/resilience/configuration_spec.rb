# frozen_string_literal: true

RSpec.describe RubyLLM::Resilience::Configuration do
  describe "lazy error resolution" do
    it "resolves the default lists against loaded constants" do
      trippable = RubyLLM::Resilience.config.resolved_trippable_errors
      expect(trippable).to include(RubyLLM::RateLimitError, Faraday::TimeoutError)
      expect(trippable).not_to include(RubyLLM::BadRequestError)
    end

    it "silently skips constants that aren't defined" do
      resolved = RubyLLM::Resilience::ErrorResolution.resolve(
        [ "RubyLLM::ServerError", "Nonexistent::Error" ]
      )
      expect(resolved).to eq([ RubyLLM::ServerError ])
    end
  end

  describe "configure-at-boot-then-freeze" do
    it "freezes the configuration after configure" do
      RubyLLM::Resilience.configure { |c| c.failure_threshold = 3 }
      expect(RubyLLM::Resilience.config).to be_frozen
      expect { RubyLLM::Resilience.config.failure_threshold = 9 }
        .to raise_error(FrozenError)
    end

    it "reset_configuration! restores mutable defaults and clears the registry" do
      RubyLLM::Resilience.configure { |c| c.failure_threshold = 3 }
      RubyLLM::Resilience::Breaker.new("api:stale")

      RubyLLM::Resilience.reset_configuration!

      expect(RubyLLM::Resilience.config.failure_threshold).to eq(5)
      expect(RubyLLM::Resilience.config).not_to be_frozen
      expect(RubyLLM::Resilience::Breaker.known_services).to be_empty
    end
  end

  describe "two configurations don't leak into each other" do
    it "isolates settings across reset boundaries" do
      RubyLLM::Resilience.configure { |c| c.cooldown_seconds = 999 }
      expect(RubyLLM::Resilience.config.cooldown_seconds).to eq(999)

      RubyLLM::Resilience.reset_configuration!
      expect(RubyLLM::Resilience.config.cooldown_seconds).to eq(120)
    end
  end
end

RSpec.describe "shorthand require" do
  it "defines ::Resilience only when explicitly required" do
    require "ruby_llm/resilience/shorthand"
    expect(::Resilience).to eq(RubyLLM::Resilience)
  end
end

RSpec.describe "Resilience.fallback_routes" do
  it "groups model chains by breaker service" do
    RubyLLM::Resilience.configure do |c|
      c.provider_resolver = ->(_m) { "anthropic" }
      c.fallback_models = {
        "claude-sonnet-4-5" => "claude-opus-4-7",
        "claude-sonnet-4-6" => [ "claude-opus-4-7", "claude-haiku-4-5" ]
      }
    end

    routes = RubyLLM::Resilience.fallback_routes
    expect(routes["api:anthropic:sonnet"]).to contain_exactly(
      "claude-sonnet-4-5 → claude-opus-4-7",
      "claude-sonnet-4-6 → claude-opus-4-7 → claude-haiku-4-5"
    )
  end
end
