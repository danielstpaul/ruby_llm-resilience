# frozen_string_literal: true

module RubyLLM
  module Resilience
    # All five injection seams live here. Configure once at boot, then the
    # configuration is frozen — concurrency safety comes from immutability,
    # not locks. (Use RubyLLM::Resilience.reset_configuration! in tests.)
    class Configuration
      # Server-side unhealthiness — these TRIP the breaker. Client errors
      # (4xx, auth, bad request) never do: those are your bug, not their
      # outage. Resolved lazily so ruby_llm/faraday remain soft dependencies.
      DEFAULT_TRIPPABLE_NAMES = %w[
        RubyLLM::RateLimitError
        RubyLLM::ServerError
        RubyLLM::ServiceUnavailableError
        RubyLLM::OverloadedError
        Faraday::TimeoutError
        Faraday::ConnectionFailed
        Faraday::ServerError
      ].freeze

      # Errors that advance a fallback chain to its next step (without
      # necessarily tripping). ModelNotFoundError is deliberate: it covers
      # new-model rollout windows where a registry misses an ID. Programming
      # bugs (NoMethodError, ArgumentError) are NOT here — those propagate so
      # they surface in your error tracker instead of silently degrading.
      DEFAULT_FALLBACK_NAMES = %w[
        RubyLLM::Error
        RubyLLM::ModelNotFoundError
        Faraday::Error
      ].freeze

      attr_accessor :cache_store, :failure_threshold, :cooldown_seconds,
                    :failures_window_seconds, :fallback_models,
                    :on_error, :on_status, :on_fallback,
                    :provider_resolver, :service_namer,
                    :trippable_errors, :fallback_errors,
                    :services, :service_metadata, :dashboard_auth, :dashboard_services

      # Normalized fallback hops for a model: always an Array (possibly empty).
      def fallbacks_for(model_name)
        Array(@fallback_models[model_name.to_s])
      end

      # Effective per-service settings (global defaults + per-service override).
      Settings = Struct.new(:failure_threshold, :cooldown_seconds, :failures_window_seconds)

      def initialize
        @cache_store = MemoryStore.new
        @failure_threshold = 5
        @cooldown_seconds = 120
        @failures_window_seconds = 3600
        # Model → fallback(s). Values may be a single model or an array of
        # hops, tried in order:
        #   c.fallback_models = {
        #     "claude-haiku-4-5"  => "claude-sonnet-4-6",                       # one hop
        #     "gemini-3.5-flash"  => ["claude-sonnet-4-6", "claude-opus-4-7"]   # multi-hop
        #   }
        # One deliberate hop is the recommended default (capacity incidents
        # are tier-correlated; chains of desperation compound quality drift) —
        # multi-hop is available, not encouraged.
        @fallback_models = {}
        @on_error = ->(_error, _context) {}
        @on_status = ->(_service, _state) {}

        # Fired every time a chain advances past a failed/skipped step —
        # the audit trail that keeps fallback an emergency, not an ambient
        # optimization:
        #   c.on_fallback = ->(from:, to:, error:) {
        #     Appsignal.increment_counter("llm.fallback", 1,
        #       from: from[:service], to: to[:service], error: error.class.name)
        #   }
        @on_fallback = ->(from:, to:, error:) {}
        @provider_resolver = default_provider_resolver
        @service_namer = TierNamer
        @trippable_errors = nil # nil => lazy defaults (see resolved_* below)
        @fallback_errors = nil

        # Per-service overrides for the three breaker knobs. A cheap
        # fast-recovery moderation endpoint and an expensive batch endpoint
        # shouldn't share one cooldown:
        #   c.services = { "api:openai:moderation" => { cooldown_seconds: 30 } }
        @services = {}

        # App knowledge for dashboards — descriptions belong in config, not
        # hardcoded in a controller:
        #   c.service_metadata = { "api:anthropic:sonnet" =>
        #     { description: "Coaching + generation", consumers: "Chat, Practice" } }
        @service_metadata = {}

        # Default service list for the dashboard engine. nil = the
        # per-process registry (services seen since boot). Apps with a known
        # static fleet should set this so the dashboard is complete from the
        # first request:
        #   c.dashboard_services = %w[api:anthropic:sonnet api:openai:gpt ...]
        @dashboard_services = nil

        # Auth hook for the mountable dashboard (see resilience/engine).
        # DENY BY DEFAULT: mounting without configuring this renders 404 on
        # every request. Override with e.g.
        #   c.dashboard_auth = ->(controller) {
        #     controller.head :not_found unless controller.current_user&.admin?
        #   }
        @dashboard_auth = ->(controller) { controller.head :not_found }
      end

      def settings_for(service)
        override = @services[service.to_s] || {}
        Settings.new(
          override[:failure_threshold] || failure_threshold,
          override[:cooldown_seconds] || cooldown_seconds,
          override[:failures_window_seconds] || failures_window_seconds
        )
      end

      def metadata_for(service)
        @service_metadata[service.to_s] || {}
      end

      def resolved_trippable_errors
        @trippable_errors || ErrorResolution.resolve(DEFAULT_TRIPPABLE_NAMES)
      end

      def resolved_fallback_errors
        @fallback_errors || ErrorResolution.resolve(DEFAULT_FALLBACK_NAMES)
      end

      private

      # RubyLLM's Models#find RAISES ModelNotFoundError for unknown ids — and
      # unknown ids occur precisely during new-model rollout windows. Rescue
      # to "unknown" rather than letting the resolver take down the call.
      def default_provider_resolver
        lambda do |model_name|
          return "unknown" unless defined?(::RubyLLM) && ::RubyLLM.respond_to?(:models)

          begin
            ::RubyLLM.models.find(model_name.to_s)&.provider.to_s
          rescue StandardError
            "unknown"
          end
        end
      end
    end
  end
end
