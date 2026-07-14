# frozen_string_literal: true

require_relative "resilience/version"
require_relative "resilience/errors"
require_relative "resilience/memory_store"
require_relative "resilience/tier_namer"
require_relative "resilience/configuration"
require_relative "resilience/breaker"
require_relative "resilience/chain"

# Under Rails the dashboard engine loads automatically (mounting it stays
# opt-in via routes). Outside Rails the core works alone — zero dependencies.
require_relative "resilience/engine" if defined?(::Rails::Engine)

module RubyLLM
  # Circuit breakers and fallback chains for LLM apps.
  #
  #   RubyLLM::Resilience.configure do |c|
  #     c.cache_store = ActiveSupport::Cache::RedisCacheStore.new(...)
  #     c.fallback_models = { "claude-haiku-4-5" => "claude-sonnet-4-6" }
  #     c.on_error  = ->(error, ctx) { Rails.error.report(error, context: ctx) }
  #     c.on_status = ->(service, state) { Appsignal.set_gauge("circuit_breaker.state", state == :open ? 1 : 0, service:) }
  #   end
  #
  #   RubyLLM::Resilience.run("api:openai:embeddings") { RubyLLM.embed(text) }
  module Resilience
    class << self
      def config
        @config ||= Configuration.new
      end

      # Configure once at boot; the configuration freezes afterwards so
      # fiber/thread safety comes from immutability. Use
      # reset_configuration! in tests.
      def configure
        @config ||= Configuration.new
        yield @config
        @config.freeze
        @config
      end

      def reset_configuration!
        @config = Configuration.new
        Breaker.reset_registry!
        @config
      end

      def run(service, &block)
        Chain.run(service, &block)
      end

      def run_with_model_fallback(primary_model, fallback: :map, &block)
        Chain.run_with_model_fallback(primary_model, fallback: fallback, &block)
      end

      def run_with_fallback(*steps)
        Chain.run_with_fallback(*steps)
      end

      def trippable?(error)
        config.resolved_trippable_errors.any? { |klass| error.is_a?(klass) }
      end

      # Convenience: the breaker name the configured service_namer would
      # assign to a model.
      def service_for(model_name)
        config.service_namer.call(model_name)
      end

      # Fallback routing grouped by breaker service, for dashboards:
      #   { "api:anthropic:haiku" => ["claude-haiku-4-5 → claude-sonnet-4-6"], ... }
      # A service can carry several routes when multiple models map into the
      # same tier breaker.
      def fallback_routes
        config.fallback_models.keys.each_with_object(Hash.new { |h, k| h[k] = [] }) do |model, routes|
          service = service_for(model)
          chain = [ model, *config.fallbacks_for(model) ]
          routes[service] << chain.join(" → ")
        end
      end
    end
  end
end
