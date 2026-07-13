# ruby_llm-resilience

**RubyLLM gives you every provider. This gives you what happens when one of
them goes down.**

Circuit breakers and fallback chains for LLM apps — battle-tested behind
**450,000+ production LLM calls**.

```ruby
# Guard any call
RubyLLM::Resilience.run("api:openai:embeddings") { RubyLLM.embed(text) }

# Fallback routing when a model's tier is struggling — fully configurable:
RubyLLM::Resilience.run_with_model_fallback("claude-haiku-4-5") do |model|
  RubyLLM.chat(model: model).ask(prompt)   # hops per your fallback_models map
end
# fallback: false          → no routing, breaker only
# fallback: "gpt-5.5"      → explicit per-call hop, ignoring the map
# fallback: ["a", "b"]     → explicit multi-hop chain

# Custom cross-provider chain
RubyLLM::Resilience.run_with_fallback(
  { service: "api:openai:moderation", call: -> { RubyLLM.moderate(content) } },
  { service: "api:anthropic:haiku",   call: -> { my_anthropic_moderator.call(content) } }
)
```

Zero runtime dependencies. Works with any cache store that speaks five
methods. Fails open when your store blips — the breaker never becomes the
outage.

## Install

```ruby
gem "ruby_llm-resilience"
```

```ruby
# config/initializers/resilience.rb
RubyLLM::Resilience.configure do |c|
  # REQUIRED for multi-process apps — the default MemoryStore is per-process.
  c.cache_store = ActiveSupport::Cache::RedisCacheStore.new(url: ENV["REDIS_URL"])

  c.fallback_models = {
    "claude-haiku-4-5"  => "claude-sonnet-4-6",
    "claude-sonnet-4-6" => "claude-opus-4-7",
    "claude-opus-4-7"   => "claude-sonnet-4-6",
    "gemini-3.5-flash"  => "claude-sonnet-4-6"   # cross-provider safety net
  }

  c.on_error  = ->(error, ctx) { Rails.error.report(error, handled: true, context: ctx) }
  c.on_status = ->(service, state) {
    Appsignal.set_gauge("circuit_breaker.state", state == :open ? 1 : 0, service: service)
  }
end
```

## How it works

State machine per service: `CLOSED → OPEN → HALF_OPEN → CLOSED`.

- **Trip**: `failure_threshold` consecutive server-side failures (default 5)
  open the breaker for `cooldown_seconds` (default 120).
- **Probe**: after cooldown, an atomic SETNX lock lets **exactly one** caller
  across all your processes probe the provider. Success closes; failure
  re-opens immediately.
- **Chains**: steps whose breaker is open are *skipped*, first success wins,
  and if the chain exhausts with any step skipped-open you get
  `BreakerTripped` — so you can distinguish "the providers are down" (fail
  closed, show the friendly banner) from "this request failed."

## Design notes — what 450k production calls taught us

These are the decisions that differ from a textbook breaker, learned in
production:

- **4xx never trips.** Client errors are your bug, not their outage. Only
  rate limits, 5xx, overloads and transport timeouts count toward the
  threshold — and the failure count *survives* interleaved 4xx errors.
- **Tier-hop fallbacks, one hop only.** Provider capacity incidents are
  tier-correlated: when Sonnet is overloaded, every Sonnet version is.
  Same-tier version hops are theatre. Hopping tier (haiku→sonnet) puts you
  on a separate breaker and a separate capacity pool. And chains don't
  chase transitively — one deliberate escape per model.
- **Tier-level breaker names.** `api:anthropic:sonnet`, not
  `api:anthropic:claude-sonnet-4-6` — a version rollover shouldn't fragment
  your health state across two breakers.
- **`BreakerTripped` on exhaustion, not the last error.** Callers must be
  able to fail *closed* on persistent provider failure while failing *open*
  on one-off errors.
- **Fail-open on store outage.** If Redis is down, every breaker reports
  closed and records nothing. The breaker must never take the app down.
- **`allow_request?` vs `open?`.** The gate that consumes the half-open
  probe slot is separate from the pure reads — so your dashboard can poll
  `state`/`open?` forever without stealing probes.
- **`ModelNotFoundError` advances chains.** New-model rollout windows leave
  registries briefly stale; degrade to the fallback model instead of
  surfacing "unknown model" to users.
- **Deterministic failover, not smart routing.** OpenRouter-style routing
  optimizes continuously on fleet-wide signal a single app doesn't have —
  and prompts are model-specific, so silently serving a Sonnet-tuned prompt
  on GPT is an unlogged quality regression, not an optimization. Here the
  map is explicit, hops are emergencies, and every hop fires `on_fallback`
  so your telemetry sees exactly what routed where and why. (RubyLLM speaks
  OpenRouter as a provider, so the two compose if you want both.)

## The five seams

Everything app-specific is injectable:

| Seam | Default | Wire it to |
|---|---|---|
| `cache_store` | in-process `MemoryStore` | Redis (any object with `read`/`write(expires_in:, unless_exist:)`/`increment(expires_in:)`/`delete`/`delete_multi`) |
| `on_error` | no-op | `Rails.error.report`, Sentry, Honeybadger |
| `on_status` | no-op | AppSignal/Datadog gauge (fires on every success and every trip — gauge semantics) |
| `provider_resolver` | RubyLLM's model registry, rescued | your own model→provider logic |
| `service_namer` | `TierNamer` (per-provider tiers) | `->(model) { "api:#{model}" }` for per-model breakers |

Not LLM-specific, by the way: we run the same breakers around OCR, Slack
webhooks, CAPTCHA verification and email-validation APIs. Configure custom
`trippable_errors`/`fallback_errors` and guard anything.

## Per-service configuration

One cooldown doesn't fit all: a cheap fast-recovery moderation endpoint and
an expensive batch endpoint shouldn't share settings.

```ruby
RubyLLM::Resilience.configure do |c|
  c.failure_threshold = 5      # global defaults...
  c.cooldown_seconds  = 120

  c.services = {               # ...with per-service overrides
    "api:openai:moderation" => { failure_threshold: 2, cooldown_seconds: 30 },
    "api:anthropic:batches" => { cooldown_seconds: 600 }
  }

  c.service_metadata = {       # app knowledge for the dashboard — config, not code
    "api:anthropic:sonnet" => { description: "Coaching + generation", consumers: "Chat, Practice" }
  }
end
```

## The dashboard

An optional mountable engine ships with the gem (the core stays
zero-dependency — the engine only loads when you ask for it under Rails):

```ruby
# config/application.rb
require "ruby_llm/resilience/engine"

# config/routes.rb
mount RubyLLM::Resilience::Engine => "/resilience"

# config/initializers/resilience.rb — REQUIRED: the dashboard denies by
# default; every request 404s until you explicitly allow it:
RubyLLM::Resilience.configure do |c|
  c.dashboard_auth = ->(controller) {
    controller.head :not_found unless controller.current_user&.admin?
  }
end
```

One page: live state pills per service, failure counts, probe countdowns,
your `service_metadata` descriptions, and reset buttons. Auto-refreshes —
safely, because **all dashboard reads are pure**: polling never consumes
half-open probe slots (that's why `allow_request?` and `open?` are separate
methods).

Prefer your own admin panel? The data API is public:

```ruby
RubyLLM::Resilience::Breaker.dashboard_status
# => [{ service: "api:anthropic:sonnet", state: :closed, failure_count: 0,
#       seconds_until_probe: nil, metadata: { description: "..." } }, ...]

RubyLLM::Resilience::Breaker.new("api:anthropic:sonnet").reset!  # console escape hatch
```

## Vs. circuitbox / stoplight / semian / breaker_machines / ruby_llm-agents

- **[semian](https://github.com/Shopify/semian)** intercepts at the driver
  level — superb for MySQL/Redis, structurally wrong for LLM SDK calls.
- **circuitbox / stoplight** are excellent *generic single breakers*. What
  they don't do is the part this gem exists for: skip-open **fallback
  chains** with fail-closed exhaustion semantics, model→tier naming, and an
  LLM-tuned error taxonomy.
- **[breaker_machines](https://github.com/seuros/breaker_machines)** is a
  modern generic breaker with per-class fallbacks and a rich DSL — the
  closest generic cousin. It still isn't LLM-aware: no model→tier naming,
  no multi-step skip-open chains, no trippable-vs-fallback error split.
- **ruby_llm-agents** bundles a breaker inside a full agent framework; this
  is the extractable primitive with zero dependencies.

Why not build the chain layer on stoplight? Zero hard deps, a 5-method
store contract, and a ~200-line breaker meant vendoring beat depending.

## License

MIT.
