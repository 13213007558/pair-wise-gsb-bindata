#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))
require "bigdecimal"

describe "A Posit" do
  let(:posit_class) { BinData::Posit }

  it "round trips every n=8 bit pattern" do
    (0..3).each do |exponent_size|
      (0...256).each do |bits|
        binary = posit_bytes(bits)
        value = posit_class.read(binary, n: 8, es: exponent_size)
        written = posit_class.new(value, n: 8, es: exponent_size).to_binary_s

        _(written).must_equal_binary binary
      end
    end
  end

  it "reads exact Rational values and an explicit NAR" do
    posit = posit_class.new(n: 8, es: 1)

    posit.read(posit_bytes(0))
    _(posit).must_equal 0

    posit.read(posit_bytes(0x40))
    _(posit).must_equal 1
    _(posit.snapshot).must_be_instance_of Rational

    posit.read(posit_bytes(0xc0))
    _(posit).must_equal(-1)

    posit.read(posit_bytes(0x80))
    _(posit.snapshot).must_equal BinData::Posit::NAR
  end

  it "uses the expected minpos and maxpos" do
    minpos = Rational(1, 1 << 12)
    maxpos = Rational(1 << 12)

    _(posit_class.read(posit_bytes(0x01), n: 8, es: 1)).must_equal minpos
    _(posit_class.read(posit_bytes(0xff), n: 8, es: 1)).must_equal(-minpos)
    _(posit_class.read(posit_bytes(0x7f), n: 8, es: 1)).must_equal maxpos
    _(posit_class.read(posit_bytes(0x81), n: 8, es: 1)).must_equal(-maxpos)
  end

  it "rounds to nearest with ties to even around minpos and maxpos" do
    minpos = Rational(1, 1 << 12)
    maxpos = Rational(1 << 12)

    _(posit_class.new(minpos / 2, n: 8, es: 1).to_binary_s).
      must_equal_binary posit_bytes(0x00)
    _(posit_class.new(-minpos / 2, n: 8, es: 1).to_binary_s).
      must_equal_binary posit_bytes(0x00)
    minpos_midpoint = (minpos + Rational(1, 1 << 10)) / 2
    _(posit_class.new(minpos_midpoint, n: 8, es: 1).to_binary_s).
      must_equal_binary posit_bytes(0x02)
    _(posit_class.new(-minpos_midpoint, n: 8, es: 1).to_binary_s).
      must_equal_binary posit_bytes(0xfe)

    maxpos_midpoint = (maxpos + Rational(1 << 10)) / 2
    _(posit_class.new(maxpos_midpoint, n: 8, es: 1).to_binary_s).
      must_equal_binary posit_bytes(0x7e)
    _(posit_class.new(-maxpos_midpoint, n: 8, es: 1).to_binary_s).
      must_equal_binary posit_bytes(0x82)
  end

  it "rounds every exact midpoint to the even positive code" do
    positive_codes = (1...128).to_a

    positive_codes.each_cons(2) do |lower, upper|
      lower_value = BinData::PositCodec.decode(lower, 8, 1)
      upper_value = BinData::PositCodec.decode(upper, 8, 1)
      midpoint = (lower_value + upper_value) / 2
      expected = lower.even? ? lower : upper

      _(BinData::PositCodec.encode(midpoint, 8, 1)).must_equal expected
      _(BinData::PositCodec.encode(-midpoint, 8, 1)).
        must_equal((1 << 8) - expected)
    end
  end

  it "clamps inputs beyond the finite representable range" do
    maxpos = Rational(1 << 12)
    minpos = Rational(1, 1 << 12)

    _(posit_class.new(maxpos * 2, n: 8, es: 1).to_binary_s).
      must_equal_binary posit_bytes(0x7f)
    _(posit_class.new(-maxpos * 2, n: 8, es: 1).to_binary_s).
      must_equal_binary posit_bytes(0x81)
    _(posit_class.new(Rational(3, 1 << 14), n: 8, es: 1).to_binary_s).
      must_equal_binary posit_bytes(0x01)
    _(posit_class.new(-Rational(3, 1 << 14), n: 8, es: 1).to_binary_s).
      must_equal_binary posit_bytes(0xff)
    _(posit_class.new(BigDecimal("1e10000"), n: 8, es: 1).to_binary_s).
      must_equal_binary posit_bytes(0x7f)
  end

  it "accepts integers, rationals and finite BigDecimals without Float" do
    posit = posit_class.new(BigDecimal("1.5"), n: 8, es: 1)

    _(posit.snapshot).must_equal Rational(3, 2)
    _(posit.to_binary_s).must_equal_binary posit_bytes(0x48)

    posit.assign(BigDecimal("-2.5"))
    _(posit.snapshot).must_equal Rational(-5, 2)
    _(posit.to_binary_s).must_equal_binary posit_bytes(0xac)

    posit.assign(Rational(7, 4))
    _(posit.snapshot).must_be_instance_of Rational
    _(posit.to_binary_s).must_equal_binary posit_bytes(0x4c)
  end

  it "writes NAR explicitly" do
    posit = posit_class.new(BinData::Posit::NAR, n: 8, es: 2)

    _(posit.to_binary_s).must_equal_binary posit_bytes(0x80)
  end

  it "rejects Float and non-finite BigDecimal values" do
    _ { posit_class.new(1.0, n: 8, es: 1) }.must_raise ArgumentError
    _ { posit_class.new(BigDecimal::INFINITY, n: 8, es: 1) }.
      must_raise ArgumentError
    _ { posit_class.new(BigDecimal::NAN, n: 8, es: 1) }.
      must_raise ArgumentError
  end

  it "accepts nbits as an alias for n" do
    posit = posit_class.new(1, nbits: 8, es: 1)

    _(posit.to_binary_s).must_equal_binary posit_bytes(0x40)
  end

  it "validates parameters" do
    _ { posit_class.new(1, n: 0, es: 1) }.must_raise ArgumentError
    _ { posit_class.new(1, n: 8, es: -1) }.must_raise ArgumentError
    _ { posit_class.new(1, n: 8) }.must_raise ArgumentError
  end

  class PositBitFieldRecord < BinData::Record
    endian :big

    bit3 :prefix
    posit :measurement, n: 6, es: 1
    bit7 :suffix
  end

  it "combines with ordinary bit fields and crosses byte boundaries" do
    record_class = PositBitFieldRecord

    record = record_class.new(prefix: 0b101, measurement: 1, suffix: 0b1100110)
    binary = record.to_binary_s

    _(binary).must_equal_binary posit_bytes(0b10101000, 0b01100110)

    reread = record_class.new
    reread.read(binary)
    _(reread.prefix).must_equal 0b101
    _(reread.measurement).must_equal 1
    _(reread.suffix).must_equal 0b1100110
  end

  private

  def posit_bytes(*values)
    values.pack("C*")
  end
end
