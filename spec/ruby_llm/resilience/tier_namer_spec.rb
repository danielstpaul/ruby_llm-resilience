# frozen_string_literal: true

RSpec.describe RubyLLM::Resilience::TierNamer do
  before do
    RubyLLM::Resilience.reset_configuration!
    RubyLLM::Resilience.configure do |c|
      c.provider_resolver = lambda do |model|
        case model.to_s
        when /\Aclaude/ then "anthropic"
        when /\Agemini/ then "gemini"
        when /\Agpt/, /\Ao\d/ then "openai"
        else "unknown"
        end
      end
    end
  end

  describe "anthropic tiers" do
    it { expect(described_class.call("claude-haiku-4-5")).to eq("api:anthropic:haiku") }
    it { expect(described_class.call("claude-sonnet-4-6")).to eq("api:anthropic:sonnet") }
    it { expect(described_class.call("claude-opus-4-7")).to eq("api:anthropic:opus") }

    it "collapses versions into one tier breaker" do
      expect(described_class.call("claude-sonnet-4-5")).to eq(described_class.call("claude-sonnet-4-6"))
    end
  end

  describe "google tiers (ordering: flash-lite before flash)" do
    it { expect(described_class.call("gemini-2.5-flash-lite")).to eq("api:google:flash-lite") }
    it { expect(described_class.call("gemini-3.5-flash")).to eq("api:google:flash") }
    it { expect(described_class.call("gemini-3-pro")).to eq("api:google:pro") }
  end

  describe "openai tiers (ordering: -nano/-mini/-pro before ^gpt)" do
    it { expect(described_class.call("gpt-5.5-nano")).to eq("api:openai:gpt-nano") }
    it { expect(described_class.call("gpt-5.5-mini")).to eq("api:openai:gpt-mini") }
    it { expect(described_class.call("gpt-5.5-pro")).to eq("api:openai:gpt-pro") }
    it { expect(described_class.call("gpt-5.5")).to eq("api:openai:gpt") }
  end

  it "maps unknown providers to api:unknown:other" do
    expect(described_class.call("mystery-model")).to eq("api:unknown:other")
  end

  it "treats provider 'google' and 'gemini' identically" do
    RubyLLM::Resilience.reset_configuration!
    RubyLLM::Resilience.configure { |c| c.provider_resolver = ->(_m) { "google" } }
    expect(described_class.call("gemini-3.5-flash")).to eq("api:google:flash")
  end
end

RSpec.describe "default provider_resolver" do
  it "returns 'unknown' rather than raising when the registry misses" do
    # The stub RubyLLM module has no .models — the resolver must degrade.
    expect(RubyLLM::Resilience.config.provider_resolver.call("anything")).to eq("unknown")
  end
end
