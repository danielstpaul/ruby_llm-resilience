# frozen_string_literal: true

require_relative "lib/ruby_llm/resilience/version"

Gem::Specification.new do |spec|
  spec.name        = "ruby_llm-resilience"
  spec.version     = RubyLLM::Resilience::VERSION
  spec.authors     = [ "Daniel St Paul" ]
  spec.email       = [ "danielstpaul@hotmail.com" ]

  spec.summary     = "Circuit breakers and fallback chains for LLM apps."
  spec.description = "RubyLLM gives you every provider. This gives you what happens " \
                     "when one of them goes down: tier-aware circuit breakers, " \
                     "cross-provider fallback chains, and fail-open store semantics — " \
                     "battle-tested behind 450k+ production LLM calls."
  spec.homepage    = "https://github.com/danielstpaul/ruby_llm-resilience"
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"]          = spec.homepage
  spec.metadata["source_code_uri"]       = spec.homepage
  spec.metadata["changelog_uri"]         = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files         = Dir["lib/**/*", "app/**/*", "config/routes.rb",
                           "LICENSE.txt", "README.md", "CHANGELOG.md"]
  spec.require_paths = [ "lib" ]

  # Zero runtime dependencies — ruby_llm and faraday error classes are
  # resolved lazily; any 5-method cache store satisfies the store contract.
  # The dashboard engine (require "ruby_llm/resilience/engine") is opt-in
  # and only loads when Rails is present.

  spec.add_development_dependency "rails", ">= 7.1"
  spec.add_development_dependency "rake",  "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rspec-rails", "~> 7.0"
end
