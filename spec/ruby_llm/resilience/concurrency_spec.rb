# frozen_string_literal: true

RSpec.describe "concurrency" do
  it "trips at most once when threads race record_failure around the threshold" do
    trips = Queue.new
    RubyLLM::Resilience.configure do |c|
      c.failure_threshold = 5
      c.on_status = ->(_service, state) { trips << state if state == :open }
    end

    breaker = RubyLLM::Resilience::Breaker.new("api:race")
    Array.new(20) { Thread.new { breaker.record_failure } }.each(&:join)

    expect(breaker.state).to eq(:open)
    expect(trips.size).to eq(1)
  end

  it "grants exactly one probe across threads in half-open" do
    at_time = 1_000.0
    allow(Time).to receive(:now).and_return(Time.at(at_time))

    breaker = RubyLLM::Resilience::Breaker.new("api:race2")
    RubyLLM::Resilience.config.failure_threshold.times { breaker.record_failure }

    allow(Time).to receive(:now)
      .and_return(Time.at(at_time + RubyLLM::Resilience.config.cooldown_seconds + 1))

    results = Array.new(20) do
      Thread.new { RubyLLM::Resilience::Breaker.new("api:race2").allow_request? }
    end.map(&:value)

    expect(results.count(true)).to eq(1)
  end
end
