# frozen_string_literal: true

module RubyLLM
  module Resilience
    # Raised when a call is blocked by an open circuit, or when a fallback
    # chain is exhausted and at least one step was skipped because its
    # breaker was open.
    #
    # Distinguishing this class from the underlying provider error lets
    # callers fail CLOSED ("the provider is down, show the friendly banner")
    # instead of treating it like a one-off request failure.
    class BreakerTripped < StandardError; end

    # Resolves error class names lazily so the gem has zero hard runtime
    # dependencies: if ruby_llm or faraday isn't loaded, their error classes
    # simply don't participate in the default lists.
    module ErrorResolution
      module_function

      def resolve(names)
        names.filter_map do |name|
          Object.const_get(name)
        rescue NameError
          nil
        end
      end
    end
  end
end
