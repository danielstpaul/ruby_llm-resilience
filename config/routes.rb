# frozen_string_literal: true

RubyLLM::Resilience::Engine.routes.draw do
  root to: "breakers#index"
  # Service names contain colons ("api:anthropic:sonnet") — allow anything
  # but a slash in the segment.
  post "breakers/:id/reset", to: "breakers#reset", as: :reset_breaker,
                             constraints: { id: %r{[^/]+} }
end
