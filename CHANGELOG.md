# Changelog

## [Unreleased]

## [0.3.0] - 2026-07-13

Fallback routing is now fully user-configurable:

- **Multi-hop maps**: `fallback_models` values accept an array of hops
  (`"gemini-3.5-flash" => ["claude-sonnet-4-6", "claude-opus-4-7"]`) as well
  as a single model. One deliberate hop remains the documented default.
- **Per-call override**: `run_with_model_fallback(model, fallback: ...)` —
  `:map` (default), `false`/`nil` (breaker only, no routing), a model
  string, or an array chain. Expresses variant→control patterns in one call.
- **`on_fallback` callback**: fires on every chain advance with
  `from:`, `to:` (service + model) and the triggering `error:` — including
  skipped-open steps. Fallbacks are now observable, not silent.

## [0.2.0] - 2026-07-13

- **Mountable dashboard engine** (`require "ruby_llm/resilience/engine"`,
  `mount RubyLLM::Resilience::Engine => "/resilience"`): live state pills,
  failure counts, probe countdowns, metadata, reset buttons, auto-refresh.
  Deny-by-default auth via `config.dashboard_auth` — every request 404s
  until explicitly allowed. Core remains zero-dependency; the engine loads
  only under Rails.
- **Per-service overrides**: `config.services = { "api:x" =>
  { failure_threshold:, cooldown_seconds:, failures_window_seconds: } }`.
- **Service metadata**: `config.service_metadata` — dashboard descriptions
  as config, not hardcoded controllers; included in `dashboard_status`.

## [0.1.0] - 2026-07-13

Initial release. Design proven across 450k+ production LLM calls.

- `RubyLLM::Resilience.run(service)` — circuit-broken single calls
- `run_with_model_fallback(model)` — one tier-hop via `fallback_models`
- `run_with_fallback(*steps)` — skip-open chains, `BreakerTripped` on
  exhaustion when any breaker was open
- `Breaker` — CLOSED→OPEN→HALF_OPEN state machine, atomic single-probe
  SETNX lock, atomic trip transition, fail-open on store outage
- `allow_request?` (mutating gate) split from pure `open?`/`state` reads
- Five injection seams: `cache_store`, `on_error`, `on_status`,
  `provider_resolver`, `service_namer`
- Zero runtime dependencies; lazy resolution of RubyLLM/Faraday error
  classes; built-in thread-safe `MemoryStore`
