# frozen_string_literal: true

module RubyLLM
  module Resilience
    # Thread-safe in-process store implementing the five-method cache
    # contract the breaker needs:
    #
    #   read(key)
    #   write(key, value, expires_in: nil, unless_exist: false) -> true/false
    #   increment(key, amount, expires_in: nil) -> Integer
    #   delete(key)
    #   delete_multi(keys)
    #
    # This is the DEFAULT store and it is per-process: two Puma workers each
    # see their own breaker state. That's fine for development and small
    # deployments, but multi-process production apps should configure a
    # shared store (e.g. ActiveSupport::Cache::RedisCacheStore) so a breaker
    # tripped in one process is open in all of them.
    #
    # TTL contract: `increment` applies `expires_in` only when it CREATES the
    # counter; subsequent increments do not refresh the TTL. (This matches
    # how the failure-counter window is meant to behave: N failures within
    # the window of the first failure.)
    class MemoryStore
      Entry = Struct.new(:value, :expires_at)

      def initialize
        @data = {}
        @mutex = Mutex.new
      end

      def read(key)
        @mutex.synchronize { live_entry(key)&.value }
      end

      def write(key, value, expires_in: nil, unless_exist: false)
        @mutex.synchronize do
          return false if unless_exist && live_entry(key)

          @data[key] = Entry.new(value, expires_in ? now + expires_in : nil)
          true
        end
      end

      def increment(key, amount = 1, expires_in: nil)
        @mutex.synchronize do
          entry = live_entry(key)
          if entry
            entry.value = entry.value.to_i + amount
          else
            entry = Entry.new(amount, expires_in ? now + expires_in : nil)
            @data[key] = entry
          end
          entry.value
        end
      end

      def delete(key)
        @mutex.synchronize { !@data.delete(key).nil? }
      end

      def delete_multi(keys)
        @mutex.synchronize { keys.count { |key| !@data.delete(key).nil? } }
      end

      def clear
        @mutex.synchronize { @data.clear }
      end

      private

      # Must be called while holding @mutex.
      def live_entry(key)
        entry = @data[key]
        return nil unless entry

        if entry.expires_at && now >= entry.expires_at
          @data.delete(key)
          nil
        else
          entry
        end
      end

      def now
        Time.now.to_f
      end
    end
  end
end
