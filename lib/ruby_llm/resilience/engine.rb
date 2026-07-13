# frozen_string_literal: true

# Optional mountable dashboard. Deliberately NOT loaded by the default
# require — the core gem has zero dependencies and works outside Rails.
#
#   # config/application.rb (or an initializer)
#   require "ruby_llm/resilience/engine"
#
#   # config/routes.rb
#   mount RubyLLM::Resilience::Engine => "/resilience"
#
# SECURITY: the dashboard denies by default. Every request 404s until you
# configure an auth hook:
#
#   RubyLLM::Resilience.configure do |c|
#     c.dashboard_auth = ->(controller) {
#       controller.head :not_found unless controller.respond_to?(:current_user) &&
#                                         controller.current_user&.admin?
#     }
#   end
raise LoadError, "ruby_llm/resilience/engine requires Rails" unless defined?(::Rails::Engine)

require "ruby_llm/resilience"

module RubyLLM
  module Resilience
    class Engine < ::Rails::Engine
      isolate_namespace RubyLLM::Resilience

      # Zeitwerk camelizes "ruby_llm" to "RubyLlm" without this. Matches the
      # acronym RubyLLM's own Rails integration docs tell users to register,
      # so host apps that already have it are unaffected.
      initializer "ruby_llm_resilience.inflections" do
        ActiveSupport::Inflector.inflections(:en) do |inflect|
          inflect.acronym "LLM"
        end
      end
    end
  end
end
