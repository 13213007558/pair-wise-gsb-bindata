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
  class RangeCodedRecord < BinData::Record
    FREQ_TABLE = {
      'h'.ord => 3, 'e'.ord => 2, 'l'.ord => 5, 'o'.ord => 4,
      'w'.ord => 2, 'r'.ord => 1, 'd'.ord => 1, ' '.ord => 2,
    }

    uint8 :data_length, value: -> { coded.length }
    section :coded, transform: -> { BinData::Transform::RangeCoder.new(FREQ_TABLE, data_length) },
                    type: [:string, read_length: :data_length]
  end

  class TwoRangeCodedRecords < BinData::Record
    FREQ_TABLE = RangeCodedRecord::FREQ_TABLE

    uint8 :len1, value: -> { s1.length }
    section :s1, transform: -> { BinData::Transform::RangeCoder.new(FREQ_TABLE, len1) },
                 type: [:string, read_length: :len1]
    uint8 :len2, value: -> { s2.length }
    section :s2, transform: -> { BinData::Transform::RangeCoder.new(FREQ_TABLE, len2) },
                 type: [:string, read_length: :len2]
  end

  it "encodes and decodes with a fixed frequency table" do
    obj = RangeCodedRecord.new
    obj.coded = "hello world"
    _(obj.value_read_from_written.coded).must_equal "hello world"
  end

  it "round trips arbitrary binary data" do
    table = Array.new(256, 1)
    data = (0..255).to_a.pack('C*')
    new_section = -> {
      BinData::Section.new(transform: -> { BinData::Transform::RangeCoder.new(table, 256) },
                           type: [:string, read_length: 256])
    }
    obj = new_section.call
    obj.assign(data)
    _(new_section.call.read(obj.to_binary_s)).must_equal data
  end

  it "refuses to encode a byte with zero frequency" do
    obj = RangeCodedRecord.new
    obj.coded = "hello world!"
    _ { obj.to_binary_s }.must_raise ArgumentError
  end

  it "validates the cumulative frequency precision limit" do
    _ { BinData::Transform::RangeCoder.new(Array.new(256, 300), 1) }.must_raise ArgumentError
    _ { BinData::Transform::RangeCoder.new({ 97 => 65_537 }, 1) }.must_raise ArgumentError
  end

  it "validates the frequency table" do
    _ { BinData::Transform::RangeCoder.new({ 97 => -1 }, 1) }.must_raise ArgumentError
    _ { BinData::Transform::RangeCoder.new({ 256 => 1 }, 1) }.must_raise ArgumentError
    _ { BinData::Transform::RangeCoder.new({ 97 => 1.5 }, 1) }.must_raise ArgumentError
    _ { BinData::Transform::RangeCoder.new(Array.new(255, 1), 1) }.must_raise ArgumentError
    _ { BinData::Transform::RangeCoder.new("not a table", 1) }.must_raise ArgumentError
    _ { BinData::Transform::RangeCoder.new({}, 1) }.must_raise ArgumentError
    _ { BinData::Transform::RangeCoder.new({ 97 => 1 }, -1) }.must_raise ArgumentError
  end

  it "represents empty content" do
    obj = RangeCodedRecord.new
    obj.coded = ""
    str = obj.to_binary_s
    _(str.size).must_equal 1
    _(RangeCodedRecord.read(str).coded).must_equal ""
  end

  it "reads back to back sections without consuming the next section" do
    obj = TwoRangeCodedRecords.new
    obj.s1 = "hello"
    obj.s2 = "world"
    str = obj.to_binary_s

    io = BinData::IO.create_string_io(str)
    read_obj = TwoRangeCodedRecords.read(io)
    _(read_obj.s1).must_equal "hello"
    _(read_obj.s2).must_equal "world"
    _(io.pos).must_equal str.size
  end

  it "reads consecutive sections one at a time from the one stream" do
    obj1 = RangeCodedRecord.new
    obj1.coded = "hello"
    obj2 = RangeCodedRecord.new
    obj2.coded = "world"
    str = obj1.to_binary_s + obj2.to_binary_s

    io = BinData::IO::Read.new(BinData::IO.create_string_io(str))
    read1 = RangeCodedRecord.new.read(io)
    read2 = RangeCodedRecord.new.read(io)
    _(read1.coded).must_equal "hello"
    _(read2.coded).must_equal "world"
  end

  it "stops decoding at the end of the section" do
    obj = RangeCodedRecord.new
    obj.coded = "hello"
    str = obj.to_binary_s + "TRAILING"

    io = BinData::IO.create_string_io(str)
    read_obj = RangeCodedRecord.read(io)
    _(read_obj.coded).must_equal "hello"
    _(io.pos).must_equal str.size - 8
  end

  it "reads and writes on unseekable streams" do
    obj = TwoRangeCodedRecords.new
    obj.s1 = "hello"
    obj.s2 = "world"

    rd, wr = IO.pipe
    obj.write(wr)
    wr.close

    read_obj = TwoRangeCodedRecords.read(rd)
    _(read_obj.s1).must_equal "hello"
    _(read_obj.s2).must_equal "world"
    rd.close
  end
end
