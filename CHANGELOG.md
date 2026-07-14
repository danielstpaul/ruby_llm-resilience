# Changelog

## [Unreleased]

## [0.5.0] - 2026-07-14

- Dashboard table: click-to-sort columns (text/numeric aware) and a
  service/state filter box — dependency-free vanilla JS, with sort/filter
  state persisted in localStorage so it survives the 10s auto-refresh.

## [0.4.0] - 2026-07-14

Dashboard fleshed out:

- **Fallback routes column** — model chains from `fallback_models`, grouped
  by breaker service via the namer (`Resilience.fallback_routes` is public
  API for custom dashboards)
- Failures shown against the effective per-service threshold (`1 / 5`);
  cooldown column with per-service override markers
- **Configuration panel** — store, defaults, fallback-map size, and whether
  each telemetry hook (`on_error`/`on_status`/`on_fallback`) is configured
  or still a no-op
- `Breaker.dashboard_status` rows now include `failure_threshold`,
  `cooldown_seconds`, `overridden`
- README: telemetry recipes (alert on the handled error, graph the gauge,
  trend the counter)

## [0.3.3] - 2026-07-14

- New `config.dashboard_services`: default service list for the engine
  dashboard (nil = per-process registry). Apps with a known static fleet
  get a complete dashboard from the first request. (Third
  production-adoption catch.)

## [0.3.2] - 2026-07-14

- Fix dashboard template lookup in apps using the ruby_llm gem: its Railtie
  registers `acronym "RubyLLM"`, which changed the engine controller's
  derived controller_path and broke view resolution. controller_path is now
  pinned. (Second production-adoption catch.)

## [0.3.1] - 2026-07-14

- Breaker registry now uses shared constants instead of class-ivars, making
  Breaker safely subclassable (apps can add service lists/aliases in a
  subclass). Found while dogfooding — the shim subclass crashed on v0.3.0.

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
