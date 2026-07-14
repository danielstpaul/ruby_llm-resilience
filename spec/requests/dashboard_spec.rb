# frozen_string_literal: true

require "rails_helper"

RSpec.describe "dashboard engine", type: :request do
  def allow_dashboard!
    RubyLLM::Resilience.configure { |c| c.dashboard_auth = ->(_controller) {} }
  end

  describe "deny-by-default auth" do
    it "404s every route until an auth hook is configured" do
      get "/resilience"
      expect(response).to have_http_status(:not_found)

      post "/resilience/breakers/api:x/reset"
      expect(response).to have_http_status(:not_found)
    end

    it "passes the controller to the auth hook" do
      seen = nil
      RubyLLM::Resilience.configure do |c|
        c.dashboard_auth = ->(controller) { seen = controller.class.name; controller.head :not_found }
      end
      get "/resilience"
      expect(seen).to eq("RubyLLM::Resilience::BreakersController")
    end
  end

  describe "index" do
    before { allow_dashboard! }

    it "renders registered breakers with state pills and metadata" do
      RubyLLM::Resilience.reset_configuration!
      RubyLLM::Resilience.configure do |c|
        c.dashboard_auth = ->(_controller) {}
        c.service_metadata = { "api:demo" => { description: "Demo service" } }
      end
      RubyLLM::Resilience::Breaker.new("api:demo")

      get "/resilience"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("api:demo")
      expect(response.body).to include("closed")
      expect(response.body).to include("Demo service")
    end

    it "accepts an explicit services param" do
      get "/resilience", params: { services: "api:one,api:two" }
      expect(response.body).to include("api:one").and include("api:two")
    end

    it "shows the empty state when nothing is registered" do
      get "/resilience"
      expect(response.body).to include("No breakers registered")
    end
  end

  describe "reset" do
    before { allow_dashboard! }

    it "force-closes an open breaker (service names keep their colons)" do
      breaker = RubyLLM::Resilience::Breaker.new("api:anthropic:sonnet")
      RubyLLM::Resilience.config.failure_threshold.times { breaker.record_failure }
      expect(breaker.state).to eq(:open)

      post "/resilience/breakers/#{CGI.escape('api:anthropic:sonnet')}/reset"
      expect(response).to redirect_to("/resilience/")

      expect(breaker.state).to eq(:closed)
    end
  end
end

RSpec.describe "dashboard_services config", type: :request do
  it "uses the configured static list when no params given" do
    RubyLLM::Resilience.configure do |c|
      c.dashboard_auth = ->(_controller) {}
      c.dashboard_services = %w[api:static:one api:static:two]
    end
    get "/resilience"
    expect(response.body).to include("api:static:one").and include("api:static:two")
  end
end

RSpec.describe "fleshed-out dashboard", type: :request do
  before do
    RubyLLM::Resilience.configure do |c|
      c.dashboard_auth = ->(_controller) {}
      c.provider_resolver = ->(m) { m.start_with?("claude") ? "anthropic" : "unknown" }
      c.fallback_models = {
        "claude-haiku-4-5"  => "claude-sonnet-4-6",
        "claude-sonnet-4-6" => [ "claude-opus-4-7", "claude-haiku-4-5" ]
      }
      c.services = { "api:anthropic:haiku" => { failure_threshold: 2, cooldown_seconds: 30 } }
      c.on_error = ->(_e, _c) { :wired }
    end
    RubyLLM::Resilience::Breaker.new("api:anthropic:haiku")
    RubyLLM::Resilience::Breaker.new("api:anthropic:sonnet")
  end

  it "shows fallback routes derived from the model map (multi-hop included)" do
    get "/resilience"
    expect(response.body).to include("claude-haiku-4-5 → claude-sonnet-4-6")
    expect(response.body).to include("claude-sonnet-4-6 → claude-opus-4-7 → claude-haiku-4-5")
  end

  it "shows failures against the effective per-service threshold and cooldown" do
    get "/resilience"
    expect(response.body).to include("0 / 2")   # overridden threshold
    expect(response.body).to include("30s")     # overridden cooldown
    expect(response.body).to include("0 / 5")   # global default on the other row
  end

  it "shows which telemetry hooks are configured vs default" do
    get "/resilience"
    expect(response.body).to match(%r{on_error</code> <span class="hook configured})
    expect(response.body).to match(%r{on_status</code> <span class="hook default})
  end
end
