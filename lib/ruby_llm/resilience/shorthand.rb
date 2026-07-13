# frozen_string_literal: true

# Opt-in top-level alias:
#
#   require "ruby_llm/resilience/shorthand"
#   Resilience.run("api:openai:embeddings") { ... }
#
# Kept out of the default require deliberately — claiming a top-level
# ::Resilience constant is namespace pollution unless you ask for it.
Resilience = RubyLLM::Resilience unless defined?(::Resilience)
