#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))
require 'bindata/transform/rans'

describe BinData::Transform::Rans do
  def rans_encode(data, **opts)
    sio = BinData::IO.create_string_io
    transform = BinData::Transform::Rans.new(0, **opts)
    transform.prepend_to_chain(BinData::IO::RawIO.new(sio))
    transform.write(data)
    transform.after_write_transform
    sio.string
  end

  def rans_decode(blob, out_length)
    transform = BinData::Transform::Rans.new(blob.bytesize)
    transform.prepend_to_chain(BinData::IO::RawIO.new(BinData::IO.create_string_io(blob)))
    out = transform.read(out_length)
    transform.after_read_transform
    out
  end

  def rans_round_trip(data, **opts)
    rans_decode(rans_encode(data, **opts), data.bytesize)
  end

  let(:freq) { { 97 => 4, 98 => 2, 99 => 1 } } # a b c

  # Fixed vectors, byte level checkable.  All use scale_bits 4, so the
  # frequency table sums to 16, and the explicit model a:4 b:2 c:1,
  # quantised to a:10 b:4 c:2.
  let(:v1) { # "abacaba", single state
    [0, 1, 4, 3, 0, 97, 10, 0, 98, 4, 0, 99, 2, 0, 16, 0, 0, 0, 7, 0, 0, 0,
     40, 110, 163, 1, 148].pack("C*")
  }
  let(:v2) { # "abacaba", two interleaved states
    [1, 2, 4, 3, 0, 97, 10, 0, 98, 4, 0, 99, 2, 0, 16, 0, 0, 0, 7, 0, 0, 0,
     54, 220, 70, 3, 124, 1, 0, 64].pack("C*")
  }
  let(:v3) { # "ab" * 50, skewed model a:15 b:1, forces renormalisation
    [0, 1, 4, 2, 0, 97, 15, 0, 98, 1, 0, 16, 0, 0, 0, 100, 0, 0, 0,
     135, 227, 153, 12,
     152, 237, 220, 101, 50, 118, 254, 169, 50, 220, 186, 67, 152, 101,
     101, 67, 84, 203, 67, 220, 220, 47, 50, 118, 203].pack("C*")
  }

  describe "block header" do
    it "records layout, states, scale bits and frequency total" do
      enc = rans_encode("abacaba".b, layout: :interleaved, states: 2,
                         scale_bits: 4, frequencies: freq)
      layout, n_states, scale_bits, n_symbols = enc.byteslice(0, 5).unpack("C3S")
      _(layout).must_equal 1
      _(n_states).must_equal 2
      _(scale_bits).must_equal 4
      _(n_symbols).must_equal 3

      table = enc.byteslice(5, 3 * n_symbols).unpack("Cv" * n_symbols)
      _(table).must_equal [97, 10, 98, 4, 99, 2]

      freq_total = enc.byteslice(5 + 3 * n_symbols, 4).unpack1("V")
      _(freq_total).must_equal 16
      _(freq_total).must_equal(1 << scale_bits)
    end

    it "is self describing so the decoder ignores constructor defaults" do
      data = "self describing block".b
      enc = rans_encode(data, layout: :interleaved, states: 3, scale_bits: 9)
      # rans_decode builds the transform with all default parameters;
      # every parameter is recovered from the block itself.
      _(rans_decode(enc, data.bytesize)).must_equal data
    end
  end

  describe "round trips" do
    it "restores data with a single state" do
      data = "the quick brown fox jumps over the lazy dog. ".b * 20
      _(rans_round_trip(data, layout: :single)).must_equal data
    end

    it "restores data with interleaved states" do
      data = "the quick brown fox jumps over the lazy dog. ".b * 20
      _(rans_round_trip(data, layout: :interleaved, states: 4)).must_equal data
    end

    it "restores empty data" do
      _(rans_round_trip("".b)).must_equal "".b
    end

    it "restores binary data spanning the whole alphabet" do
      data = Random.new(42).bytes(5000)
      _(rans_round_trip(data)).must_equal data
      _(rans_round_trip(data, layout: :interleaved, states: 8)).must_equal data
    end
  end

  describe "fixed vectors" do
    it "encodes the single state vector byte for byte" do
      enc = rans_encode("abacaba".b, scale_bits: 4, frequencies: freq)
      assert_equals_binary v1, enc
    end

    it "encodes the interleaved vector byte for byte" do
      enc = rans_encode("abacaba".b, layout: :interleaved, states: 2,
                         scale_bits: 4, frequencies: freq)
      assert_equals_binary v2, enc
    end

    it "decodes the fixed vectors" do
      _(rans_decode(v1, 7)).must_equal "abacaba".b
      _(rans_decode(v2, 7)).must_equal "abacaba".b
      _(rans_decode(v3, 100)).must_equal("ab".b * 50)
    end

    it "produces different bytes for interleaved states but the same sequence" do
      refute_equal v1, v2
      _(rans_decode(v1, 7)).must_equal rans_decode(v2, 7)
    end
  end

  describe "reverse order encoding" do
    it "encodes symbols in reverse order" do
      refute_equal rans_encode("ab".b, scale_bits: 4, frequencies: freq),
                   rans_encode("ba".b, scale_bits: 4, frequencies: freq)
    end
  end

  describe "zero frequency symbols" do
    it "fails before writing any output" do
      sio = BinData::IO.create_string_io
      transform = BinData::Transform::Rans.new(0, frequencies: { 97 => 5 })
      transform.prepend_to_chain(BinData::IO::RawIO.new(sio))
      transform.write("ab")

      _ { transform.after_write_transform }.must_raise BinData::ValidityError
      _(sio.string).must_be_empty
    end

    it "fails when the model is missing a symbol present in the input" do
      _ { rans_encode("abcd".b, frequencies: freq) }.
        must_raise BinData::ValidityError
    end
  end

  describe "state renormalisation" do
    it "emits renormalisation bytes and keeps states within 32 bits" do
      header_length = 5 + 2 * 3 + 8 + 4
      states = v3.byteslice(header_length - 4, 4).unpack("V")
      _(states.first).must_be :>=, BinData::Transform::Rans::LOWER_BOUND
      _(states.first).must_be :<, 1 << BinData::Transform::Rans::STATE_BITS
      _(v3.bytesize).must_be :>, header_length
    end

    it "round trips heavily skewed distributions" do
      data = ("a".b * 500) + ("b".b * 3) + "c".b
      _(rans_round_trip(data, scale_bits: 8)).must_equal data
    end
  end

  describe "final state recovery" do
    def corrupt_byte(blob, offset)
      blob.dup.tap { |b| b.setbyte(offset, b.getbyte(offset) ^ 0xff) }
    end

    it "rejects a corrupt final state" do
      state_offset = 5 + 3 * 3 + 8
      _ { rans_decode(corrupt_byte(v1, state_offset), 7) }.must_raise IOError
    end

    it "rejects a corrupt renormalisation byte" do
      _ { rans_decode(corrupt_byte(v3, v3.bytesize - 1), 100) }.must_raise IOError
    end

    it "rejects trailing garbage" do
      _ { rans_decode(v1 + "\x00".b, 7) }.must_raise IOError
    end

    it "rejects a truncated stream" do
      _ { rans_decode(v1.byteslice(0, v1.bytesize - 1), 7) }.must_raise IOError
    end
  end

  it "works as a section transform" do
    class RansRecord < BinData::Record
      int32le :len, value: -> { s.num_bytes }
      section :s, transform: -> {
        BinData::Transform::Rans.new(len, layout: :interleaved, states: 4)
      } do
        int32le :str_len, value: -> { str.length }
        string :str, read_length: :str_len
      end
    end

    obj = RansRecord.new
    data = "highly compressible" * 100
    obj.s.str = data
    _(obj.len).must_be :<, data.length

    str = obj.to_binary_s
    obj = RansRecord.read(str)
    _(obj.s.str).must_equal data
  end
end
