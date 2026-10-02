#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))

describe BinData::Section do
  def reed_solomon_frame(data, data_shards, parity_shards)
    require 'bindata/transform/reed_solomon'

    section = BinData::Section.new(
      transform: -> { BinData::Transform::ReedSolomon.new(data_shards, parity_shards) },
      type: [:string, read_length: data.bytesize]
    )
    section.assign(data)
    section.to_binary_s
  end

  def omit_shards(frame, positions)
    header_size = BinData::Transform::ReedSolomon::HEADER_SIZE
    header = frame.byteslice(0, header_size)
    _identifier, data_shards, parity_shards, _original_length, shard_length =
      header.unpack(BinData::Transform::ReedSolomon::HEADER_FORMAT)
    total_shards = data_shards + parity_shards
    survivors = []
    total_shards.times do |position|
      start = header_size + position * shard_length
      next if positions.include?(position)

      survivors << frame.byteslice(start, shard_length)
    end

    header + survivors.join
  end

  def read_reed_solomon(frame, data_length, positions)
    section = BinData::Section.new(
      transform: -> { BinData::Transform::ReedSolomon.new(missing_shards: positions) },
      type: [:string, read_length: data_length]
    )
    section.read(frame).snapshot
  end

  it "transforms data byte at a time" do
    require 'bindata/transform/xor'

    obj = BinData::Section.new(transform: -> { BinData::Transform::Xor.new(0xff) },
                               type: [:string, read_length: 5])

    _(obj.read("\x97\x9A\x93\x93\x90")).must_equal "hello"
  end

  it "recovers every allowed erasure pattern for small systematic GF(256) groups" do
    require 'bindata/transform/reed_solomon'

    data = "abcdefg".b
    configurations = [[1, 1], [2, 1], [3, 2], [4, 3]]
    pattern_count = 0

    configurations.each do |data_shards, parity_shards|
      frame = reed_solomon_frame(data, data_shards, parity_shards)

      (0..parity_shards).each do |count|
        (0...(data_shards + parity_shards)).to_a.combination(count).each do |positions|
          partial_frame = omit_shards(frame, positions)
          _(read_reed_solomon(partial_frame, data.bytesize, positions)).must_equal data
          pattern_count += 1
        end
      end
    end

    _(pattern_count).must_equal 87
  end

  it "uses an independent fixed GF(256) Reed-Solomon vector" do
    require 'bindata/transform/reed_solomon'

    data = [1, 2, 4, 8].pack("C4")
    frame = reed_solomon_frame(data, 2, 2)

    _(frame.byteslice(-8, 8)).must_equal [1, 2, 4, 8, 9, 18, 13, 26].pack("C8")
    _(frame.byteslice(3, 10)).must_equal [2, 2, 0, 0, 0, 4, 0, 0, 0, 2].pack("C10")

    [[0, 3], [1, 2]].each do |positions|
      _(read_reed_solomon(omit_shards(frame, positions), 4, positions)).must_equal data
    end
  end

  it "rebuilds original length and strips zero padding from the short shard" do
    require 'bindata/transform/reed_solomon'

    data = "abcdefg".b
    frame = reed_solomon_frame(data, 3, 2)
    header = frame.byteslice(0, BinData::Transform::ReedSolomon::HEADER_SIZE)

    _(header.unpack1('N', offset: 5)).must_equal 7
    _(header.unpack1('N', offset: 9)).must_equal 3
    _(frame.bytesize).must_equal 13 + 5 * 3

    positions = [2]
    _(read_reed_solomon(omit_shards(frame, positions), 7, positions)).must_equal data
  end

  it "rebuilds empty data and rejects erasures without parity capacity" do
    require 'bindata/transform/reed_solomon'

    empty_frame = reed_solomon_frame("".b, 2, 0)
    _(empty_frame).must_equal "RS1".b + [2, 0, 0, 0, 0, 0, 0, 0, 0, 0].pack("C2N2")
    _(read_reed_solomon(empty_frame, 0, [])).must_equal "".b

    _{ read_reed_solomon(empty_frame, 0, [0]) }.
      must_raise IOError, /cannot recover 1 erasures with 0 parity shards/
  end

  it "does not return partially reconstructed data beyond erasure capacity" do
    require 'bindata/transform/reed_solomon'

    data = "abcdefg".b
    frame = reed_solomon_frame(data, 3, 2)
    positions = [0, 1, 2]

    _{ read_reed_solomon(omit_shards(frame, positions), 7, positions) }.
      must_raise IOError, /cannot recover 3 erasures with 2 parity shards/
  end

  it "rejects inconsistent surviving shards instead of performing error correction" do
    require 'bindata/transform/reed_solomon'

    data = "abcdefg".b
    frame = reed_solomon_frame(data, 3, 2)
    header_size = BinData::Transform::ReedSolomon::HEADER_SIZE
    corrupted = frame.dup
    corrupted.setbyte(header_size + 3 * 3, corrupted.getbyte(header_size + 3 * 3) ^ 1)

    _{ read_reed_solomon(corrupted, 7, []) }.
      must_raise IOError, "Reed-Solomon parity verification failed"
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
