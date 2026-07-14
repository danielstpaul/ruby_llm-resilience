# frozen_string_literal: true

require "rails/generators"
require "generators/resilience/install_generator"
require "tmpdir"

RSpec.describe RubyLLM::Resilience::InstallGenerator do
  it "writes the commented initializer into the destination root" do
    dest = File.join(Dir.mktmpdir, "app")
    described_class.start([], destination_root: dest)

    initializer = File.join(dest, "config/initializers/resilience.rb")
    expect(File).to exist(initializer)
    content = File.read(initializer)
    expect(content).to include("RubyLLM::Resilience.configure")
    expect(content).to include("fallback_models")
    expect(content).to include("dashboard_auth")
  end
end
