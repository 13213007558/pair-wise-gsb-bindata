#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))

module ChecksumTestAlgo
  SUM8 = ->(data) { (data.bytes.sum % 256).chr }
  FIRST_BYTE = ->(data) { data[0] || "\x00" }
end

class ChecksumTestSum8Digest
  def self.digest(data)
    (data.bytes.sum % 256).chr
  end
end

describe BinData::Checksum do
  let(:sum8) { ChecksumTestAlgo::SUM8 }

  def new_record(&block)
    Class.new(BinData::Record, &block)
  end

  it "computes the digest over a range of fields when writing" do
    algo = sum8
    klass = new_record do
      uint8 :a, initial_value: 1
      uint8 :b, initial_value: 2
      checksum :s, algorithm: algo, over: :a..:b
    end

    _(klass.new.to_binary_s).must_equal_binary "\x01\x02\x03"
  end

  it "covers fields that are declared after the checksum" do
    algo = sum8
    klass = new_record do
      checksum :s, algorithm: algo, over: :a..:b
      uint8 :a, initial_value: 1
      uint8 :b, initial_value: 2
    end

    _(klass.new.to_binary_s).must_equal_binary "\x03\x01\x02"
  end

  it "recomputes the digest when covered values change" do
    algo = sum8
    klass = new_record do
      uint8 :a, initial_value: 1
      uint8 :b, initial_value: 2
      checksum :s, algorithm: algo, over: :a..:b
    end

    obj = klass.new
    obj.a = 5
    _(obj.to_binary_s).must_equal_binary "\x05\x02\x07"
  end

  it "reads and verifies the digest" do
    algo = sum8
    klass = new_record do
      uint8 :a
      uint8 :b
      checksum :s, algorithm: algo, over: :a..:b
    end

    obj = klass.read("\x01\x02\x03")
    _(obj.a).must_equal 1
    _(obj.s.snapshot).must_equal_binary "\x03"
  end

  it "reports the checksum field and its range on mismatch" do
    algo = sum8
    klass = new_record do
      uint8 :a
      uint8 :b
      checksum :s, algorithm: algo, over: :a..:b
    end

    ex = _ { klass.read("\x01\x02\x04") }.must_raise BinData::ValidityError
    _(ex.message).must_match(/checksum mismatch for obj\.s/)
    _(ex.message).must_match(/:a\.\.:b/)
  end

  it "accepts a single field name" do
    algo = sum8
    klass = new_record do
      uint8 :a, initial_value: 1
      uint8 :b, initial_value: 2
      checksum :s, algorithm: algo, over: :b
    end

    _(klass.new.to_binary_s).must_equal_binary "\x01\x02\x02"
  end

  it "accepts a list of field names in the given order" do
    algo = ChecksumTestAlgo::FIRST_BYTE
    klass = new_record do
      uint8 :a, initial_value: 1
      uint8 :b, initial_value: 2
      checksum :s, algorithm: algo, over: [:b, :a]
    end

    _(klass.new.to_binary_s).must_equal_binary "\x01\x02\x02"
  end

  it "accepts an exclusive range" do
    algo = sum8
    klass = new_record do
      uint8 :a, initial_value: 1
      uint8 :b, initial_value: 2
      checksum :s, algorithm: algo, over: :a...:b
    end

    _(klass.new.to_binary_s).must_equal_binary "\x01\x02\x01"
  end

  it "covers anonymous fields inside a range" do
    algo = sum8
    klass = new_record do
      uint8 :a, initial_value: 1
      uint8 "", initial_value: 10
      uint8 :b, initial_value: 2
      checksum :s, algorithm: algo, over: :a..:b
    end

    _(klass.new.to_binary_s).must_equal_binary "\x01\x0a\x02\x0d"
  end

  it "accepts an algorithm object that responds to digest" do
    klass = new_record do
      uint8 :a, initial_value: 1
      uint8 :b, initial_value: 2
      checksum :s, algorithm: ChecksumTestSum8Digest, over: :a..:b
    end

    _(klass.new.to_binary_s).must_equal_binary "\x01\x02\x03"
  end

  it "rejects an algorithm that is not callable" do
    _ {
      new_record do
        uint8 :a
        checksum :s, algorithm: 5, over: :a
      end
    }.must_raise ArgumentError
  end

  it "rejects an algorithm with a variable length digest" do
    klass = new_record do
      uint8 :a
      checksum :s, algorithm: ->(data) { data }, over: :a
    end

    _ { klass.new.to_binary_s }.must_raise ArgumentError
  end

  it "rejects unknown fields in the covered range" do
    algo = sum8
    klass = new_record do
      uint8 :a
      checksum :s, algorithm: algo, over: :a..:nope
    end

    ex = _ { klass.new }.must_raise ArgumentError
    _(ex.message).must_match(/unknown field/)
  end

  it "rejects a range whose end precedes its start" do
    algo = sum8
    klass = new_record do
      uint8 :a
      uint8 :b
      checksum :s, algorithm: algo, over: :b..:a
    end

    _ { klass.new }.must_raise ArgumentError
  end

  it "rejects an empty list of fields" do
    algo = sum8
    _ {
      new_record do
        uint8 :a
        checksum :s, algorithm: algo, over: []
      end
    }.must_raise ArgumentError
  end

  it "rejects a range that does not contain field names" do
    algo = sum8
    _ {
      new_record do
        uint8 :a
        checksum :s, algorithm: algo, over: 5
      end
    }.must_raise ArgumentError
  end

  it "rejects an algorithm that does not return a string" do
    klass = new_record do
      uint8 :a
      checksum :s, algorithm: ->(_data) { 5 }, over: :a
    end

    _ { klass.new.to_binary_s }.must_raise ArgumentError
  end

  it "must be declared inside a record" do
    obj = BinData::Checksum.new(algorithm: sum8, over: :a)

    _ { obj.to_binary_s }.must_raise ArgumentError
  end

  it "reports a mismatch against a list of fields" do
    algo = sum8
    klass = new_record do
      uint8 :a
      uint8 :b
      checksum :s, algorithm: algo, over: [:a, :b]
    end

    ex = _ { klass.read("\x01\x02\x04") }.must_raise BinData::ValidityError
    _(ex.message).must_match(/:a, :b/)
  end

  it "is clear before being read" do
    algo = sum8
    klass = new_record do
      uint8 :a
      checksum :s, algorithm: algo, over: :a
    end

    obj = klass.read("\x01\x01")
    _(obj.s.clear?).must_equal false
    obj.clear
    _(obj.s.clear?).must_equal true
  end

  it "detects re-entrant digest computation" do
    obj = nil
    algo = ->(data) { obj.s.snapshot if data.bytesize > 1; "\x00" }
    klass = new_record do
      uint8 :a, initial_value: 1
      uint8 :b, initial_value: 2
      checksum :s, algorithm: algo, over: :a..:b
    end

    obj = klass.new
    _ { obj.to_binary_s }.must_raise ArgumentError
  end

  it "includes the digest length in num_bytes" do
    algo = sum8
    klass = new_record do
      uint8 :a
      uint8 :b
      checksum :s, algorithm: algo, over: :a..:b
    end

    _(klass.new.num_bytes).must_equal 3
  end

  it "exposes the computed digest through snapshot" do
    algo = sum8
    klass = new_record do
      uint8 :a, initial_value: 1
      uint8 :b, initial_value: 2
      checksum :s, algorithm: algo, over: :a..:b
    end

    _(klass.new.snapshot.s).must_equal_binary "\x03"
  end

  it "round trips a record" do
    algo = sum8
    klass = new_record do
      uint8 :a, initial_value: 1
      uint8 :b, initial_value: 2
      checksum :s, algorithm: algo, over: :a..:b
    end

    obj = klass.new
    _(obj.value_read_from_written.to_binary_s).must_equal_binary obj.to_binary_s
  end

  it "works as a field of an anonymous struct" do
    algo = sum8
    obj = BinData::Struct.new(fields: [[:uint8, :a, { initial_value: 1 }],
                                       [:checksum, :s, { algorithm: algo, over: :a }]])

    _(obj.to_binary_s).must_equal_binary "\x01\x01"
  end

  describe "with nested structures" do
    it "covers the exact serialized bytes of nested structs" do
      algo = sum8
      klass = new_record do
        endian :little
        struct :n do
          uint8  :x, initial_value: 1
          uint16 :y, initial_value: 0x0203
        end
        checksum :s, algorithm: algo, over: :n
      end

      # digest covers 01 03 02 (little endian)
      _(klass.new.to_binary_s).must_equal_binary "\x01\x03\x02\x06"
    end

    it "covers the exact serialized bytes of dynamic arrays" do
      algo = sum8
      klass = new_record do
        uint8 :len, value: -> { data.length }
        array :data, type: :uint8, initial_length: :len
        checksum :s, algorithm: algo, over: :len..:data
      end

      obj = klass.new(data: [1, 2, 3])
      _(obj.to_binary_s).must_equal_binary "\x03\x01\x02\x03\x09"

      obj.data = [5]
      _(obj.to_binary_s).must_equal_binary "\x01\x05\x06"

      _(klass.read("\x03\x01\x02\x03\x09").data.snapshot).must_equal [1, 2, 3]
      _ { klass.read("\x03\x01\x02\x03\x08") }.must_raise BinData::ValidityError
    end

    it "verifies checksums declared inside nested structs" do
      algo = sum8
      klass = new_record do
        uint8 :tag
        struct :n do
          uint8 :x
          checksum :s, algorithm: algo, over: :x
        end
      end

      obj = klass.read("\x09\x05\x05")
      _(obj.n.x).must_equal 5

      ex = _ { klass.read("\x09\x05\x06") }.must_raise BinData::ValidityError
      _(ex.message).must_match(/obj\.n\.s/)
    end
  end

  describe "with conditional fields" do
    it "excludes fields that are not included from the digest" do
      algo = sum8
      klass = new_record do
        uint8 :flag, initial_value: 0
        uint8 :opt, onlyif: -> { flag == 1 }, initial_value: 7
        checksum :s, algorithm: algo, over: :flag..:opt
      end

      obj = klass.new
      _(obj.to_binary_s).must_equal_binary "\x00\x00"

      obj.flag = 1
      _(obj.to_binary_s).must_equal_binary "\x01\x07\x08"

      klass.read("\x00\x00")
      klass.read("\x01\x07\x08")
      _ { klass.read("\x01\x07\x09") }.must_raise BinData::ValidityError
    end
  end

  describe "covering other checksums" do
    it "computes chained checksums in dependency order when writing" do
      algo = sum8
      klass = new_record do
        endian :little
        uint16   :magic, initial_value: 0x4D47
        uint8    :body_len, value: -> { body.length }
        checksum :body_sum, algorithm: algo, over: :body
        string   :body, read_length: :body_len
        checksum :file_sum, algorithm: algo, over: :magic..:body
      end

      obj = klass.new(body: "hello")
      expected = [0x47, 0x4d, 5, 20, *"hello".bytes, 193].pack("C*")
      _(obj.to_binary_s).must_equal_binary expected

      read_back = klass.read(expected)
      _(read_back.body).must_equal "hello"
    end

    it "reports which range mismatched when reading chained checksums" do
      algo = sum8
      klass = new_record do
        endian :little
        uint16   :magic, initial_value: 0x4D47
        uint8    :body_len, value: -> { body.length }
        checksum :body_sum, algorithm: algo, over: :body
        string   :body, read_length: :body_len
        checksum :file_sum, algorithm: algo, over: :magic..:body
      end

      bin = klass.new(body: "hello").to_binary_s

      corrupt_body = bin.dup
      corrupt_body.setbyte(5, corrupt_body.getbyte(5) ^ 0xff)
      ex = _ { klass.read(corrupt_body) }.must_raise BinData::ValidityError
      _(ex.message).must_match(/body_sum/)

      corrupt_trailer = bin.dup
      corrupt_trailer.setbyte(-1, corrupt_trailer.getbyte(-1) ^ 0xff)
      ex = _ { klass.read(corrupt_trailer) }.must_raise BinData::ValidityError
      _(ex.message).must_match(/file_sum/)
    end

    it "rejects dependency cycles between checksums" do
      algo = sum8
      klass = new_record do
        checksum :sa, algorithm: algo, over: [:sb]
        checksum :sb, algorithm: algo, over: [:sa]
      end

      ex = _ { klass.new }.must_raise ArgumentError
      _(ex.message).must_match(/dependency cycle/)
    end

    it "rejects longer dependency cycles" do
      algo = sum8
      klass = new_record do
        checksum :sa, algorithm: algo, over: [:sb]
        checksum :sb, algorithm: algo, over: [:sc]
        checksum :sc, algorithm: algo, over: [:sa]
      end

      _ { klass.new }.must_raise ArgumentError
    end

    it "accepts acyclic checksum chains" do
      algo = sum8
      klass = new_record do
        uint8 :x, initial_value: 1
        checksum :sa, algorithm: algo, over: :x
        checksum :sb, algorithm: algo, over: :sa
        checksum :sc, algorithm: algo, over: :sb
      end

      # sa = sum(1) = 1, sb = sum(1) = 1, sc = sum(1) = 1
      _(klass.new.to_binary_s).must_equal_binary "\x01\x01\x01\x01"
    end
  end

  describe "covering itself" do
    it "rejects ambiguous self coverage" do
      algo = sum8
      klass = new_record do
        uint8 :a
        checksum :s, algorithm: algo, over: :a..:b
        uint8 :b
      end

      ex = _ { klass.new }.must_raise ArgumentError
      _(ex.message).must_match(/covers itself/)
    end

    it "excludes itself from the digest with exclude_self" do
      algo = sum8
      klass = new_record do
        uint8 :a, initial_value: 1
        checksum :s, algorithm: algo, over: :a..:b, exclude_self: true
        uint8 :b, initial_value: 3
      end

      # digest covers 01 03
      _(klass.new.to_binary_s).must_equal_binary "\x01\x04\x03"
      klass.read("\x01\x04\x03")
      _ { klass.read("\x01\x05\x03") }.must_raise BinData::ValidityError
    end

    it "contributes a fixed fill value with fill" do
      algo = sum8
      klass = new_record do
        uint8 :a, initial_value: 1
        checksum :s, algorithm: algo, over: :a..:b, fill: "\x05"
        uint8 :b, initial_value: 3
      end

      # digest covers 01 05 03
      _(klass.new.to_binary_s).must_equal_binary "\x01\x09\x03"
      klass.read("\x01\x09\x03")
      _ { klass.read("\x01\x0a\x03") }.must_raise BinData::ValidityError
    end

    it "rejects fill that does not match the digest length" do
      algo = sum8
      klass = new_record do
        uint8 :a
        checksum :s, algorithm: algo, over: :a..:s, fill: "\x00\x00"
      end

      _ { klass.new.to_binary_s }.must_raise ArgumentError
    end

    it "rejects exclude_self combined with fill" do
      algo = sum8
      _ {
        new_record do
          uint8 :a
          checksum :s, algorithm: algo, over: :a, exclude_self: true, fill: "\x00"
        end
      }.must_raise ArgumentError
    end

    it "rejects a fill that is not a string" do
      algo = sum8
      _ {
        new_record do
          uint8 :a
          checksum :s, algorithm: algo, over: :a, fill: 5
        end
      }.must_raise ArgumentError
    end
  end
end
