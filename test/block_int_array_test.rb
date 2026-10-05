#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))

describe BinData::BlockIntArray do
  let(:values) do
    [0, 1, -1, 2, 100_000, 99_997, 1 << 128, (1 << 128) - 5]
  end

  it "round trips signed deltas, exceptions and a partial tail block" do
    arr = BinData::BlockIntArray.new(values, block_size: 3)
    encoded = arr.to_binary_s
    decoded = BinData::BlockIntArray.new(block_size: 3).read(encoded)

    _(decoded.to_a).must_equal(values)
    values.each_index do |index|
      _(decoded[index]).must_equal(values[index])
    end
    _(decoded[-1]).must_equal(values.last)
  end

  it "uses less space than fixed 64-bit little-endian storage" do
    mostly_small = Array.new(100) { |index| index }
    mostly_small[50] = 1 << 200

    encoded = BinData::BlockIntArray.new(mostly_small).to_binary_s
    _(encoded.bytesize).must_be(:<, mostly_small.length * 8 + 24)
  end

  it "preserves values outside the configured common width without truncation" do
    large = 1 << 130
    values = [large, large + 1, large - 3]
    encoded = BinData::BlockIntArray
                .new(values, block_size: 3, common_nbits: 4)
                .to_binary_s
    decoded = BinData::BlockIntArray
                .new(block_size: 3, common_nbits: 4)
                .read(encoded)

    _(decoded.to_a).must_equal(values)
  end

  it "supports an empty array" do
    encoded = BinData::BlockIntArray.new([]).to_binary_s
    decoded = BinData::BlockIntArray.new.read(encoded)

    _(decoded).must_be_empty
    _(decoded[0]).must_be_nil
    _(encoded.bytesize).must_equal(24)
  end

  it "pads unused packed bits with zero and ignores them on read" do
    values = [7, 8, 9]
    encoded = BinData::BlockIntArray.new(values, block_size: 3, common_nbits: 2)
                .to_binary_s
    decoded = BinData::BlockIntArray
                .new(block_size: 3, common_nbits: 2)
                .read(encoded)

    _(decoded.to_a).must_equal(values)
  end

  it "declares a versioned little-endian header" do
    encoded = BinData::BlockIntArray.new([1], block_size: 64).to_binary_s

    _(encoded.byteslice(0, 4)).must_equal("BDBA".b)
    _(encoded.getbyte(4)).must_equal(1)
    _(encoded.getbyte(5)).must_equal(0)
    _(encoded.byteslice(6, 2).unpack1('v')).must_equal(64)
    _(encoded.byteslice(8, 8).unpack1('Q<')).must_equal(encoded.bytesize)
    _(encoded.byteslice(16, 8).unpack1('Q<')).must_equal(1)
  end

  it "rejects an unsupported version" do
    encoded = BinData::BlockIntArray.new([1]).to_binary_s
    encoded.setbyte(4, 2)

    _ { BinData::BlockIntArray.new.read(encoded) }.must_raise BinData::ValidityError
  end

  it "rejects truncated data" do
    encoded = BinData::BlockIntArray.new(values, block_size: 3).to_binary_s

    _ { BinData::BlockIntArray.new(block_size: 3).read(encoded.byteslice(0, 24)) }
      .must_raise IOError
  end

  it "rejects a mismatched block size" do
    encoded = BinData::BlockIntArray.new(values, block_size: 3).to_binary_s

    _ { BinData::BlockIntArray.new(block_size: 4).read(encoded) }
      .must_raise BinData::ValidityError
  end

  it "rejects nonzero padding in common deltas" do
    encoded = BinData::BlockIntArray.new([1, 2, 3], block_size: 3).to_binary_s
    encoded.setbyte(46, 0xff)
    decoded = BinData::BlockIntArray.new(block_size: 3)

    _ { decoded.read(encoded)[2] }.must_raise BinData::ValidityError
  end

  it "validates block size parameters" do
    _ { BinData::BlockIntArray.new(block_size: 0) }.must_raise ArgumentError
    _ { BinData::BlockIntArray.new(block_size: 65_536) }.must_raise ArgumentError
  end

  it "validates common width parameters" do
    _ { BinData::BlockIntArray.new(common_nbits: -1) }.must_raise ArgumentError
    _ { BinData::BlockIntArray.new(common_nbits: 65) }.must_raise ArgumentError
  end

  it "rejects non-integer values" do
    _ { BinData::BlockIntArray.new([1, "2"]) }.must_raise ArgumentError
  end
end
