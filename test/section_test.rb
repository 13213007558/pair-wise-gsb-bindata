#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))

describe BinData::Section do
  it "transforms data byte at a time" do
    require 'bindata/transform/xor'

    obj = BinData::Section.new(transform: -> { BinData::Transform::Xor.new(0xff) },
                               type: [:string, read_length: 5])

    _(obj.read("\x97\x9A\x93\x93\x90")).must_equal "hello"
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

require 'bindata/transform/range_coder'

describe BinData::Transform::RangeCoder do
  frequencies = [0] * 256
  frequencies[?a.ord] = 30
  frequencies[?b.ord] = 10
  frequencies[?c.ord] = 5
  frequencies[?d.ord] = 1

  build_record = lambda do |*lengths|
    table = frequencies
    Class.new(BinData::Record) do
      lengths.each_with_index do |len, i|
        section :"field#{i}", transform: -> { BinData::Transform::RangeCoder.new(len, table) } do
          string :data, read_length: len
        end
      end
    end
  end

  it "round trips data with a fixed frequency table" do
    klass = build_record.call(11)
    obj = klass.new
    obj.field0.assign("abacabadaba")

    str = obj.to_binary_s
    _(str.bytesize).must_be :<, 11
    _(klass.read(str).field0.snapshot).must_equal "abacabadaba"
  end

  it "represents empty content" do
    klass = build_record.call(0, 3)
    obj = klass.new
    obj.field0.assign("")
    obj.field1.assign("dab")

    result = klass.read(obj.to_binary_s)
    _(result.field0.snapshot).must_equal ""
    _(result.field1.snapshot).must_equal "dab"
  end

  it "stops exactly at the end of the section without reading ahead" do
    table = frequencies
    first_class = Class.new(BinData::Record) do
      section :s, transform: -> { BinData::Transform::RangeCoder.new(5, table) } do
        string :data, read_length: 5
      end
    end
    second_class = Class.new(BinData::Record) do
      section :s, transform: -> { BinData::Transform::RangeCoder.new(3, table) } do
        string :data, read_length: 3
      end
    end

    first = first_class.new
    first.s.assign("abaca")
    second = second_class.new
    second.s.assign("bad")

    # write the two encoded sections back to back
    stream = first.to_binary_s + second.to_binary_s

    # read the sections back one at a time
    io = BinData::IO.create_string_io(stream)
    read_first = first_class.read(io)
    _(read_first.s.snapshot).must_equal "abaca"

    # the first byte of the second section must not have been
    # consumed by reading the first section
    _(io.pos).must_equal first.to_binary_s.bytesize

    read_second = second_class.read(io)
    _(read_second.s.snapshot).must_equal "bad"
  end

  it "reads and writes non seekable streams" do
    rd, wr = ::IO.pipe

    klass = build_record.call(5, 3)
    obj = klass.new
    obj.field0.assign("abaca")
    obj.field1.assign("bad")
    obj.write(wr)
    wr.close

    result = klass.read(rd)
    _(result.field0.snapshot).must_equal "abaca"
    _(result.field1.snapshot).must_equal "bad"
  ensure
    rd.close
  end

  it "will not encode a symbol with zero frequency" do
    klass = build_record.call(1)
    obj = klass.new
    obj.field0.assign("z")

    _ { obj.to_binary_s }.must_raise ArgumentError
  end

  it "verifies the amount of data written matches the declared length" do
    klass = build_record.call(3)
    obj = klass.new
    obj.field0.assign("ab")

    _ { obj.to_binary_s }.must_raise IOError
  end

  it "validates the declared length" do
    _ { BinData::Transform::RangeCoder.new(-1, frequencies) }.must_raise ArgumentError
    _ { BinData::Transform::RangeCoder.new("5", frequencies) }.must_raise ArgumentError
  end

  it "validates the frequency table" do
    _ { BinData::Transform::RangeCoder.new(1, [0] * 255) }.must_raise ArgumentError
    _ { BinData::Transform::RangeCoder.new(1, [0] * 256) }.must_raise ArgumentError

    negative = [0] * 256
    negative[?a.ord] = -1
    _ { BinData::Transform::RangeCoder.new(1, negative) }.must_raise ArgumentError

    non_integer = [0] * 256
    non_integer[?a.ord] = 1.5
    _ { BinData::Transform::RangeCoder.new(1, non_integer) }.must_raise ArgumentError
  end

  it "validates the cumulative frequency precision limit" do
    limit = BinData::Transform::RangeCoder::MAX_TOTAL_FREQUENCY

    over_limit = [0] * 256
    over_limit[?a.ord] = limit + 1
    _ { BinData::Transform::RangeCoder.new(1, over_limit) }.must_raise ArgumentError

    at_limit = [0] * 256
    at_limit[?a.ord] = limit - 1
    at_limit[?b.ord] = 1

    klass = Class.new(BinData::Record) do
      section :s, transform: -> { BinData::Transform::RangeCoder.new(4, at_limit) } do
        string :data, read_length: 4
      end
    end
    obj = klass.new
    obj.s.assign("aaba")
    _(klass.read(obj.to_binary_s).s.snapshot).must_equal "aaba"
  end
end
