#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))

describe BinData::Varint do
  it "defaults to zero" do
    obj = BinData::Varint.new
    _(obj.value).must_equal 0
    assert_equals_binary "\x00", obj.to_binary_s
  end

  it "encodes small values in a single byte" do
    assert_equals_binary "\x00", BinData::Varint.new(0).to_binary_s
    assert_equals_binary "\x01", BinData::Varint.new(1).to_binary_s
    assert_equals_binary "\x7f", BinData::Varint.new(127).to_binary_s
  end

  it "encodes larger values over multiple bytes" do
    assert_equals_binary "\x80\x01", BinData::Varint.new(128).to_binary_s
    assert_equals_binary "\xac\x02", BinData::Varint.new(300).to_binary_s
    assert_equals_binary "\xff\x7f", BinData::Varint.new(16_383).to_binary_s
    assert_equals_binary "\x80\x80\x01", BinData::Varint.new(16_384).to_binary_s
  end

  it "encodes the maximum value in ten bytes" do
    obj = BinData::Varint.new(BinData::Varint::MAX_VALUE)
    assert_equals_binary "\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01", obj.to_binary_s
  end

  it "reads back written values" do
    [0, 1, 127, 128, 300, 16_383, 16_384, BinData::Varint::MAX_VALUE].each do |val|
      obj = BinData::Varint.new(val)
      _(BinData::Varint.read(obj.to_binary_s).value).must_equal val
    end
  end

  it "has a value dependent num_bytes" do
    obj = BinData::Varint.new
    _(obj.num_bytes).must_equal 1

    obj.assign(127)
    _(obj.num_bytes).must_equal 1

    obj.assign(128)
    _(obj.num_bytes).must_equal 2

    obj.assign(16_383)
    _(obj.num_bytes).must_equal 2

    obj.assign(16_384)
    _(obj.num_bytes).must_equal 3
  end

  it "clamps assigned values to the representable range" do
    obj = BinData::Varint.new(-5)
    _(obj.value).must_equal 0

    obj.assign(1 << 70)
    _(obj.value).must_equal BinData::Varint::MAX_VALUE
  end

  it "raises LengthOverflowError when the encoded value exceeds 64 bits" do
    _ {
      BinData::Varint.read("\xff\xff\xff\xff\xff\xff\xff\xff\xff\x7f")
    }.must_raise BinData::Layout::LengthOverflowError
  end

  it "raises LengthOverflowError when the encoding does not terminate" do
    _ {
      BinData::Varint.read("\x80" * 10)
    }.must_raise BinData::Layout::LengthOverflowError
  end

  it "is usable as a record field" do
    obj = Class.new(BinData::Record) do
      varint :len
      uint8  :tag
    end.new
    obj.read("\xac\x02\x07")
    _(obj.len).must_equal 300
    _(obj.tag).must_equal 7
    assert_equals_binary "\xac\x02\x07", obj.to_binary_s
  end
end
