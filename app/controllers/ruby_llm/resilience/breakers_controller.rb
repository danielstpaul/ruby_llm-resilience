# frozen_string_literal: true

module RubyLLM
  module Resilience
    class BreakersController < ActionController::Base
      # ruby_llm's Railtie registers `acronym "RubyLLM"`, which changes this
      # controller's DERIVED controller_path to "rubyllm/resilience/breakers"
      # in host apps — breaking template lookup (views ship under
      # app/views/ruby_llm/...). Pin the path so lookup is deterministic
      # regardless of the host's inflections.
      def self.controller_path
        "ruby_llm/resilience/breakers"
      end

      protect_from_forgery with: :exception
      layout "ruby_llm/resilience/application"

      # Deny-by-default: the configured hook must explicitly allow the
      # request (by not rendering). The default hook 404s everything.
      before_action :authenticate_dashboard!

      def index
        services = params[:services].presence&.split(",") ||
                   Resilience.config.dashboard_services
        @statuses = Breaker.dashboard_status(services: services)
        @fallback_routes = Resilience.fallback_routes
        @config = Resilience.config
      end

      # "configured" when the app replaced the default no-op lambda (defaults
      # are all defined in configuration.rb — source_location tells them apart).
      helper_method def hook_status(hook)
        file = hook.respond_to?(:source_location) ? hook.source_location&.first : nil
        file&.end_with?("configuration.rb") ? "default" : "configured"
      end

      def reset
        Breaker.new(params[:id]).reset!
        redirect_to root_path, notice: "Reset #{params[:id]}"
      end

      private

      def authenticate_dashboard!
        Resilience.config.dashboard_auth.call(self)
      end
    end
  end
end
