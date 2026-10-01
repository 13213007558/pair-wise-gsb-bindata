#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))

# Decodes a varint from the start of +bin+, returning [value, width].
# Used to recompute declared values from the final bytes.
def decode_varint(bin)
  value = 0
  shift = 0
  bin.each_byte.with_index(1) do |byte, width|
    value |= (byte & 0x7f) << shift
    return [value, width] if (byte & 0x80).zero?

    shift += 7
  end
  raise "unterminated varint"
end

class SSInner < BinData::SelfSizedRecord
  varint :len
  uint8  :tag
  string :payload, read_length: -> { content_length - 1 }
end

class SSAligned < BinData::SelfSizedRecord
  length_align 4

  varint :len
  uint8  :n
  string :payload, read_length: :n
end

class SSOuter < BinData::SelfSizedRecord
  varint :len
  uint8  :version
  ss_inner :inner
  uint8  :trailer
end

describe BinData::SelfSizedRecord do
  it "writes a length that includes the length field itself" do
    obj = SSInner.new(tag: 7, payload: "hello")
    bin = obj.to_binary_s

    decoded_len, width = decode_varint(bin)
    _(decoded_len).must_equal bin.size
    _(width).must_equal 1
    _(obj.len).must_equal bin.size
  end

  it "reads back all declared values from the final bytes" do
    obj = SSInner.new(tag: 7, payload: "hello")
    back = SSInner.read(obj.to_binary_s)

    _(back.len).must_equal 7
    _(back.tag).must_equal 7
    _(back.payload).must_equal "hello"
    _(back.content_length).must_equal 6
    _(back.padding_length).must_equal 0
    _(back.num_bytes).must_equal 7
    _(back.len.abs_offset).must_equal 0
    _(back.tag.abs_offset).must_equal 1
    _(back.payload.abs_offset).must_equal 2
  end

  it "keeps a one byte length when the total fits in 127 bytes" do
    obj = SSInner.new(tag: 0, payload: "x" * 125)
    bin = obj.to_binary_s

    decoded_len, width = decode_varint(bin)
    _(decoded_len).must_equal 127
    _(width).must_equal 1
    _(bin.size).must_equal 127
    _(obj.len).must_equal 127

    back = SSInner.read(bin)
    _(back.len).must_equal 127
    _(back.content_length).must_equal 126
    _(back.payload.length).must_equal 125
  end

  it "restabilises past 128 when the length crosses the width boundary" do
    # content is 127 bytes, so a 1 byte length field (max 127) cannot
    # represent the total; the length grows to 129 with a 2 byte varint.
    obj = SSInner.new(tag: 0, payload: "x" * 126)
    bin = obj.to_binary_s

    decoded_len, width = decode_varint(bin)
    _(decoded_len).must_equal 129
    _(width).must_equal 2
    _(bin.size).must_equal 129
    assert_equals_binary "\x81\x01", bin[0, 2]

    back = SSInner.read(bin)
    _(back.len).must_equal 129
    _(back.content_length).must_equal 127
    _(back.payload.length).must_equal 126
    _(back.payload.abs_offset).must_equal 3
  end

  it "restabilises past 16384 when the length crosses the next boundary" do
    obj = SSInner.new(tag: 0, payload: "x" * 16_380)
    bin = obj.to_binary_s

    decoded_len, width = decode_varint(bin)
    _(decoded_len).must_equal 16_383
    _(width).must_equal 2

    obj = SSInner.new(tag: 0, payload: "x" * 16_381)
    bin = obj.to_binary_s

    decoded_len, width = decode_varint(bin)
    _(decoded_len).must_equal 16_385
    _(width).must_equal 3

    back = SSInner.read(bin)
    _(back.len).must_equal 16_385
    _(back.payload.length).must_equal 16_381
  end

  it "nests two levels of self inclusive lengths" do
    obj = SSOuter.new(version: 1, trailer: 9,
                      inner: { tag: 7, payload: "hello" })
    bin = obj.to_binary_s

    decoded_len, _width = decode_varint(bin)
    _(decoded_len).must_equal bin.size

    back = SSOuter.read(bin)
    _(back.len).must_equal 10
    _(back.version).must_equal 1
    _(back.trailer).must_equal 9
    _(back.inner.len).must_equal 7
    _(back.inner.tag).must_equal 7
    _(back.inner.payload).must_equal "hello"
    _(back.inner.abs_offset).must_equal 2
    _(back.trailer.abs_offset).must_equal 9
    _(back.num_bytes).must_equal 10
  end

  it "solves nested lengths across a varint width boundary" do
    obj = SSOuter.new(version: 1, trailer: 9,
                      inner: { tag: 0, payload: "x" * 126 })
    bin = obj.to_binary_s

    decoded_len, width = decode_varint(bin)
    _(decoded_len).must_equal bin.size
    _(width).must_equal 2

    back = SSOuter.read(bin)
    _(back.len).must_equal 133
    _(back.inner.len).must_equal 129
    _(back.inner.payload.length).must_equal 126
    _(back.inner.abs_offset).must_equal 3
    _(back.trailer.abs_offset).must_equal 132
    _(back.num_bytes).must_equal 133
  end

  it "pads the record to the declared alignment" do
    obj = SSAligned.new(n: 5, payload: "hello")
    bin = obj.to_binary_s

    decoded_len, _width = decode_varint(bin)
    _(decoded_len).must_equal 8
    _(bin.size).must_equal 8
    _((bin.size % 4)).must_equal 0
    assert_equals_binary "\x00", bin[-1, 1]

    back = SSAligned.read(bin)
    _(back.len).must_equal 8
    _(back.content_length).must_equal 7
    _(back.padding_length).must_equal 1
    _(back.payload).must_equal "hello"
  end

  it "lets alignment absorb a varint width boundary crossing" do
    # content is 126 bytes; with alignment 4 the total stabilises at 128
    # with a 2 byte length field and no padding.
    obj = SSAligned.new(n: 125, payload: "x" * 125)
    bin = obj.to_binary_s

    decoded_len, width = decode_varint(bin)
    _(decoded_len).must_equal 128
    _(width).must_equal 2
    _(bin.size).must_equal 128

    back = SSAligned.read(bin)
    _(back.len).must_equal 128
    _(back.padding_length).must_equal 0
    _(back.payload.length).must_equal 125

    # one more content byte forces 3 padding bytes
    obj = SSAligned.new(n: 126, payload: "x" * 126)
    bin = obj.to_binary_s

    decoded_len, _width = decode_varint(bin)
    _(decoded_len).must_equal 132
    _((bin.size % 4)).must_equal 0
    assert_equals_binary "\x00\x00\x00", bin[-3, 3]

    back = SSAligned.read(bin)
    _(back.padding_length).must_equal 3
    _(back.payload.length).must_equal 126
  end

  it "inherits length_align from the parent class" do
    subclass = Class.new(SSAligned)
    obj = subclass.new(n: 5, payload: "hello")
    _(obj.to_binary_s.size).must_equal 8
  end

  it "rejects invalid length_align values" do
    _ {
      Class.new(BinData::SelfSizedRecord) do
        length_align 0
      end
    }.must_raise ArgumentError

    _ {
      Class.new(BinData::SelfSizedRecord) do
        length_align(-4)
      end
    }.must_raise ArgumentError
  end

  it "is usable as a field of a plain record" do
    klass = Class.new(BinData::Record) do
      uint8    :hdr
      ss_inner :inner
    end

    obj = klass.new(hdr: 1, inner: { tag: 7, payload: "hi" })
    bin = obj.to_binary_s
    _(bin.size).must_equal 5

    back = klass.read(bin)
    _(back.hdr).must_equal 1
    _(back.inner.len).must_equal 4
    _(back.inner.payload).must_equal "hi"
  end

  it "does not write a partial record when the build fails" do
    klass = Class.new(BinData::SelfSizedRecord) do
      varint :len
      uint8  :bad, value: -> { raise "boom" }
    end

    io = StringIO.new
    _ { klass.new.write(io) }.must_raise RuntimeError
    _(io.string).must_equal ""
  end

  it "does not write a partial record when the layout cannot stabilise" do
    klass = Class.new(BinData::SelfSizedRecord) do
      varint :len
      string :pad, value: -> { "x" * length_value }
    end

    io = StringIO.new
    _ { klass.new.write(io) }.must_raise BinData::Layout::NoStableSolutionError
    _(io.string).must_equal ""
  end

  it "raises NoStableSolutionError when num_bytes cannot stabilise" do
    klass = Class.new(BinData::SelfSizedRecord) do
      varint :len
      string :pad, value: -> { "x" * length_value }
    end

    _ { klass.new.num_bytes }.must_raise BinData::Layout::NoStableSolutionError
  end

  it "rejects a declared length that excludes its own field" do
    _ { SSInner.read("\x00") }.must_raise BinData::ValidityError
  end

  it "rejects content that exceeds the declared length" do
    klass = Class.new(BinData::SelfSizedRecord) do
      varint   :len
      uint32be :a
      uint32be :b
    end

    _ { klass.read("\x03" + "\x00" * 8) }.must_raise BinData::ValidityError
  end

  it "requires the first field to be a varint" do
    klass = Class.new(BinData::SelfSizedRecord) do
      uint8 :not_a_varint
    end

    _ { klass.new.to_binary_s }.must_raise TypeError
  end

  it "rejects byte_align fields in favour of length_align" do
    klass = Class.new(BinData::SelfSizedRecord) do
      varint :len
      uint8  :a, byte_align: 4
    end

    _ { klass.new }.must_raise ArgumentError
  end
end
