# frozen_string_literal: true

# ruby_llm-resilience — circuit breakers and fallback chains for LLM calls.
# Docs: https://github.com/danielstpaul/ruby_llm-resilience
#
# Everything below is optional; the gem works with defaults out of the box
# (per-process memory store, threshold 5, cooldown 120s). The two settings
# most apps DO want are cache_store (multi-process correctness) and
# fallback_models (the actual routing).
RubyLLM::Resilience.configure do |config|
  # --- Store -----------------------------------------------------------
  # REQUIRED for multi-process apps: the default MemoryStore is per-process,
  # so a breaker tripped in one worker stays closed in the others. Any store
  # with read / write(expires_in:, unless_exist:) / increment(expires_in:) /
  # delete / delete_multi works — Redis is the usual choice:
  #
  # config.cache_store = ActiveSupport::Cache::RedisCacheStore.new(
  #   url: ENV["REDIS_URL"], namespace: "circuit_breaker"
  # )

  # --- Breaker knobs ----------------------------------------------------
  # config.failure_threshold       = 5    # consecutive failures before trip
  # config.cooldown_seconds        = 120  # open duration before a probe
  # config.failures_window_seconds = 3600 # failure-counter window
  #
  # Per-service overrides (a fast-recovery moderation endpoint shouldn't
  # share a cooldown with an expensive batch endpoint):
  # config.services = {
  #   "api:openai:moderation" => { failure_threshold: 2, cooldown_seconds: 30 }
  # }

  # --- Fallback routing -------------------------------------------------
  # One deliberate tier-hop per model is the recommended shape. Values may
  # be a single model or an array of hops.
  # config.fallback_models = {
  #   "claude-haiku-4-5"  => "claude-sonnet-4-6",
  #   "claude-sonnet-4-6" => "claude-opus-4-7",
  #   "gemini-3.5-flash"  => "claude-sonnet-4-6"   # cross-provider safety net
  # }

  # --- Telemetry (alert on the error, graph the gauge, trend the counter) —
  # config.on_error = ->(error, context) {
  #   Rails.error.report(error, handled: true, context: context)
  # }
  # config.on_status = ->(service, state) {
  #   Appsignal.set_gauge("circuit_breaker.state", state == :open ? 1 : 0, service: service)
  # }
  # config.on_fallback = ->(from:, to:, error:) {
  #   Appsignal.increment_counter("llm.fallback", 1,
  #     from: from[:service], to: to[:service], error: error.class.name)
  # }

  # --- Dashboard (mount RubyLLM::Resilience::Engine in routes.rb) --------
  # DENY-BY-DEFAULT: every dashboard request 404s until you configure this.
  # config.dashboard_auth = ->(controller) {
  #   controller.head :not_found unless controller.respond_to?(:current_user) &&
  #                                     controller.current_user&.admin?
  # }
  #
  # Show a static fleet (instead of only breakers seen since boot), with
  # descriptions for the About column:
  # config.dashboard_services = %w[api:anthropic:sonnet api:openai:moderation]
  # config.service_metadata = {
  #   "api:anthropic:sonnet" => { description: "Coaching", consumers: "Chat" }
  # }
end
