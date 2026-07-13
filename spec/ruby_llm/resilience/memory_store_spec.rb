# frozen_string_literal: true

RSpec.describe RubyLLM::Resilience::MemoryStore do
  subject(:store) { described_class.new }

  it "reads back written values" do
    store.write("k", "v")
    expect(store.read("k")).to eq("v")
  end

  it "returns nil for missing keys" do
    expect(store.read("missing")).to be_nil
  end

  it "expires values after expires_in" do
    at_time(1_000)
    store.write("k", "v", expires_in: 10)
    expect(store.read("k")).to eq("v")

    at_time(1_011)
    expect(store.read("k")).to be_nil
  end

  describe "unless_exist (SETNX semantics)" do
    it "returns true on first write, false while the key lives" do
      expect(store.write("k", 1, unless_exist: true)).to be(true)
      expect(store.write("k", 2, unless_exist: true)).to be(false)
      expect(store.read("k")).to eq(1)
    end

    it "allows the write again after expiry" do
      at_time(1_000)
      store.write("k", 1, expires_in: 5, unless_exist: true)
      at_time(1_006)
      expect(store.write("k", 2, unless_exist: true)).to be(true)
    end

    it "grants exactly one winner under thread contention" do
      unstubbed_store = described_class.new
      winners = Array.new(20) do
        Thread.new { unstubbed_store.write("lock", true, expires_in: 60, unless_exist: true) }
      end.map(&:value)
      expect(winners.count(true)).to eq(1)
    end
  end

  describe "increment" do
    it "creates at the given amount and counts up" do
      expect(store.increment("c", 1)).to eq(1)
      expect(store.increment("c", 1)).to eq(2)
      expect(store.increment("c", 3)).to eq(5)
    end

    it "applies expires_in only on create (window semantics)" do
      at_time(1_000)
      store.increment("c", 1, expires_in: 10)
      at_time(1_005)
      store.increment("c", 1, expires_in: 10) # must NOT refresh the TTL
      at_time(1_011)
      expect(store.read("c")).to be_nil
    end

    it "is atomic under thread contention" do
      unstubbed_store = described_class.new
      Array.new(50) { Thread.new { unstubbed_store.increment("c", 1) } }.each(&:join)
      expect(unstubbed_store.read("c")).to eq(50)
    end
  end

  describe "delete/delete_multi" do
    it "deletes keys individually and in bulk" do
      store.write("a", 1)
      store.write("b", 2)
      store.write("c", 3)

      expect(store.delete("a")).to be(true)
      expect(store.delete("a")).to be(false)
      expect(store.delete_multi(%w[b c missing])).to eq(2)
      expect(store.read("b")).to be_nil
    end
  end
end
