#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))

describe BinData::Struct, "with checksum fields" do
  class ChecksumNestedRecord < BinData::Record
    uint16le :inner_checksum, checksum: {
      range: :number,
      digest: ->(bytes) { bytes.unpack1("v") }
    }
    uint16le :number
  end
  it "calculates a header checksum from following serialized bytes" do
    klass = Class.new(BinData::Record) do
      uint32le :header_checksum, checksum: {
        range: :payload,
        algorithm: ->(bytes) { bytes.bytes.sum(0) }
      }
      uint8 :payload_length, value: -> { payload.length }
      array :payload, initial_length: :payload_length, type: :uint8
    end

    obj = klass.new
    obj.payload.assign([1, 2, 3])

    _(obj.to_binary_s).must_equal_binary "\x06\x00\x00\x00\x03\x01\x02\x03"
  end

  it "supports binary string digest fields" do
    klass = Class.new(BinData::Record) do
      string :digest, length: 4, checksum: {
        range: :payload,
        algorithm: ->(bytes) { bytes.bytesize.to_s.rjust(4, "0") }
      }
      string :payload, length: 3
    end

    binary = klass.new(payload: "abc").to_binary_s

    _(binary.byteslice(0, 4)).must_equal_binary "0003"
    klass.read(binary)
  end

  it "orders a trailing checksum after a checksum inside its range" do
    klass = Class.new(BinData::Record) do
      uint32le :header_checksum, checksum: {
        range: :payload,
        digest: ->(bytes) { bytes.bytesize }
      }
      string :payload, length: 3
      uint32le :total_checksum, checksum: {
        range: [:header_checksum, :payload],
        digest: ->(bytes) { bytes.bytesize }
      }
    end

    obj = klass.new(payload: "abc")
    binary = obj.to_binary_s

    _(binary.unpack1("V")).must_equal 3
    _(binary.byteslice(7, 4).unpack1("V")).must_equal 7
    klass.read(binary)
  end

  it "reports the mismatching range when reading" do
    klass = Class.new(BinData::Record) do
      uint32le :checksum, checksum: {
        range: :payload,
        digest: ->(bytes) { bytes.bytesize }
      }
      string :payload, length: 3
    end

    error = _ { klass.read("\x02\x00\x00\x00abc") }.must_raise BinData::ValidityError
    _(error.message).must_include "obj.checksum"
    _(error.message).must_include "payload"
  end

  it "excludes a self-referential checksum when explicitly requested" do
    klass = Class.new(BinData::Record) do
      uint32le :checksum, checksum: {
        range: [:checksum, :payload],
        self: :exclude,
        digest: ->(bytes) { bytes.bytesize }
      }
      string :payload, length: 3
    end

    binary = klass.new(payload: "abc").to_binary_s

    _(binary.unpack1("V")).must_equal 3
    klass.read(binary)
  end

  it "uses fixed filler bytes for an included self-reference" do
    klass = Class.new(BinData::Record) do
      uint32le :checksum, checksum: {
        range: [:checksum, :payload],
        self: "\x00\x00\x00\x00",
        digest: ->(bytes) { bytes.bytesize }
      }
      string :payload, length: 3
    end

    binary = klass.new(payload: "abc").to_binary_s

    _(binary.unpack1("V")).must_equal 7
    klass.read(binary)
  end

  it "encodes fixed filler field values with the checksum field type" do
    klass = Class.new(BinData::Record) do
      uint32be :checksum, checksum: {
        range: [:checksum, :payload],
        self: 0,
        digest: ->(bytes) { bytes.bytesize }
      }
      string :payload, length: 3
    end

    binary = klass.new(payload: "abc").to_binary_s

    _(binary.unpack1("N")).must_equal 7
    klass.read(binary)
  end

  it "rejects an ambiguous included self-reference" do
    error = _ {
      Class.new(BinData::Record) do
        uint32le :checksum, checksum: {
          range: [:checksum, :payload],
          digest: ->(_) { 0 }
        }
        string :payload, length: 3
      end.new.to_binary_s
    }.must_raise ArgumentError

    _(error.message).must_include "self: :exclude"
  end

  it "rejects filler bytes whose width differs from the field" do
    error = _ {
      Class.new(BinData::Record) do
        uint32le :checksum, checksum: {
          range: [:checksum, :payload],
          self: "\x00\x00\x00",
          digest: ->(_) { 0 }
        }
        string :payload, length: 3
      end.new.to_binary_s
    }.must_raise ArgumentError

    _(error.message).must_include "3 bytes"
    _(error.message).must_include "4 bytes"
  end

  it "rejects true cyclic checksum dependencies" do
    klass = Class.new(BinData::Record) do
      uint32le :primary, checksum: {
        range: [:primary, :secondary],
        self: :exclude,
        digest: ->(_) { 0 }
      }
      uint32le :secondary, checksum: {
        range: [:primary, :secondary],
        self: :exclude,
        digest: ->(_) { 0 }
      }
    end

    error = _ { klass.new.to_binary_s }.must_raise ArgumentError
    _(error.message).must_include "cyclic checksum dependencies"
    _(error.message).must_include "primary"
    _(error.message).must_include "secondary"
  end

  it "covers nested structures and dynamically sized arrays" do
    klass = Class.new(BinData::Record) do
      uint32le :outer_checksum, checksum: {
        range: [:item_count, :items],
        digest: ->(bytes) { bytes.bytesize }
      }
      uint8 :item_count, value: -> { items.length }
      array :items, initial_length: :item_count, type: :checksum_nested_record
    end

    obj = klass.new
    obj.items << { number: 0x1234 }
    obj.items << { number: 0x5678 }

    binary = obj.to_binary_s
    _(binary.bytesize).must_equal 13
    _(binary.unpack1("V")).must_equal 9
    _(binary.byteslice(7, 2).unpack1("v")).must_equal 0x1234
    _(binary.byteslice(11, 2).unpack1("v")).must_equal 0x5678
    klass.read(binary)
  end

  it "supports multiple field ranges" do
    klass = Class.new(BinData::Record) do
      uint32le :checksum, checksum: {
        range: [[:primary, :primary], [:tertiary, :tertiary]],
        self: :exclude,
        digest: ->(bytes) { bytes.bytesize }
      }
      uint8 :primary
      uint8 :second
      uint8 :tertiary
    end

    binary = klass.new(primary: 1, second: 2, tertiary: 3).to_binary_s

    _(binary.unpack1("V")).must_equal 2
    klass.read(binary)
  end

  it "ignores inactive optional checksum fields" do
    klass = Class.new(BinData::Record) do
      uint8 :kind
      uint32le :checksum,
               onlyif: -> { kind == 1 },
               checksum: { range: :payload, digest: ->(bytes) { bytes.bytesize } }
      string :payload, length: 3
    end

    binary = klass.new(kind: 0, payload: "abc").to_binary_s

    _(binary).must_equal_binary "\x00abc"
    klass.read(binary)
  end

  it "verifies ranges when reading from an unseekable stream" do
    klass = Class.new(BinData::Record) do
      uint32le :checksum,
               checksum: { range: :payload, digest: ->(bytes) { bytes.bytesize } }
      string :payload, length: 3
    end

    stream = StringIO.new("\x03\x00\x00\x00abc")
    def stream.pos
      raise NoMethodError
    end

    klass.read(stream)
  end
end
