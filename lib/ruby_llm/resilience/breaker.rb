# frozen_string_literal: true

require "set"

module RubyLLM
  module Resilience
    # Cache-backed circuit breaker for one service.
    #
    # State machine: CLOSED → OPEN → HALF_OPEN → CLOSED
    #
    # Three keys per service in the configured store:
    #   {service}:failures    — consecutive-failure counter (windowed TTL)
    #   {service}:open_until  — epoch float; presence means open/half-open
    #   {service}:probe_lock  — SETNX lock so exactly one caller probes
    #
    # API purity contract (learned the hard way in production):
    #   allow_request?  — the MUTATING gate. In half-open it CONSUMES the
    #                     probe slot. Call it exactly once per real request.
    #   open?/closed?/state/failure_count/seconds_until_probe — PURE reads,
    #                     safe for dashboards, logging, and health checks.
    #
    # Fail-open everywhere: if the store is unreachable, the breaker reports
    # closed and records nothing. The breaker must never take the app down
    # when Redis blips — the API call itself is the thing being protected.
    class Breaker
      attr_reader :service

      # Constants (not class-ivars) so subclasses share one registry —
      # apps may subclass Breaker to add their own service lists/aliases.
      REGISTRY = Set.new
      REGISTRY_MUTEX = Mutex.new
      private_constant :REGISTRY, :REGISTRY_MUTEX

      class << self
        def register(service)
          REGISTRY_MUTEX.synchronize { REGISTRY.add(service) }
        end

        # Per-process registry of breakers seen since boot. A cache-store
        # contract can't enumerate keys, so this (plus an explicit list) is
        # how dashboards discover services.
        def known_services
          REGISTRY_MUTEX.synchronize { REGISTRY.to_a.sort }
        end

        def dashboard_status(services: nil)
          (services || known_services).map do |service|
            breaker = new(service)
            {
              service: service,
              state: breaker.state,
              failure_count: breaker.failure_count,
              seconds_until_probe: breaker.seconds_until_probe,
              metadata: Resilience.config.metadata_for(service)
            }
          end
        end

        def reset_registry!
          REGISTRY_MUTEX.synchronize { REGISTRY.clear }
        end
      end

      def initialize(service)
        @service = service.to_s
        self.class.register(@service)
      end

      # The mutating gate: true if this request may proceed. In half-open,
      # acquires the atomic probe lock — exactly one caller across all
      # processes gets true; everyone else is treated as open.
      def allow_request?
        case current_state
        when :closed    then true
        when :open      then false
        when :half_open then acquire_probe_lock
        end
      end

      # Pure: true only when fully open. Half-open reports false (a request
      # MAY be allowed). Never consumes the probe slot — dashboard-safe.
      def open?
        current_state == :open
      end

      def closed?
        !open?
      end

      def state
        current_state
      end

      def failure_count
        safely(0) { cache.read(failures_key) }.to_i
      end

      # Seconds until the breaker will allow a probe (nil if closed).
      def seconds_until_probe
        open_until = safely { cache.read(open_until_key) }
        return nil unless open_until

        remaining = open_until.to_f - Time.now.to_f
        remaining.positive? ? remaining.ceil : 0
      end

      # Reset failure count and close the breaker. Fires on_status with
      # :closed on EVERY success — gauge semantics (idempotent), matching
      # the production original. It is not a once-per-transition event.
      def record_success
        safely { cache.delete_multi([ failures_key, open_until_key, probe_lock_key ]) }
        notify_status(:closed)
      end

      # Increment the failure counter; trip at threshold. In half-open, a
      # single probe failure re-opens immediately (force: the open_until key
      # still exists in half-open and must be overwritten, not skipped).
      def record_failure
        if current_state == :half_open
          trip!(force: true)
        else
          count = safely do
            cache.increment(failures_key, 1, expires_in: settings.failures_window_seconds)
          end
          trip! if count && count >= settings.failure_threshold
        end
      end

      # Force-close (admin/console use).
      def reset!
        record_success
      end

      private

      def current_state
        open_until = safely(:store_error) { cache.read(open_until_key) }
        return :closed if open_until == :store_error # fail open
        return :closed if open_until.nil?

        Time.now.to_f < open_until.to_f ? :open : :half_open
      end

      # Trips are ATOMIC: from closed, the open_until write uses SETNX so
      # racing threads that all crossed the threshold produce exactly one
      # transition (and one set of callbacks). From half-open (force:), the
      # key already exists and must be overwritten — no race is possible
      # there because the probe lock admitted exactly one caller.
      def trip!(force: false)
        cooldown = settings.cooldown_seconds
        open_until = Time.now.to_f + cooldown

        transitioned = safely(false) do
          if force
            cache.write(open_until_key, open_until, expires_in: cooldown * 2)
            true
          else
            cache.write(open_until_key, open_until, expires_in: cooldown * 2, unless_exist: true)
          end
        end
        return unless transitioned

        safely { cache.delete(failures_key) }
        notify_error(
          BreakerTripped.new("Circuit breaker tripped for #{@service}"),
          { service: @service, cooldown_seconds: cooldown }
        )
        notify_status(:open)
      end

      # Atomic SETNX: exactly one fiber/thread/process becomes the probe.
      # Lock TTL = cooldown, so a probe that dies without reporting frees
      # the slot after one cooldown period.
      def acquire_probe_lock
        safely(false) do
          cache.write(probe_lock_key, true, expires_in: settings.cooldown_seconds, unless_exist: true)
        end
      end

      # Store operations never raise into the caller: report via on_error
      # and return the fallback. The call being protected matters more than
      # the bookkeeping around it.
      def safely(fallback = nil)
        yield
      rescue StandardError => e
        notify_error(e, { service: @service, phase: "circuit_breaker_store" })
        fallback
      end

      # User callbacks must not be able to break the call path either.
      def notify_status(state)
        config.on_status.call(@service, state)
      rescue StandardError
        nil
      end

      def notify_error(error, context)
        config.on_error.call(error, context)
      rescue StandardError
        nil
      end

      def failures_key   = "#{@service}:failures"
      def open_until_key = "#{@service}:open_until"
      def probe_lock_key = "#{@service}:probe_lock"

      def cache    = config.cache_store
      def config   = Resilience.config
      def settings = config.settings_for(@service)
    end
  end
end
