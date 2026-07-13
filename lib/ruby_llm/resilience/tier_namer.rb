# frozen_string_literal: true

module RubyLLM
  module Resilience
    # Default service_namer: maps a model name to a per-provider, per-TIER
    # breaker name ("api:anthropic:sonnet").
    #
    # Tier-level (not per-model) breakers are deliberate: provider capacity
    # incidents are tier-correlated (when Sonnet is overloaded, every Sonnet
    # version typically is), and a version rollover (sonnet-4-5 → sonnet-4-6)
    # shouldn't fragment health state across two breakers.
    #
    # Custom naming is one lambda away:
    #   config.service_namer = ->(model) { "api:#{model}" }  # per-model
    module TierNamer
      module_function

      def call(model_name)
        provider = Resilience.config.provider_resolver.call(model_name).to_s

        case provider
        when "anthropic"         then anthropic(model_name)
        when "gemini", "google"  then google(model_name)
        when "openai"            then openai(model_name)
        else "api:unknown:other"
        end
      end

      def anthropic(model_name)
        case model_name.to_s
        when /haiku/  then "api:anthropic:haiku"
        when /sonnet/ then "api:anthropic:sonnet"
        when /opus/   then "api:anthropic:opus"
        else "api:anthropic:other"
        end
      end

      # Order matters — flash-lite must be tested before flash, since
      # "gemini-3.1-flash-lite" matches both /flash/ and /flash-lite/.
      def google(model_name)
        case model_name.to_s
        when /flash-lite/ then "api:google:flash-lite"
        when /flash/      then "api:google:flash"
        when /pro/        then "api:google:pro"
        else "api:google:other"
        end
      end

      # Order matters — `-nano` / `-mini` / `-pro` must be tested before the
      # bare `^gpt` match (gpt-5.5-pro matches both `-pro` and `^gpt`).
      def openai(model_name)
        case model_name.to_s
        when /-nano/ then "api:openai:gpt-nano"
        when /-mini/ then "api:openai:gpt-mini"
        when /-pro/  then "api:openai:gpt-pro"
        when /^gpt/  then "api:openai:gpt"
        else "api:openai:other"
        end
      end
    end
  end
end
