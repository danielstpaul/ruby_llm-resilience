# frozen_string_literal: true

# Demo app for the dashboard engine — development use only.
#   bundle exec puma demo/config.ru -p 9292
require "bundler/setup"
require "rails"
require "action_controller/railtie"
require_relative "../lib/ruby_llm/resilience/engine"

module Demo
  class Application < Rails::Application
    config.root = __dir__
    config.load_defaults Rails::VERSION::STRING.to_f
    config.eager_load = false
    config.hosts.clear
    config.secret_key_base = "demo-only"
    config.logger = Logger.new($stdout)
  end
end

Demo::Application.initialize!
Rails.application.routes.draw { mount RubyLLM::Resilience::Engine => "/" }

RubyLLM::Resilience.configure do |c|
  c.dashboard_auth = ->(_controller) {} # demo: allow everyone
  c.services = {
    # 90s cooldown: watch the countdown hit 0 and the pill turn amber
    # (open → half-open) on auto-refresh, live.
    "api:openai:moderation" => { failure_threshold: 2, cooldown_seconds: 90 },
    # Long cooldown: a steady red pill to look at.
    "api:google:flash"      => { cooldown_seconds: 600 }
  }
  c.fallback_models = {
    "claude-haiku-4-5"  => "claude-sonnet-4-6",
    "claude-sonnet-4-6" => "claude-opus-4-7",
    "gemini-3.5-flash"  => [ "claude-sonnet-4-6", "claude-opus-4-7" ]
  }
  c.provider_resolver = ->(m) { m.start_with?("claude") ? "anthropic" : m.start_with?("gemini") ? "gemini" : "unknown" }
  c.on_error = ->(error, ctx) { puts "[demo on_error] #{error.class}: #{ctx.inspect}" }
  c.service_metadata = {
    "api:anthropic:sonnet"  => { description: "Coaching + generation", consumers: "Chat, Practice" },
    "api:openai:moderation" => { description: "Content moderation", consumers: "Message flow" },
    "api:google:flash"      => { description: "Quiz generation", consumers: "Learn" }
  }
end

# Seed one breaker per state so the demo shows the full palette.
RubyLLM::Resilience::Breaker.new("api:anthropic:sonnet")                      # closed
RubyLLM::Resilience::Breaker.new("api:anthropic:haiku").record_failure       # closed w/ failures
open_breaker = RubyLLM::Resilience::Breaker.new("api:openai:moderation")
2.times { open_breaker.record_failure }        # open — goes half-open after 90s, watch it live
steady = RubyLLM::Resilience::Breaker.new("api:google:flash")
5.times { steady.record_failure }              # open for 10 minutes — the steady red pill

run Rails.application
