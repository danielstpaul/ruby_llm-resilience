# frozen_string_literal: true

RSpec.describe "per-service configuration" do
  before do
    RubyLLM::Resilience.configure do |c|
      c.failure_threshold = 5
      c.cooldown_seconds = 120
      c.services = {
        "api:openai:moderation" => { failure_threshold: 2, cooldown_seconds: 30 }
      }
      c.service_metadata = {
        "api:openai:moderation" => { description: "Content moderation", consumers: "Message flow" }
      }
    end
  end

  it "applies overridden thresholds to the named service only" do
    moderation = RubyLLM::Resilience::Breaker.new("api:openai:moderation")
    other = RubyLLM::Resilience::Breaker.new("api:other")

    2.times { moderation.record_failure }
    2.times { other.record_failure }

    expect(moderation.state).to eq(:open)   # trips at its own threshold of 2
    expect(other.state).to eq(:closed)      # global threshold of 5 still applies
  end

  it "applies overridden cooldowns" do
    at_time(1_000)
    moderation = RubyLLM::Resilience::Breaker.new("api:openai:moderation")
    2.times { moderation.record_failure }

    at_time(1_000 + 31)
    expect(moderation.state).to eq(:half_open) # 30s cooldown, not 120s
  end

  it "falls back to globals for unspecified knobs" do
    settings = RubyLLM::Resilience.config.settings_for("api:openai:moderation")
    expect(settings.failures_window_seconds).to eq(3600) # not overridden
    expect(settings.failure_threshold).to eq(2)
  end

  it "exposes metadata through dashboard_status" do
    RubyLLM::Resilience::Breaker.new("api:openai:moderation")
    status = RubyLLM::Resilience::Breaker.dashboard_status.first
    expect(status[:metadata]).to eq(description: "Content moderation", consumers: "Message flow")
  end

  it "returns empty metadata for undescribed services" do
    RubyLLM::Resilience::Breaker.new("api:mystery")
    status = RubyLLM::Resilience::Breaker.dashboard_status(services: %w[api:mystery]).first
    expect(status[:metadata]).to eq({})
  end
end
