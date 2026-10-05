#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))

describe BinData::Section do
  it "transforms data byte at a time" do
    require 'bindata/transform/xor'

    obj = BinData::Section.new(transform: -> { BinData::Transform::Xor.new(0xff) },
                               type: [:string, read_length: 5])

    _(obj.read("\x97\x9A\x93\x93\x90")).must_equal "hello"
  end

  it "reads and writes HDLC framed data" do
    require 'bindata/transform/hdlc'

    obj = BinData::Section.new(
      transform: -> { BinData::Transform::HDLC.new(bit_order: :big) },
      type: [:string, read_length: 5]
    )
    obj.assign("hello")

    wire = obj.to_binary_s
    _(wire).must_equal "~hello-\x91~".b
    reader = BinData::Section.new(
      transform: -> { BinData::Transform::HDLC.new(bit_order: :big) },
      type: [:string, read_length: 5]
    )
    _(reader.read(wire)).must_equal "hello"
  end

  it "strips bit stuffing before checking the HDLC FCS" do
    require 'bindata/transform/hdlc'

    obj = BinData::Section.new(
      transform: -> { BinData::Transform::HDLC.new(bit_order: :lsb) },
      type: [:string, read_length: 1]
    )
    obj.assign("\xff".b)
    wire = obj.to_binary_s

    _(wire.bytesize).must_equal 6
    _(obj.read(wire)).must_equal "\xff".b
  end

  it "handles consecutive flags and resumes after a discarded frame" do
    require 'bindata/transform/hdlc'

    transform = BinData::Transform::HDLC.new(bit_order: :big)
    good_one = transform.encode_frame("bad!x")
    bad = good_one.dup
    bad.setbyte(1, bad.getbyte(1) ^ 0x01)
    good_two = transform.encode_frame("good")
    stream = bad + "\x7e" + good_two

    errors = []
    transform = BinData::Transform::HDLC.new(
      bit_order: :big,
      on_invalid_frame: ->(error) { errors << error }
    )
    payload = nil
    BinData::IO::Read.new(StringIO.new(stream)).transform(transform) do |io|
      payload = io.read_all_bytes
    end

    _(payload).must_equal "good"
    _(errors.map(&:reason)).must_equal [:fcs]
    error = errors.first
    _(error.reason).must_equal :fcs
    _(error.bit_range).must_equal(0...(bad.bytesize * 8))
    _(error.byte_range).must_equal(0...bad.bytesize)
  end

  it "recognizes abort across arbitrary byte and bit chunks" do
    require 'bindata/transform/hdlc'

    transform = BinData::Transform::HDLC.new(bit_order: :little)
    aborted = transform.encode_frame("lost")
    aborted.setbyte(aborted.bytesize - 1, 0xfe)
    good = transform.encode_frame("next")
    stream = aborted + good
    bit_stream = stream.bytes.flat_map do |byte|
      0.upto(7).map { |index| (byte >> index) & 1 }
    end

    decoder = BinData::Transform::HDLC::Decoder.new(:little)
    events = []
    bit_stream.each_slice(13) do |bits|
      events.concat(decoder.feed_bits(bits))
    end
    events.concat(decoder.flush)

    _(events.map(&:payload).compact).must_equal ["next"]
    _(events.find { |event| !event.valid }.reason).must_equal :abort
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
