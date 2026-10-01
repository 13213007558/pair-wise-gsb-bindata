#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))

# Reads a LEB128 varint from +str+ at +offset+, returning
# [value, offset_after] so tests can recompute declared values from the
# final bytes.
def read_varint_from(str, offset = 0)
  value = 0
  shift = 0
  loop do
    byte = str.getbyte(offset)
    offset += 1
    value |= (byte & 0x7f) << shift
    break if (byte & 0x80).zero?

    shift += 7
  end
  [value, offset]
end

class SolvedLengthChunk < BinData::Record
  varint :len, solved_length: true
  string :payload
end

class SolvedLengthInner < BinData::Record
  varint :len, solved_length: true
  string :payload
end

class SolvedLengthOuter < BinData::Record
  varint :len, solved_length: true
  uint8  :tag
  solved_length_inner :inner
  uint8  :tail
end

class SolvedLengthAligned < BinData::Record
  varint :len, solved_length: true
  string :payload
  uint8  :tail, byte_align: 4
end

class SolvedLengthRoundTrip < BinData::Record
  varint :len, solved_length: true
  string :payload, read_length: -> { len - len.num_bytes }
end

# A field that fails halfway through writing itself.
class SolvedLengthExplodingField < BinData::Base
  def clear?; true; end
  def assign(val); end
  def snapshot; nil; end
  def do_num_bytes; 1; end
  def do_read(io); io.readbytes(1); end

  def do_write(io)
    io.writebytes("B")
    raise "boom"
  end
end

class SolvedLengthFragile < BinData::Record
  uint8  :tag
  varint :len, solved_length: true
  solved_length_exploding_field :expl
end

class SolvedLengthBadValue < BinData::Record
  uint8  :tag
  varint :len, solved_length: true
  varint :bad, value: -> { -1 }
end

class SolvedLengthHolder < BinData::Record
  uint8 :head
  solved_length_fragile :frag
end

describe BinData::Struct, "with :solved_length fields" do
  it "solves a self inclusive varint length" do
    obj = SolvedLengthChunk.new(payload: "abc")
    _(obj.to_binary_s).must_equal_binary "\x04abc"
    _(obj.len).must_equal 4
  end

  it "recomputes the declared length from the final bytes" do
    obj = SolvedLengthChunk.new(payload: "x" * 10)
    bytes = obj.to_binary_s

    declared, offset = read_varint_from(bytes)
    _(declared).must_equal bytes.bytesize
    _(declared).must_equal obj.len.value
    _(offset).must_equal 1
  end

  it "restabilises across the 127/128 varint width boundary" do
    # payload 126: total 127 fits in one varint byte.
    # payload 127: total 128 does not, so the stable total is 129.
    expectations = { 125 => 126, 126 => 127, 127 => 129, 128 => 130 }

    expectations.each_pair do |payload_size, expected_total|
      obj   = SolvedLengthChunk.new(payload: "x" * payload_size)
      bytes = obj.to_binary_s

      _(bytes.bytesize).must_equal expected_total
      _(obj.len).must_equal expected_total

      # recompute the declared value from the final bytes
      declared, offset = read_varint_from(bytes)
      _(declared).must_equal bytes.bytesize
      _(offset).must_equal BinData::Varint.width_of(expected_total)

      # the payload follows the length prefix
      _(bytes[offset..]).must_equal "x" * payload_size
    end
  end

  it "restabilises across the 16383/16384 varint width boundary" do
    [16_382, 16_383, 16_384].each do |payload_size|
      obj   = SolvedLengthChunk.new(payload: "x" * payload_size)
      bytes = obj.to_binary_s

      declared, offset = read_varint_from(bytes)
      _(declared).must_equal bytes.bytesize
      _(declared).must_equal obj.len.value
      _(offset).must_equal BinData::Varint.width_of(declared)
    end
  end

  it "restabilises when the content changes size" do
    obj = SolvedLengthChunk.new(payload: "x" * 126)
    _(obj.to_binary_s.bytesize).must_equal 127

    obj.payload = "x" * 127
    bytes = obj.to_binary_s
    _(bytes.bytesize).must_equal 129
    _(obj.len).must_equal 129

    obj.payload = "x" * 126
    _(obj.to_binary_s.bytesize).must_equal 127
    _(obj.len).must_equal 127
  end

  it "keeps num_bytes consistent with the written bytes" do
    [1, 126, 127, 300].each do |payload_size|
      obj = SolvedLengthChunk.new(payload: "x" * payload_size)
      _(obj.num_bytes).must_equal obj.to_binary_s.bytesize
    end
  end

  it "reads back self describing records" do
    obj   = SolvedLengthRoundTrip.new(payload: "y" * 200)
    bytes = obj.to_binary_s

    read = SolvedLengthRoundTrip.read(bytes)
    _(read.len).must_equal bytes.bytesize
    _(read.payload).must_equal "y" * 200
  end

  describe "with two levels of self inclusive lengths" do
    it "solves both levels" do
      obj = SolvedLengthOuter.new(tag: 1, inner: { payload: "hello" }, tail: 9)
      bytes = obj.to_binary_s

      # recompute every declared value from the final bytes
      outer_len, offset = read_varint_from(bytes)
      _(outer_len).must_equal bytes.bytesize
      _(outer_len).must_equal obj.len.value

      _(bytes.getbyte(offset)).must_equal 1
      inner_len, = read_varint_from(bytes, offset + 1)
      _(inner_len).must_equal obj.inner.len.value
      _(inner_len).must_equal obj.inner.num_bytes
      _(bytes.getbyte(bytes.bytesize - 1)).must_equal 9
    end

    it "restabilises both levels across width boundaries" do
      # inner total is 127 (one byte); adding the outer fields pushes
      # the outer total across 128, so the outer length needs two bytes.
      obj = SolvedLengthOuter.new(tag: 1, inner: { payload: "x" * 126 }, tail: 9)
      bytes = obj.to_binary_s

      _(obj.inner.len).must_equal 127

      outer_len, offset = read_varint_from(bytes)
      _(outer_len).must_equal bytes.bytesize
      _(outer_len).must_equal 127 + 1 + 1 + 2
      _(offset).must_equal 2

      inner_len, = read_varint_from(bytes, offset + 1)
      _(inner_len).must_equal 127
    end
  end

  describe "with alignment padding" do
    it "accounts for padding in the solved length" do
      obj = SolvedLengthAligned.new(payload: "abc", tail: 0xff)
      bytes = obj.to_binary_s

      # len(1) + payload(3) = 4, already aligned, tail at offset 4
      _(bytes.bytesize).must_equal 5
      _(obj.len).must_equal 5
      _(bytes.getbyte(4)).must_equal 0xff
    end

    it "inserts padding so the aligned field lands on its boundary" do
      obj = SolvedLengthAligned.new(payload: "ab", tail: 0xff)
      bytes = obj.to_binary_s

      # len(1) + payload(2) = 3, one pad byte, tail at offset 4
      _(bytes.bytesize).must_equal 5
      _(bytes.getbyte(3)).must_equal 0
      _(bytes.getbyte(4)).must_equal 0xff

      declared, = read_varint_from(bytes)
      _(declared).must_equal bytes.bytesize
    end

    it "keeps alignment and length consistent across the width boundary" do
      (120..130).each do |payload_size|
        obj   = SolvedLengthAligned.new(payload: "x" * payload_size, tail: 0xff)
        bytes = obj.to_binary_s

        # recompute all declared values from the final bytes
        declared, prefix_width = read_varint_from(bytes)
        _(declared).must_equal bytes.bytesize
        _(declared).must_equal obj.len.value

        # the tail sits at the end of the record on a 4 byte boundary
        tail_offset = bytes.bytesize - 1
        _(tail_offset % 4).must_equal 0
        _(bytes.getbyte(tail_offset)).must_equal 0xff

        # padding between payload and tail is zeroed
        padding = bytes[(prefix_width + payload_size)...tail_offset]
        _(padding).must_equal "\x00" * padding.bytesize
      end
    end
  end

  describe "when building fails" do
    it "leaves no partial record on the caller io" do
      io = StringIO.new
      _ { SolvedLengthFragile.new(tag: 1).write(io) }.must_raise RuntimeError
      _(io.string).must_equal ""
    end

    it "leaves no partial record when solving fails" do
      io = StringIO.new
      _ {
        SolvedLengthBadValue.new(tag: 1).write(io)
      }.must_raise BinData::LayoutSolver::UnsupportedExpressionError
      _(io.string).must_equal ""
    end

    it "does not emit partial bytes of the failing record when nested" do
      io = StringIO.new
      _ { SolvedLengthHolder.new(head: 7, frag: { tag: 1 }).write(io) }.must_raise RuntimeError

      # only the complete leading field of the outer record was written
      _(io.string).must_equal "\x07"
    end
  end
end
