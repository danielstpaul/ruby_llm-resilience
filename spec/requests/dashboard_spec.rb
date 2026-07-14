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
