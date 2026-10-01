#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))

describe BinData::Varint do
  it "computes the encoded width" do
    _(BinData::Varint.width_of(0)).must_equal 1
    _(BinData::Varint.width_of(1)).must_equal 1
    _(BinData::Varint.width_of(127)).must_equal 1
    _(BinData::Varint.width_of(128)).must_equal 2
    _(BinData::Varint.width_of(16_383)).must_equal 2
    _(BinData::Varint.width_of(16_384)).must_equal 3
    _(BinData::Varint.width_of((1 << 21) - 1)).must_equal 3
    _(BinData::Varint.width_of(1 << 21)).must_equal 4
    _(BinData::Varint.width_of(1 << 35)).must_equal 6
  end

  it "has a default of zero" do
    _(BinData::Varint.new).must_equal 0
  end

  it "writes values below 128 as a single byte" do
    _(BinData::Varint.new(initial_value: 0).to_binary_s).must_equal_binary "\x00"
    _(BinData::Varint.new(initial_value: 127).to_binary_s).must_equal_binary "\x7f"
  end

  it "writes values of 128 and above as multiple bytes" do
    _(BinData::Varint.new(initial_value: 128).to_binary_s).must_equal_binary "\x80\x01"
    _(BinData::Varint.new(initial_value: 300).to_binary_s).must_equal_binary "\xac\x02"
    _(BinData::Varint.new(initial_value: 16_384).to_binary_s).must_equal_binary "\x80\x80\x01"
  end

  it "round trips values across width boundaries" do
    [0, 1, 127, 128, 129, 300, 16_383, 16_384, (1 << 35)].each do |v|
      bytes = BinData::Varint.new(initial_value: v).to_binary_s
      _(BinData::Varint.read(bytes)).must_equal v
    end
  end

  it "has num_bytes matching the encoded width" do
    _(BinData::Varint.new(initial_value: 127).num_bytes).must_equal 1
    _(BinData::Varint.new(initial_value: 128).num_bytes).must_equal 2
    _(BinData::Varint.new(initial_value: 16_384).num_bytes).must_equal 3
  end

  it "rejects negative values on assign" do
    _ { BinData::Varint.new(-1) }.must_raise ArgumentError
  end

  it "rejects non integer values on assign" do
    _ { BinData::Varint.new("x") }.must_raise ArgumentError
  end

  it "rejects negative values on write" do
    obj = BinData::Varint.new(value: -> { -1 })
    _ { obj.to_binary_s }.must_raise RangeError
  end

  it "is usable as a record field" do
    class VarintRecord < BinData::Record
      varint :v
    end

    rec = VarintRecord.read("\xac\x02")
    _(rec.v).must_equal 300
    _(rec.to_binary_s).must_equal_binary "\xac\x02"
  end
end
