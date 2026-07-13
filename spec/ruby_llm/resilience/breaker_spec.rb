# frozen_string_literal: true

RSpec.describe RubyLLM::Resilience::Breaker do
  subject(:breaker) { described_class.new("api:test:svc") }

  let(:config) { RubyLLM::Resilience.config }

  describe "state machine" do
    it "starts closed" do
      expect(breaker.state).to eq(:closed)
      expect(breaker.allow_request?).to be(true)
      expect(breaker.open?).to be(false)
    end

    it "stays closed below the failure threshold" do
      (config.failure_threshold - 1).times { breaker.record_failure }
      expect(breaker.state).to eq(:closed)
      expect(breaker.failure_count).to eq(config.failure_threshold - 1)
    end

    it "opens at the failure threshold" do
      config.failure_threshold.times { breaker.record_failure }
      expect(breaker.state).to eq(:open)
      expect(breaker.allow_request?).to be(false)
      expect(breaker.open?).to be(true)
    end

    it "clears the failure counter when it trips" do
      config.failure_threshold.times { breaker.record_failure }
      expect(breaker.failure_count).to eq(0)
    end

    it "moves to half-open after the cooldown" do
      at_time(1_000)
      config.failure_threshold.times { breaker.record_failure }
      expect(breaker.state).to eq(:open)

      at_time(1_000 + config.cooldown_seconds + 1)
      expect(breaker.state).to eq(:half_open)
    end

    it "closes from half-open on a successful probe" do
      at_time(1_000)
      config.failure_threshold.times { breaker.record_failure }
      at_time(1_000 + config.cooldown_seconds + 1)

      expect(breaker.allow_request?).to be(true) # the probe
      breaker.record_success
      expect(breaker.state).to eq(:closed)
      expect(breaker.failure_count).to eq(0)
    end

    it "re-opens immediately when the half-open probe fails" do
      at_time(1_000)
      config.failure_threshold.times { breaker.record_failure }
      at_time(1_000 + config.cooldown_seconds + 1)

      expect(breaker.allow_request?).to be(true)
      breaker.record_failure # single probe failure — no threshold counting
      expect(breaker.state).to eq(:open)
    end

    it "expires the failure window so stale failures don't accumulate" do
      at_time(1_000)
      (config.failure_threshold - 1).times { breaker.record_failure }

      at_time(1_000 + config.failures_window_seconds + 1)
      expect(breaker.failure_count).to eq(0)
      breaker.record_failure
      expect(breaker.state).to eq(:closed)
    end
  end

  describe "probe lock (half-open)" do
    before do
      at_time(1_000)
      config.failure_threshold.times { breaker.record_failure }
      at_time(1_000 + config.cooldown_seconds + 1)
    end

    it "grants exactly one probe" do
      results = Array.new(5) { described_class.new("api:test:svc").allow_request? }
      expect(results.count(true)).to eq(1)
      expect(results.count(false)).to eq(4)
    end

    it "frees the probe slot after one cooldown if the probe never reports" do
      expect(breaker.allow_request?).to be(true)
      expect(breaker.allow_request?).to be(false)

      at_time(1_000 + (config.cooldown_seconds * 2) + 2)
      expect(breaker.allow_request?).to be(true)
    end
  end

  describe "API purity" do
    before do
      at_time(1_000)
      config.failure_threshold.times { breaker.record_failure }
      at_time(1_000 + config.cooldown_seconds + 1)
    end

    it "open?/state/failure_count/seconds_until_probe never consume the probe slot" do
      10.times do
        breaker.open?
        breaker.state
        breaker.failure_count
        breaker.seconds_until_probe
      end
      # The probe must still be available for the first real request.
      expect(breaker.allow_request?).to be(true)
    end

    it "reports half-open as not-open (pure view)" do
      expect(breaker.state).to eq(:half_open)
      expect(breaker.open?).to be(false)
    end
  end

  describe "#seconds_until_probe" do
    it "is nil when closed" do
      expect(breaker.seconds_until_probe).to be_nil
    end

    it "counts down while open and floors at 0" do
      at_time(1_000)
      config.failure_threshold.times { breaker.record_failure }

      at_time(1_000 + 20)
      expect(breaker.seconds_until_probe).to eq(config.cooldown_seconds - 20)

      at_time(1_000 + config.cooldown_seconds + 5)
      expect(breaker.seconds_until_probe).to eq(0)
    end
  end

  describe "callbacks" do
    it "fires on_status(:open) and on_error exactly once per trip" do
      statuses = []
      errors = []
      RubyLLM::Resilience.reset_configuration!
      RubyLLM::Resilience.configure do |c|
        c.on_status = ->(service, state) { statuses << [ service, state ] }
        c.on_error  = ->(error, ctx) { errors << [ error.class, ctx[:service] ] }
      end

      b = described_class.new("api:test:svc")
      RubyLLM::Resilience.config.failure_threshold.times { b.record_failure }

      expect(statuses).to eq([ [ "api:test:svc", :open ] ])
      expect(errors).to eq([ [ RubyLLM::Resilience::BreakerTripped, "api:test:svc" ] ])
    end

    it "fires on_status(:closed) on every success (gauge semantics)" do
      statuses = []
      RubyLLM::Resilience.reset_configuration!
      RubyLLM::Resilience.configure do |c|
        c.on_status = ->(service, state) { statuses << [ service, state ] }
      end

      b = described_class.new("api:test:svc")
      3.times { b.record_success }
      expect(statuses).to eq([ [ "api:test:svc", :closed ] ] * 3)
    end

    it "never lets a raising callback break the call path" do
      RubyLLM::Resilience.reset_configuration!
      RubyLLM::Resilience.configure do |c|
        c.on_status = ->(_s, _st) { raise "boom" }
        c.on_error  = ->(_e, _c) { raise "boom" }
      end

      b = described_class.new("api:test:svc")
      expect { b.record_success }.not_to raise_error
      expect { RubyLLM::Resilience.config.failure_threshold.times { b.record_failure } }
        .not_to raise_error
    end
  end

  describe "fail-open on store outage" do
    before do
      RubyLLM::Resilience.reset_configuration!
      RubyLLM::Resilience.configure do |c|
        c.cache_store = ExplodingStore.new
        c.on_error = ->(error, ctx) { (@reported ||= []) << [ error.message, ctx[:phase] ] }
      end
    end

    it "treats the breaker as closed and allows requests" do
      expect(breaker.state).to eq(:closed)
      expect(breaker.allow_request?).to be(true)
      expect(breaker.open?).to be(false)
    end

    it "never raises from record_success/record_failure" do
      expect { breaker.record_success }.not_to raise_error
      expect { breaker.record_failure }.not_to raise_error
    end

    it "reports store errors through on_error" do
      breaker.state
      expect(@reported).to include([ "store is down", "circuit_breaker_store" ])
    end
  end

  describe "registry + dashboard" do
    it "registers services on instantiation and reports pure status" do
      described_class.new("api:a")
      described_class.new("api:b")

      status = described_class.dashboard_status
      expect(status.map { |s| s[:service] }).to eq(%w[api:a api:b])
      expect(status.first).to include(state: :closed, failure_count: 0, seconds_until_probe: nil)
    end

    it "accepts an explicit service list" do
      status = described_class.dashboard_status(services: %w[api:only])
      expect(status.map { |s| s[:service] }).to eq(%w[api:only])
    end
  end
end
