#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))

describe BinData::EliasFanoSequence, "when assigning" do
  it "rejects non array values" do
    _ { BinData::EliasFanoSequence.new(initial_value: 5) }.must_raise ArgumentError
    _ { BinData::EliasFanoSequence.new(initial_value: nil) }.must_raise ArgumentError
  end

  it "rejects negative values" do
    _ { BinData::EliasFanoSequence.new(initial_value: [1, -1]) }.must_raise ArgumentError
  end

  it "rejects non integer values" do
    _ { BinData::EliasFanoSequence.new(initial_value: [1, 2.5]) }.must_raise ArgumentError
  end

  it "rejects decreasing values" do
    _ { BinData::EliasFanoSequence.new(initial_value: [3, 1]) }.must_raise ArgumentError
  end

  it "rejects values above the 63 bit limit" do
    too_big = BinData::EliasFanoSequence::MAX_VALUE + 1
    _ { BinData::EliasFanoSequence.new(initial_value: [too_big]) }.must_raise ArgumentError
  end

  it "accepts duplicate values" do
    obj = BinData::EliasFanoSequence.new(initial_value: [2, 2, 2])
    _(obj.to_a).must_equal [2, 2, 2]
  end
end

describe BinData::EliasFanoSequence, "round trip" do
  def round_trip(values)
    obj = BinData::EliasFanoSequence.new(initial_value: values)
    BinData::EliasFanoSequence.read(obj.to_binary_s).to_a
  end

  it "handles an empty sequence" do
    _(round_trip([])).must_equal []
  end

  it "handles a single element" do
    _(round_trip([42])).must_equal [42]
  end

  it "handles all equal values" do
    _(round_trip([7, 7, 7, 7, 7])).must_equal [7, 7, 7, 7, 7]
  end

  it "handles a very large sparse upper bound" do
    values = [0, 5, 2**62]
    obj = BinData::EliasFanoSequence.new(initial_value: values)
    _(obj.num_bytes).must_be :<, 64
    _(round_trip(values)).must_equal values
  end

  it "handles duplicates and gaps" do
    values = [0, 0, 1, 1, 1, 255, 256, 256, 1_000_000]
    _(round_trip(values)).must_equal values
  end

  it "works as a record field" do
    rec_class = Class.new(BinData::Record) do
      uint8 :tag
      elias_fano_sequence :seq
    end
    rec = rec_class.new
    rec.tag = 1
    rec.seq = [10, 20, 30]
    read_back = rec_class.read(rec.to_binary_s)
    _(read_back.seq.to_a).must_equal [10, 20, 30]
    _(read_back.seq.rank(20)).must_equal 1
  end
end

describe BinData::EliasFanoSequence, "queries on edge cases" do
  it "answers queries on an empty sequence" do
    obj = BinData::EliasFanoSequence.new
    _(obj.select(0)).must_be_nil
    _(obj.rank(0)).must_equal 0
    _(obj.rank(100)).must_equal 0
    _(obj.rank_le(100)).must_equal 0
    _(obj.lower_bound(0)).must_equal 0
  end

  it "answers queries on an all equal sequence" do
    obj = BinData::EliasFanoSequence.new(initial_value: [5, 5, 5, 5])
    _(obj.select(0)).must_equal 5
    _(obj.select(3)).must_equal 5
    _(obj.select(4)).must_be_nil
    _(obj.rank(5)).must_equal 0
    _(obj.rank_le(5)).must_equal 4
    _(obj.rank(6)).must_equal 4
    _(obj.lower_bound(5)).must_equal 0
    _(obj.lower_bound(6)).must_equal 4
  end

  it "answers queries on a sparse sequence with a huge upper bound" do
    obj = BinData::EliasFanoSequence.new(initial_value: [3, 2**62])
    _(obj.select(1)).must_equal 2**62
    _(obj.rank(3)).must_equal 0
    _(obj.rank(4)).must_equal 1
    _(obj.rank(2**62)).must_equal 1
    _(obj.rank_le(2**62)).must_equal 2
    _(obj.lower_bound(2**62)).must_equal 1
    _(obj.lower_bound(2**62 + 1)).must_equal 2
  end

  it "answers queries below and above the value range" do
    obj = BinData::EliasFanoSequence.new(initial_value: [10, 20, 30])
    _(obj.rank(0)).must_equal 0
    _(obj.rank(10)).must_equal 0
    _(obj.rank_le(10)).must_equal 1
    _(obj.rank(31)).must_equal 3
    _(obj.lower_bound(0)).must_equal 0
    _(obj.lower_bound(31)).must_equal 3
    _(obj.select(-1)).must_be_nil
    _(obj.select(3)).must_be_nil
  end
end

describe BinData::EliasFanoSequence, "auxiliary select index" do
  it "samples every SELECT_SAMPLING-th element" do
    n = 3000
    values = Array.new(n) { |i| i * 2 }
    obj = BinData::EliasFanoSequence.new(initial_value: values)
    index = obj.send(:ef_index)
    expected = (n + BinData::EliasFanoSequence::SELECT_SAMPLING - 1) /
               BinData::EliasFanoSequence::SELECT_SAMPLING
    _(index.select_sample_count).must_equal expected
  end

  it "is reused across queries and rebuilt after assign" do
    obj = BinData::EliasFanoSequence.new(initial_value: [1, 2, 3])
    index = obj.send(:ef_index)
    obj.rank(2)
    _(obj.send(:ef_index)).must_be_same_as index
    obj.assign([5, 6])
    _(obj.send(:ef_index)).wont_be_same_as index
    _(obj.select(1)).must_equal 6
  end
end

describe BinData::EliasFanoSequence, "random queries aligned with array bisect" do
  rng = Random.new(12_345)

  sequences = {
    "empty"          => [],
    "single"         => [rng.rand(1000)],
    "dense dups"     => Array.new(500) { rng.rand(10) }.sort,
    "all equal"      => Array.new(128) { 42 },
    "sparse huge"    => Array.new(200) { rng.rand(2**62) }.sort,
    "mixed"          => (Array.new(300) { rng.rand(50) } +
                         Array.new(300) { rng.rand(2**40) }).sort,
    "large sampling" => Array.new(3000) { rng.rand(1_000_000) }.sort,
  }

  sequences.each do |name, values|
    it "matches array bisect for #{name}" do
      obj = BinData::EliasFanoSequence.new(initial_value: values)
      n = values.length
      local_rng = Random.new(999)

      # select aligns with plain array indexing
      n.times do |i|
        _(obj.select(i)).must_equal values[i]
      end
      _(obj.select(n)).must_be_nil

      # random queries, including exact hits and out of range probes
      probes = []
      probes.concat(values.sample([n, 20].min, random: local_rng))
      max = values[-1] || 0
      40.times do
        probes << local_rng.rand(max + 2)
        probes << local_rng.rand(2**62) if max > 2**40
      end
      probes << 0
      probes << max
      probes << max + 1

      probes.each do |x|
        expected_lb = BinData::EliasFanoSequenceTestHelper.ref_lower_bound(values, x)
        _(obj.lower_bound(x)).must_equal expected_lb
        _(obj.rank(x)).must_equal expected_lb
        expected_le = BinData::EliasFanoSequenceTestHelper.ref_rank_le(values, x)
        _(obj.rank_le(x)).must_equal expected_le
      end
    end
  end
end

# Reference implementations used by the randomised tests above.
module BinData::EliasFanoSequenceTestHelper
  def self.ref_lower_bound(arr, x)
    arr.bsearch_index { |v| v >= x } || arr.length
  end

  def self.ref_rank_le(arr, x)
    arr.bsearch_index { |v| v > x } || arr.length
  end
end
