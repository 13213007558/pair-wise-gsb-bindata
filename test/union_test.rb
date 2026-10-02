#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))

class UnionWord < BinData::Union
  endian :little

  uint32le :word
  struct :halves do
    uint16 :low
    uint16 :high
  end
  array :octets, type: :uint8, initial_length: 4
end

class PaddedUnion < BinData::Union
  default_parameter length: 6

  uint16be :short
  uint32be :long
end

class DynamicUnion < BinData::Union
  default_parameter length: 4

  array :octets, type: :uint8, initial_length: 0
  uint32le :word
end

class RecordWithUnion < BinData::Record
  endian :little

  union :raw do
    uint32 :word
    struct :halves do
      uint16 :low
      uint16 :high
    end
  end
  string :tag, read_length: 2
end

class RecordArrayUnion < BinData::Union
  default_parameter length: 4

  uint32le :word
  struct :pair do
    array :halves, type: :uint16le, initial_length: 2
  end
end

describe BinData::Union, "when instantiating" do
  it "requires at least one view" do
    _ { BinData::Union.new(fields: []) }.must_raise ArgumentError
  end

  it "fails if a view type is unknown" do
    fields = [[:does_not_exist, :value]]
    _ { BinData::Union.new(fields: fields) }.must_raise BinData::UnRegisteredTypeError
  end

  it "fails if explicit capacity is too small for a fixed-size view" do
    fields = [[:uint32be, :word]]
    _ { BinData::Union.new(fields: fields, length: 3) }.must_raise ArgumentError
  end

  it "fails if explicit capacity is not positive" do
    fields = [[:uint32be, :word]]
    _ { BinData::Union.new(fields: fields, length: 0) }.must_raise ArgumentError
  end

  it "does not allow a view named length to shadow capacity" do
    fields = [[:uint32be, :length]]
    _ { BinData::Union.new(fields: fields) }.must_raise NameError
  end

  it "accepts explicit capacity together with endian hints" do
    obj = BinData::Union.new(
      endian: :little,
      length: 6,
      fields: [[:uint16, :short], [:uint32, :long]]
    )

    _(obj.num_bytes).must_equal 6
  end
end

describe BinData::Union, "with overlapping integer and record views" do
  let(:obj) { UnionWord.new }

  it "shares bytes written through two half-word views" do
    obj.halves.low = 0x3412
    obj.halves.high = 0x7856

    _(obj.word).must_equal 0x78563412
    _(obj.octets).must_equal [0x12, 0x34, 0x56, 0x78]
  end

  it "reflects changes in both directions" do
    obj.word = 0x12345678

    _(obj.halves.low).must_equal 0x5678
    _(obj.halves.high).must_equal 0x1234
  end

  it "reflects changes made through an array view" do
    obj.word = 0x12345678
    obj.octets[0] = 0xaa

    _(obj.word).must_equal 0x123456aa
    _(obj.halves.low).must_equal 0x56aa
  end

  it "reflects a nested array mutation inside a record view" do
    obj = RecordArrayUnion.new
    obj.pair.halves[1] = 0x1234

    _(obj.word).must_equal 0x12340000
  end

  it "serializes one fixed-size block of underlying bytes" do
    obj.halves.low = 0x3412
    obj.halves.high = 0x7856

    binary = obj.to_binary_s
    _(binary.bytesize).must_equal 4
    _(binary).must_equal_binary "\x12\x34\x56\x78"
  end

  it "uses the largest view as its capacity" do
    _(obj.num_bytes).must_equal 4
  end

  it "includes all current views in a snapshot" do
    obj.word = 0x12345678

    _(obj.snapshot).must_equal(
      word: 0x12345678,
      halves: { low: 0x5678, high: 0x1234 },
      octets: [0x78, 0x56, 0x34, 0x12]
    )
  end

  it "assigns from a hash and synchronizes the other views" do
    obj.assign(word: 0x12345678)

    _(obj.halves.low).must_equal 0x5678
    _(obj.halves.high).must_equal 0x1234
  end

  it "clears shared storage" do
    obj.word = 0x12345678
    _(obj.clear?).must_equal false

    obj.clear
    _(obj.clear?).must_equal true
    _(obj.word).must_equal 0
    _(obj.to_binary_s).must_equal_binary "\0\0\0\0"
  end
end

describe BinData::Union, "with different byte orders" do
  it "interprets the same bytes with each view's endian" do
    obj = BinData::Union.new(
      fields: [
        [:uint32be, :big_word],
        [:uint32le, :little_word]
      ]
    )

    obj.read("\x12\x34\x56\x78")
    _(obj.big_word).must_equal 0x12345678
    _(obj.little_word).must_equal 0x78563412

    obj.big_word = 0xaabbccdd
    _(obj.little_word).must_equal 0xddccbbaa
  end
end

describe BinData::Union, "with padded capacity" do
  it "preserves bytes outside a shorter view when switching" do
    obj = PaddedUnion.read("abcdef")

    _(obj.short).must_equal "ab".unpack1("S>")
    _(obj.long).must_equal "abcd".unpack1("L>")

    obj.short = "AB".unpack1("S>")
    _(obj.to_binary_s).must_equal_binary "ABcdef"
  end

  it "does not clear an uncovered tail after assigning a smaller view" do
    obj = PaddedUnion.new
    obj.read("abcdef")
    obj.short = 1

    _(obj.long).must_equal "\0\x01cd".unpack1("L>")
    _(obj.to_binary_s).must_equal_binary "\0\x01cdef"
  end

  it "preserves an uncovered tail when only switching views" do
    obj = PaddedUnion.read("abcdef")
    obj.long
    obj.short

    _(obj.to_binary_s).must_equal_binary "abcdef"
  end

  it "reports full union capacity rather than active view size" do
    obj = PaddedUnion.new

    _(obj.short.num_bytes).must_equal 2
    _(obj.num_bytes).must_equal 6
  end

  it "raises when a dynamic view grows beyond capacity" do
    obj = DynamicUnion.new

    _ { obj.octets.push(1, 2, 3, 4, 5) }.must_raise IOError
  end

  it "raises on a short read" do
    _ { PaddedUnion.read("abc") }.must_raise IOError
  end
end

describe BinData::Union, "embedded in a record" do
  it "shares storage and leaves following fields at the correct offset" do
    obj = RecordWithUnion.read("\x78\x56\x34\x12ZZ")

    _(obj.raw.word).must_equal 0x12345678
    _(obj.raw.halves.low).must_equal 0x5678
    _(obj.tag).must_equal "ZZ"
  end

  it "writes the union once followed by surrounding fields" do
    obj = RecordWithUnion.new
    obj.raw.halves.low = 0x3412
    obj.raw.halves.high = 0x7856
    obj.tag = "ZZ"

    _(obj.to_binary_s).must_equal_binary "\x12\x34\x56\x78ZZ"
  end
end

describe BinData::Array, "of unions" do
  it "keeps independent storage for each element" do
    values = BinData::Array.new(type: :union_word, initial_length: 2)
    values[0].word = 0x11111111
    values[1].halves.low = 0x2222
    values[1].halves.high = 0x3333

    _(values.to_binary_s).must_equal_binary(
      "\x11\x11\x11\x11\x22\x22\x33\x33"
    )
  end
end
