#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))

describe BinData::Section do
  it "transforms data byte at a time" do
    require 'bindata/transform/xor'

    obj = BinData::Section.new(transform: -> { BinData::Transform::Xor.new(0xff) },
                               type: [:string, read_length: 5])

    _(obj.read("\x97\x9A\x93\x93\x90")).must_equal "hello"
  end

  it "reads and writes an HDLC frame with bit stuffing" do
    obj = BinData::Section.new(framing: :hdlc, bit_order: :little,
                               type: [:string, read_length: 1])
    data = "\xff".b

    obj.assign(data)
    encoded = obj.to_binary_s
    _(encoded).must_equal "\x7e\xdf\x01\xbe\xfb\xfd".b
    _(obj.read(encoded)).must_equal data
  end

  it "supports MSB-first HDLC frame checks" do
    obj = BinData::Section.new(framing: :hdlc, bit_order: :big,
                               type: [:string, read_length: 2])
    encoded = "\x7e\x41\x42\xb4\x8b\x7e".b

    _(obj.read(encoded)).must_equal "AB"
    obj.assign("AB")
    _(obj.to_binary_s).must_equal encoded
  end

  it "can disable the frame check" do
    obj = BinData::Section.new(framing: :hdlc, bit_order: :little,
                               frame_check: :none,
                               type: [:string, read_length: 2])
    encoded = "\x7e\x4f\x4b\x7e".b

    _(obj.read(encoded)).must_equal "OK"
  end

  it "continues after continuous flags, a bad frame and a cross-block abort" do
    good = BinData::Section.new(framing: :hdlc, bit_order: :little,
                                type: [:string, read_length: 2])
    good.assign("AB")
    bad_frame = "\x7e\x41\x42\xef\x32\x7e".b
    good.assign("OK")
    good_frame = good.to_binary_s

    to_lsb_bits = ->(data) do
      data.bytes.flat_map { |byte| (0...8).map { |index| (byte >> index) & 1 } }
    end
    from_lsb_bits = ->(bits) do
      padded = bits.dup
      padded.concat([1] * ((8 - (padded.length % 8)) % 8))
      padded.each_slice(8).map do |slice|
        slice.each_with_index.sum { |bit, index| bit << index }
      end.pack("C*")
    end

    bits = to_lsb_bits.call("\x7e\x7e".b) +
           to_lsb_bits.call(bad_frame) +
           [0, 1, 1, 1, 1, 1, 1, 0, 0, 0] + [1] * 7 +
           to_lsb_bits.call(good_frame)
    raw = from_lsb_bits.call(bits)

    one_byte_io = Class.new do
      def initialize(data)
        @io = BinData::IO.create_string_io(data)
      end

      def read(n)
        @io.read(1)
      end

      def pos
        @io.pos
      end

      def seek(*args)
        @io.seek(*args)
      end
    end

    errors = []
    obj = BinData::Section.new(
      framing: :hdlc,
      bit_order: :little,
      on_frame_error: ->(error) { errors << error },
      type: [:string, read_length: 2]
    )

    _(obj.read(one_byte_io.new(raw))).must_equal "OK"
    _(errors.map(&:reason)).must_equal [:invalid_frame_check, :abort]
    _(errors.first.discarded_range.first).must_equal raw.index(bad_frame) * 8
    abort_start = (2 + bad_frame.bytesize) * 8
    _(errors.last.discarded_range).must_equal [abort_start, abort_start + 17]
  end

  begin
    require 'brotli'
    it "transform brotli" do
      require 'bindata/transform/brotli'

      class BrotliRecord < BinData::Record
        int32le :len, value: -> { s.num_bytes }
        section :s, transform: -> { BinData::Transform::Brotli.new(len) } do
          int32le :str_len, value: -> { str.length }
          string :str, read_length: :str_len

        end
      end

      obj = BrotliRecord.new
      data = "highly compressible" * 100
      obj.s.str = data
      _(obj.len).must_be :<, (data.length / 10)

      str =  obj.to_binary_s
      obj = BrotliRecord.read(str)
      _(obj.s.str).must_equal data
    end
  rescue LoadError; end

  begin
    require 'extlz4'
    it "transform lz4" do
      require 'bindata/transform/lz4'

      class LZ4Record < BinData::Record
        int32le :len, value: -> { s.num_bytes }
        section :s, transform: -> { BinData::Transform::LZ4.new(len) } do
          int32le :str_len, value: -> { str.length }
          string :str, read_length: :str_len

        end
      end

      obj = LZ4Record.new
      data = "highly compressible" * 100
      obj.s.str = data
      _(obj.len).must_be :<, (data.length / 10)

      str =  obj.to_binary_s
      obj = LZ4Record.read(str)
      _(obj.s.str).must_equal data
    end
  rescue LoadError; end

  it "transform zlib" do
    require 'bindata/transform/zlib'

    class ZlibRecord < BinData::Record
      int32le :len, value: -> { s.num_bytes }
      section :s, transform: -> { BinData::Transform::Zlib.new(len) } do
        int32le :str_len, value: -> { str.length }
        string :str, read_length: :str_len

      end
    end

    obj = ZlibRecord.new
    data = "highly compressible" * 100
    obj.s.str = data
    _(obj.len).must_be :<, (data.length / 10)

    str =  obj.to_binary_s
    obj = ZlibRecord.read(str)
    _(obj.s.str).must_equal data
  end

  begin
    require 'zstd-ruby'
    it "transform zstd" do
      require 'bindata/transform/zstd'

      class ZstdRecord < BinData::Record
        int32le :len, value: -> { s.num_bytes }
        section :s, transform: -> { BinData::Transform::Zstd.new(len) } do
          int32le :str_len, value: -> { str.length }
          string :str, read_length: :str_len

        end
      end

      obj = ZstdRecord.new
      data = "highly compressible" * 100
      obj.s.str = data
      _(obj.len).must_be :<, (data.length / 10)

      str =  obj.to_binary_s
      obj = ZstdRecord.read(str)
      _(obj.s.str).must_equal data
    end
  rescue LoadError; end
end
