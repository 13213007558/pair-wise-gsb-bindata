#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))

describe BinData::IntBlockArray do
  let(:values) do
    [0, 1, -1, 2, -128, 127, 1000, -1000, 1 << 200, -(1 << 201)]
  end

  def encoded(values, **params)
    arr = BinData::IntBlockArray.new(params)
    arr.assign(values)
    arr.to_binary_s.dup
  end

  it "round trips an empty array" do
    binary = encoded([])
    arr = BinData::IntBlockArray.read(binary)

    _(arr).must_equal([])
    _(arr.length).must_equal(0)
    _(arr).must_be(:empty?)
  end

  it "round trips signed and oversized integers in little endian" do
    binary = encoded(values, block_size: 3, endian: :little)
    arr = BinData::IntBlockArray.read(binary, endian: :little)

    _(arr.snapshot).must_equal(values)
    values.each_with_index do |value, index|
      _(arr[index]).must_equal(value)
    end
  end

  it "round trips signed and oversized integers in big endian" do
    binary = encoded(values, block_size: 3, endian: :big)
    arr = BinData::IntBlockArray.read(binary, endian: :big)

    _(arr.snapshot).must_equal(values)
    values.each_with_index do |value, index|
      _(arr[index]).must_equal(value)
    end
  end

  it "does not require decoding earlier blocks for indexed reads" do
    binary = encoded(values, block_size: 3)
    arr = BinData::IntBlockArray.read(binary)

    values.each_with_index do |value, index|
      _(arr.value_at(index)).must_equal(value)
      _(arr[index]).must_equal(value)
    end
    _(arr[-1]).must_equal(values.last)
    _(arr[-3]).must_equal(values[-3])
  end

  it "opens only the selected block for an indexed read" do
    binary = encoded([1, 2, 100, 101], block_size: 2)
    arr = BinData::IntBlockArray.read(binary)
    codec = arr.instance_variable_get(:@codec)
    decoded_blocks = []
    codec.singleton_class.send(:alias_method, :original_decode_block, :decode_block)
    codec.define_singleton_method(:decode_block) do |block_index|
      decoded_blocks << block_index
      original_decode_block(block_index)
    end

    _(arr[2]).must_equal(100)
    _(decoded_blocks).must_equal([1])
  end

  it "preserves a final partial block" do
    binary = encoded([10, 11, 12, 13], block_size: 3)
    arr = BinData::IntBlockArray.read(binary)

    _(arr.snapshot).must_equal([10, 11, 12, 13])
    _(arr[3]).must_equal(13)
    _(arr.num_bytes).must_equal(binary.bytesize)
  end

  it "stores exception differences without truncation" do
    huge_positive = 1 << 200
    huge_negative = -(1 << 201)
    binary = encoded([0, 1, huge_positive, huge_negative], block_size: 4)
    arr = BinData::IntBlockArray.read(binary)

    _(arr[2]).must_equal(huge_positive)
    _(arr[3]).must_equal(huge_negative)
  end

  it "returns nil for out of range indexed reads" do
    arr = BinData::IntBlockArray.read(encoded([1, 2], block_size: 2))

    _(arr[2]).must_be_nil
    _(arr[-3]).must_be_nil
  end

  it "supports ranges without changing indexed values" do
    binary = encoded(values, block_size: 4)
    arr = BinData::IntBlockArray.read(binary)

    _(arr[2..4]).must_equal(values[2..4])
    _(arr[1, 3]).must_equal(values[1, 3])
    _(arr.to_a).must_equal(values)
  end

  it "rejects non-array assignment" do
    arr = BinData::IntBlockArray.new

    _ { arr.assign(1) }.must_raise ArgumentError
  end

  it "rejects non-integer elements" do
    arr = BinData::IntBlockArray.new

    _ { arr.assign([1, "2"]) }.must_raise ArgumentError
  end

  it "rejects invalid block sizes" do
    _ { BinData::IntBlockArray.new(block_size: 0) }.must_raise ArgumentError
    _ { BinData::IntBlockArray.new(block_size: 65536) }.must_raise ArgumentError
  end

  it "rejects an unknown endian" do
    _ { BinData::IntBlockArray.new(endian: :middle) }.must_raise ArgumentError
  end

  it "rejects a truncated header" do
    binary = encoded([1])

    _ { BinData::IntBlockArray.read(binary[0...-1]) }.must_raise IOError
  end

  it "rejects a truncated payload" do
    binary = encoded(values, block_size: 3)
    payload_size = binary.unpack1('@12Q<')
    cut_size = 24 + payload_size - 1
    truncated = binary.byteslice(0, cut_size)
    truncated.setbyte(12, payload_size - 1)
    arr = BinData::IntBlockArray.read(truncated)

    _ { arr.snapshot }.must_raise IOError
  end

  it "allows trailing bytes after a self delimited value" do
    binary = encoded([1]) + "\0"

    arr = BinData::IntBlockArray.read(binary)

    _(arr.snapshot).must_equal([1])
  end

  it "rejects an unknown version" do
    binary = encoded([])
    binary.setbyte(4, 2)

    _ { BinData::IntBlockArray.read(binary) }.must_raise IOError
  end

  it "rejects reserved flags" do
    binary = encoded([])
    binary.setbyte(5, 2)

    _ { BinData::IntBlockArray.read(binary) }.must_raise IOError
  end

  it "rejects a non-minimal unsigned varint" do
    binary = encoded([1, 2], block_size: 2)
    block_start = 24 + 8
    binary.setbyte(block_start, 0x80)
    binary.insert(block_start + 1, "\0")
    payload_size = binary.unpack1('@12Q<') + 1
    binary.setbyte(12, payload_size & 0xff)

    _ { BinData::IntBlockArray.read(binary)[0] }.must_raise IOError
  end

  it "does not decode earlier blocks for a later indexed read" do
    binary = encoded([1, 2, 100, 101], block_size: 2)
    width_position = 24 + 16 + 1
    binary.setbyte(width_position, 65)
    arr = BinData::IntBlockArray.read(binary)

    _(arr[2]).must_equal(100)
    _ { arr[0] }.must_raise IOError
  end

  it "can be embedded in a record" do
    klass = Class.new(BinData::Record) do
      endian :little
      uint32 :entry_count
      int_block_array :numbers, block_size: 2
      uint8 :suffix
    end

    record = klass.new
    record.entry_count = values.length
    record.suffix = 42
    record.numbers.assign(values)
    binary = record.to_binary_s
    read_record = klass.read(binary)

    _(read_record.numbers.snapshot).must_equal(values)
    _(read_record.numbers[values.length - 1]).must_equal(values.last)
    _(read_record.suffix).must_equal(42)
  end
end
