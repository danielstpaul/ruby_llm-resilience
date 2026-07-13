# frozen_string_literal: true

require "ruby_llm/resilience"

# Stub error hierarchies matching ruby_llm / faraday, so the lazy
# constant-resolution paths are exercised for real without either gem
# installed. (RubyLLM::Resilience lives inside the same RubyLLM namespace —
# reopening it here is exactly what happens in a host app.)
module RubyLLM
  class Error < StandardError; end
  class RateLimitError < Error; end
  class ServerError < Error; end
  class ServiceUnavailableError < Error; end
  class OverloadedError < Error; end
  class BadRequestError < Error; end
  # Deliberately OUTSIDE the RubyLLM::Error hierarchy, matching the real gem.
  class ModelNotFoundError < StandardError; end
end

module Faraday
  class Error < StandardError; end
  class TimeoutError < Error; end
  class ConnectionFailed < Error; end
  class ServerError < Error; end
end

# A store that raises on everything — for fail-open tests.
class ExplodingStore
  %i[read write increment delete delete_multi].each do |m|
    define_method(m) { |*_args, **_kwargs| raise "store is down" }
  end
end

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!

  config.before do
    RubyLLM::Resilience.reset_configuration!
  end
end

# Advance a fake clock without sleeping. Stubs Time.now for both the breaker
# and the MemoryStore, so TTLs and cooldowns move together.
def at_time(epoch_seconds)
  allow(Time).to receive(:now).and_return(Time.at(epoch_seconds))
end
