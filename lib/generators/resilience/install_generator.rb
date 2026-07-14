# frozen_string_literal: true

require "rails/generators"

module RubyLLM
  module Resilience
    # rails g resilience:install
    #
    # Writes a fully-commented initializer covering every configuration seam.
    # (Namespaced inside RubyLLM::Resilience — the top-level ::Resilience
    # constant is reserved for the opt-in shorthand alias.)
    class InstallGenerator < Rails::Generators::Base
      namespace "resilience:install"
      source_root File.expand_path("templates", __dir__)

      desc "Creates config/initializers/resilience.rb with a commented example configuration"

      def create_initializer
        template "initializer.rb", "config/initializers/resilience.rb"
      end

      def show_next_steps
        say <<~NEXT, :green

          ruby_llm-resilience installed.

          Next steps:
            1. Review config/initializers/resilience.rb — the defaults work,
               but multi-process apps should configure a shared cache_store.
            2. Optional dashboard: mount it behind YOUR auth in config/routes.rb:
                 mount RubyLLM::Resilience::Engine => "/resilience"
               (it 404s everything until dashboard_auth is configured — see the
               initializer.)
            3. Guard a call:
                 RubyLLM::Resilience.run("api:openai:embeddings") { RubyLLM.embed(text) }
        NEXT
      end
    end
  end
end
