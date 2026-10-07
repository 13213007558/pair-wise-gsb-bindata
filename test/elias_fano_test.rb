#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))

describe BinData::EliasFano, "when assigning" do
  it "rejects nil" do
    _ { BinData::EliasFano.new.assign(nil) }.must_raise ArgumentError
  end

  it "rejects negative values" do
    _ { BinData::EliasFano.new.assign([1, -2, 3]) }.must_raise ArgumentError
  end

  it "rejects decreasing sequences" do
    _ { BinData::EliasFano.new.assign([1, 5, 3]) }.must_raise ArgumentError
  end

  it "accepts duplicate values" do
    obj = BinData::EliasFano.new(initial_value: [3, 3, 3])
    _(obj).must_equal [3, 3, 3]
  end
end

describe BinData::EliasFano, "with an empty sequence" do
  let(:obj) { BinData::EliasFano.new(initial_value: []) }

  it "has zero length" do
    _(obj.length).must_equal 0
    _(obj.empty?).must_equal true
  end

  it "round trips" do
    copy = BinData::EliasFano.read(obj.to_binary_s)
    _(copy).must_equal []
    _(copy.length).must_equal 0
  end

  it "answers queries trivially" do
    _(obj.lower_bound(0)).must_equal 0
    _(obj.lower_bound(100)).must_equal 0
    _(obj.rank(100)).must_equal 0
    _(obj.rank_leq(100)).must_equal 0
  end

  it "raises IndexError on select" do
    _ { obj.select(0) }.must_raise IndexError
  end
end

describe BinData::EliasFano, "with all values equal" do
  let(:vals) { [7] * 10 }
  let(:obj) { BinData::EliasFano.read(BinData::EliasFano.new(initial_value: vals).to_binary_s) }

  it "round trips" do
    _(obj).must_equal vals
  end

  it "selects" do
    10.times { |i| _(obj.select(i)).must_equal 7 }
  end

  it "bounds" do
    _(obj.lower_bound(7)).must_equal 0
    _(obj.lower_bound(8)).must_equal 10
    _(obj.rank(7)).must_equal 0
    _(obj.rank_leq(7)).must_equal 10
  end
end

describe BinData::EliasFano, "with a huge sparse universe" do
  let(:vals) { [0, 5, 2**64, 2**70 + 123_456_789] }
  let(:obj) { BinData::EliasFano.read(BinData::EliasFano.new(initial_value: vals).to_binary_s) }

  it "round trips without expanding the universe" do
    _(obj).must_equal vals
    _(obj.num_bytes).must_be :<, 100
    _(obj.universe).must_equal vals[-1] + 1
  end

  it "answers queries" do
    _(obj.select(2)).must_equal 2**64
    _(obj.lower_bound(2**64)).must_equal 2
    _(obj.lower_bound(2**64 + 1)).must_equal 3
    _(obj.rank(2**70)).must_equal 3
    _(obj.rank_leq(vals[-1])).must_equal 4
    _(obj.lower_bound(vals[-1] + 1)).must_equal 4
  end
end

describe BinData::EliasFano, "reading and writing" do
  it "round trips through the stream" do
    vals = [1, 3, 3, 7, 100, 101, 101, 1_000_000]
    obj = BinData::EliasFano.new(initial_value: vals)
    io = StringIO.new
    obj.write(io)

    copy = BinData::EliasFano.read(StringIO.new(io.value))
    _(copy).must_equal vals
    _(copy.num_bytes).must_equal io.value.bytesize
  end

  it "is usable as a record field" do
    klass = Class.new(BinData::Record) do
      uint8 :tag
      elias_fano :seq
    end
    obj = klass.new(tag: 9, seq: [2, 4, 4, 9])
    copy = klass.read(obj.to_binary_s)
    _(copy.tag).must_equal 9
    _(copy.seq).must_equal [2, 4, 4, 9]
    _(copy.seq.select(3)).must_equal 9
    _(copy.seq.rank(4)).must_equal 1
  end

  it "supports queries on a fresh read without touching the value" do
    vals = [10, 20, 30]
    obj = BinData::EliasFano.read(BinData::EliasFano.new(initial_value: vals).to_binary_s)
    _(obj.select(1)).must_equal 20
    _(obj.lower_bound(25)).must_equal 2
    _(obj.clear?).must_equal false
  end
end

describe BinData::EliasFano, "select" do
  let(:vals) { [0, 1, 4, 4, 9, 25, 36] }
  let(:obj) { BinData::EliasFano.new(initial_value: vals) }

  it "returns the value at the index" do
    vals.each_with_index { |v, i| _(obj.select(i)).must_equal v }
  end

  it "supports negative indices" do
    _(obj.select(-1)).must_equal 36
    _(obj.select(-7)).must_equal 0
  end

  it "raises IndexError when out of bounds" do
    _ { obj.select(7) }.must_raise IndexError
    _ { obj.select(-8) }.must_raise IndexError
  end
end

describe BinData::EliasFano, "rank semantics" do
  let(:vals) { [2, 2, 5, 5, 5, 9] }
  let(:obj) { BinData::EliasFano.new(initial_value: vals) }

  it "rank counts elements strictly less than x" do
    _(obj.rank(0)).must_equal 0
    _(obj.rank(2)).must_equal 0
    _(obj.rank(5)).must_equal 2
    _(obj.rank(9)).must_equal 5
    _(obj.rank(10)).must_equal 6
  end

  it "rank_leq counts elements less than or equal to x" do
    _(obj.rank_leq(1)).must_equal 0
    _(obj.rank_leq(2)).must_equal 2
    _(obj.rank_leq(5)).must_equal 5
    _(obj.rank_leq(9)).must_equal 6
  end

  it "lower_bound agrees with rank" do
    (0..11).each { |x| _(obj.lower_bound(x)).must_equal obj.rank(x) }
  end
end

describe BinData::EliasFano, "randomised alignment with plain arrays" do
  def check_sequence(vals, queries)
    obj = BinData::EliasFano.read(BinData::EliasFano.new(initial_value: vals).to_binary_s)

    _(obj).must_equal vals
    _(obj.length).must_equal vals.length

    vals.each_with_index do |v, i|
      _(obj.select(i)).must_equal v
    end

    queries.each do |x|
      expected_lb = vals.bsearch_index { |v| v >= x } || vals.length
      _(obj.lower_bound(x)).must_equal expected_lb
      _(obj.rank(x)).must_equal vals.count { |v| v < x }
      _(obj.rank_leq(x)).must_equal vals.count { |v| v <= x }
    end
  end

  it "matches binary search on random sequences" do
    rng = Random.new(42)
    cases = [
      # [count, universe] dense, sparse, huge sparse, all equal, empty
      [0, 10],
      [1, 1],
      [50, 50],
      [50, 60],
      [300, 1000],
      [300, 2**40],
      [1500, 2000],
      [1500, 2**70],
      [3000, 10_000],
    ]

    cases.each do |n, universe|
      vals = Array.new(n) { rng.rand(universe) }.sort
      queries = 200.times.map { rng.rand(universe + 2) } + [0, universe - 1, universe, universe + 1]
      check_sequence(vals, queries)
    end

    # all equal values, several sizes
    [1, 7, 513, 1200].each do |n|
      vals = [rng.rand(1000)] * n
      check_sequence(vals, [0, vals[0] - 1, vals[0], vals[0] + 1, 1001])
    end

    # heavy duplicates
    vals = Array.new(800) { rng.rand(5) }.sort
    check_sequence(vals, (0..7).to_a)
  end

  it "exercises the select index across sample boundaries" do
    rng = Random.new(7)
    n = BinData::EliasFano::SELECT_SAMPLE_RATE * 3 + 17
    vals = Array.new(n) { rng.rand(100) }.sort
    obj = BinData::EliasFano.read(BinData::EliasFano.new(initial_value: vals).to_binary_s)
    vals.each_with_index { |v, i| _(obj.select(i)).must_equal v }
    (0..101).each do |x|
      expected_lb = vals.bsearch_index { |v| v >= x } || vals.length
      _(obj.lower_bound(x)).must_equal expected_lb
    end
  end
end
