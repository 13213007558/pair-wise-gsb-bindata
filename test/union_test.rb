#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))

class TestWord < BinData::Union
  endian :big

  uint32 :word
  struct :halves do
    uint16 :high
    uint16 :low
  end
  array :byte_list, type: :uint8, initial_length: 4
end

class TestMixedEndianWord < BinData::Union
  uint32be :big_word
  uint32le :little_word
end

class TestShortView < BinData::Union
  uint32be :full
  uint16be :short
end

def short_view(value = nil, data = nil)
  params = {byte_length: 4}
  data ? TestShortView.read(data, params) : TestShortView.new(value, params)
end

class TestNestedRecordArray < BinData::Union
  endian :little

  array :halves, type: :uint16, initial_length: 2
  struct :pair do
    uint16 :low_half
    uint16 :high_half
  end
end

class TestEnclosingRecord < BinData::Record
  endian :big

  union :word do
    uint32 :whole
    struct :halves do
      uint16 :high
      uint16 :low
    end
  end
end

describe BinData::Union do
  it "has the capacity of the largest view by default" do
    _(TestWord.new.num_bytes).must_equal 4
  end

  it "shares one storage between primitive and record views" do
    obj = TestWord.new

    obj.halves.high = 0x1234
    obj.halves.low = 0x5678

    _(obj.word).must_equal 0x12345678
    _(obj.to_binary_s).must_equal_binary "\x12\x34\x56\x78"
  end

  it "shares changes made through an array view" do
    obj = TestWord.new

    obj.byte_list[0] = 0x01
    obj.byte_list[3] = 0x02

    _(obj.word).must_equal 0x01000002
    _(obj.halves.high).must_equal 0x0100
    _(obj.halves.low).must_equal 0x0002
    _(obj.to_binary_s).must_equal_binary "\x01\x00\x00\x02"
  end

  it "reflects a whole-word write through halfword views" do
    obj = TestWord.new

    obj.word = 0x01020304

    _(obj.halves.high).must_equal 0x0102
    _(obj.halves.low).must_equal 0x0304
    _(obj.byte_list.to_a).must_equal [1, 2, 3, 4]
  end

  it "reflects an array view clear immediately" do
    obj = TestWord.read("\x01\x02\x03\x04")

    obj.byte_list.clear

    _(obj.word).must_equal 0
    _(obj.to_binary_s).must_equal_binary "\x00\x00\x00\x00"
  end

  it "supports views with different byte orders" do
    obj = TestMixedEndianWord.read("\x01\x02\x03\x04")

    _(obj.big_word).must_equal 0x01020304
    _(obj.little_word).must_equal 0x04030201

    obj.little_word = 0x04030201
    _(obj.to_binary_s).must_equal_binary "\x01\x02\x03\x04"
  end

  it "serializes explicit capacity with zero padding" do
    obj = short_view
    obj.short = 0xabcd

    _(obj.num_bytes).must_equal 4
    _(obj.to_binary_s).must_equal_binary "\xab\xcd\x00\x00"
  end

  it "does not clear uncovered trailing bytes when switching views" do
    obj = short_view(nil, "\x12\x34\x56\x78")

    _(obj.short).must_equal 0x1234
    obj.short = 0xabcd

    _(obj.full).must_equal 0xabcd5678
    _(obj.to_binary_s).must_equal_binary "\xab\xcd\x56\x78"
  end

  it "does not zero a retained tail when reading a shorter view" do
    obj = short_view(nil, "\x12\x34\x56\x78")

    _(obj.full).must_equal 0x12345678
    _(obj.short).must_equal 0x1234
    _(obj.to_binary_s).must_equal_binary "\x12\x34\x56\x78"
  end

  it "keeps nested records and arrays aliased to the same bytes" do
    obj = TestNestedRecordArray.new

    obj.halves[0] = 0x0201
    obj.halves[1] = 0x0403

    _(obj.pair.low_half).must_equal 0x0201
    _(obj.pair.high_half).must_equal 0x0403
    _(obj.to_binary_s).must_equal_binary "\x01\x02\x03\x04"

    obj.pair.high_half = 0x0605
    _(obj.halves.to_a).must_equal [0x0201, 0x0605]
    _(obj.to_binary_s).must_equal_binary "\x01\x02\x05\x06"
  end

  it "keeps union storage aliased when embedded in a record" do
    obj = TestEnclosingRecord.new

    obj.word.halves.high = 0x1122
    obj.word.halves.low = 0x3344

    _(obj.word.whole).must_equal 0x11223344
    _(obj.to_binary_s).must_equal_binary "\x11\x22\x33\x44"
  end

  it "rejects a static view larger than explicit capacity" do
    _ {
      BinData::Union.new(
        byte_length: 2,
        fields: [[:uint32be, :whole]]
      )
    }.must_raise ArgumentError
  end

  it "raises when a dynamic view grows beyond union capacity" do
    obj = BinData::Union.new(
      byte_length: 2,
      fields: [[:array, :byte_list, {type: :uint8, initial_length: 2}]]
    )

    _ { obj.byte_list << 3 }.must_raise BinData::ValidityError
  end

  it "assigns complete binary storage directly" do
    obj = TestWord.new
    obj.assign("\x00\x01\x00\x02")

    _(obj.word).must_equal 0x00010002
    _(obj.to_binary_s).must_equal_binary "\x00\x01\x00\x02"
  end

  it "rejects binary assignment with the wrong length" do
    obj = TestWord.new

    _ { obj.assign("abc") }.must_raise ArgumentError
  end

  it "assigns named views from a hash" do
    obj = TestWord.new(halves: {high: 1, low: 2})

    _(obj.word).must_equal 0x00010002
    _(obj.to_binary_s).must_equal_binary "\x00\x01\x00\x02"
  end
end
