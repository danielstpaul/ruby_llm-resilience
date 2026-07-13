# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require "spec_helper"
require "rails"
require "action_controller/railtie"
require "ruby_llm/resilience/engine"

module Dummy
  class Application < Rails::Application
    # Without an explicit root, Rails infers the GEM root — and then loads
    # the engine's config/routes.rb a second time as the app's own routes.
    config.root = File.expand_path("dummy", __dir__)
    config.load_defaults Rails::VERSION::STRING.to_f
    config.eager_load = false
    config.hosts.clear
    config.secret_key_base = "test-secret"
    config.logger = Logger.new(IO::NULL)
    config.action_controller.allow_forgery_protection = false
    config.action_dispatch.show_exceptions = :none
  end
end

Dummy::Application.initialize!

Rails.application.routes.draw do
  mount RubyLLM::Resilience::Engine => "/resilience"
end

require "rspec/rails"

RSpec.configure do |config|
  config.infer_spec_type_from_file_location!
end
