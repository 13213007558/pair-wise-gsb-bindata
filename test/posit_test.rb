#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))
require 'bigdecimal'

describe "Posit fields" do
  it "reads every n=8 bit pattern as Rational or NaR for several es values" do
    (0..3).each do |es|
      (0...256).each do |pattern|
        field = BinData::Posit.new(n: 8, es: es)
        field.read(pattern.chr)

        if pattern == 0x80
          _(field.snapshot).must_equal BinData::Posit::NAR
          _(field.to_binary_s).must_equal_binary pattern.chr
        else
          _(field.snapshot).must_be_instance_of Rational
          _(field.to_binary_s).must_equal_binary pattern.chr
        end
      end
    end
  end

  it "decodes zero and NaR explicitly" do
    field = BinData::Posit.new(n: 8, es: 2)

    field.read("\x00")
    _(field.snapshot).must_equal Rational(0, 1)
    _(field.snapshot).must_be_instance_of Rational

    field.read("\x80")
    _(field.snapshot).must_equal BinData::Posit::NAR
  end

  it "writes NaR and accepts it as an initial value" do
    field = BinData::Posit.new(n: 8, es: 2, initial_value: BinData::Posit::NAR)
    _(field.to_binary_s).must_equal_binary "\x80"

    field.assign(:NaR)
    _(field.snapshot).must_equal BinData::Posit::NAR
    _(field.to_binary_s).must_equal_binary "\x80"
  end

  it "normalizes assigned integers, rationals and finite BigDecimals to Rational" do
    field = BinData::Posit.new(n: 8, es: 0)

    field.assign(1)
    _(field.snapshot).must_equal Rational(1, 1)
    _(field.snapshot).must_be_instance_of Rational

    field.assign(Rational(33, 32))
    _(field.snapshot).must_equal Rational(33, 32)

    field.assign(BigDecimal("1.03125"))
    _(field.snapshot).must_equal Rational(33, 32)
  end

  it "copies exact values from another Posit field" do
    source = BinData::Posit.new(n: 8, es: 0)
    source.assign(Rational(33, 32))

    target = BinData::Posit.new(n: 8, es: 0)
    target.assign(source)
    _(target.snapshot).must_equal Rational(33, 32)
  end

  it "rounds finite midpoint values to nearest with ties to even" do
    field = BinData::Posit.new(n: 8, es: 0)

    field.assign(Rational(65, 64))
    _(field.to_binary_s).must_equal_binary 0x40.chr

    field.assign(Rational(67, 64))
    _(field.to_binary_s).must_equal_binary 0x42.chr

    field.assign(-Rational(65, 64))
    _(field.to_binary_s).must_equal_binary 0xc0.chr

    field.assign(-Rational(67, 64))
    _(field.to_binary_s).must_equal_binary 0xbe.chr

    field.assign(BigDecimal("0.0078125"))
    _(field.to_binary_s).must_equal_binary "\x00"

    field.assign(-BigDecimal("0.0078125"))
    _(field.to_binary_s).must_equal_binary "\x00"

    field.assign(BigDecimal("0.00781250001"))
    _(field.to_binary_s).must_equal_binary "\x01"

    field.assign(-BigDecimal("0.00781250001"))
    _(field.to_binary_s).must_equal_binary "\xff"
  end

  it "rounds every adjacent n=8 midpoint with ties to even" do
    (0..3).each do |es|
      values = {}

      (0...256).each do |pattern|
        value = BinData::Posit.decode(pattern, 8, es)
        values[pattern] = value unless value.equal?(BinData::Posit::NAR)
      end

      positive_patterns = (1...128).to_a
      midpoint_pairs = [[0, positive_patterns.first]] + positive_patterns.each_cons(2).to_a

      midpoint_pairs.each do |low, high|
        midpoint = low.zero? ? values[high] / 2 : (values[low] + values[high]) / 2
        expected = low.even? ? low : high
        negative_expected = expected.zero? ? 0 : 256 - expected

        _(BinData::Posit.encode(midpoint, 8, es)).must_equal expected
        _(BinData::Posit.encode(-midpoint, 8, es)).must_equal negative_expected
      end
    end
  end

  it "saturates inputs outside the finite representable range" do
    field = BinData::Posit.new(n: 8, es: 2)
    minpos = BinData::Posit.decode(0x01, 8, 2)
    maxpos = BinData::Posit.decode(0x7f, 8, 2)

    field.assign(minpos)
    _(field.to_binary_s).must_equal_binary "\x01"
    field.assign(-minpos)
    _(field.to_binary_s).must_equal_binary "\xff"

    field.assign(maxpos)
    _(field.to_binary_s).must_equal_binary "\x7f"
    field.assign(-maxpos)
    _(field.to_binary_s).must_equal_binary "\x81"

    field.assign(maxpos * 2)
    _(field.to_binary_s).must_equal_binary "\x7f"
    field.assign(-maxpos * 2)
    _(field.to_binary_s).must_equal_binary "\x81"

    field.assign(minpos / Rational(4, 1))
    _(field.to_binary_s).must_equal_binary "\x00"
    field.assign(-minpos / Rational(4, 1))
    _(field.to_binary_s).must_equal_binary "\x00"
  end

  it "rejects Float and non-finite BigDecimal input without Float conversion" do
    field = BinData::Posit.new(n: 8, es: 2)

    _ { field.assign(1.0) }.must_raise ArgumentError
    _ { field.assign(BigDecimal::NAN) }.must_raise ArgumentError
    _ { field.assign(BigDecimal::INFINITY) }.must_raise ArgumentError
    _ { field.assign(-BigDecimal::INFINITY) }.must_raise ArgumentError
    _ { field.assign("1") }.must_raise ArgumentError
  end

  it "can use nbits as an alias for n" do
    field = BinData::Posit.new(nbits: 8, es: 2)
    field.assign(Rational(1, 1))
    _(field.to_binary_s).must_equal_binary "\x40"
  end

  it "validates n and es" do
    _ { BinData::Posit.new(n: 1, es: 0) }.must_raise ArgumentError
    _ { BinData::Posit.new(n: 8, es: -1) }.must_raise ArgumentError
    _ { BinData::Posit.new(es: 0) }.must_raise ArgumentError
    _ { BinData::Posit.new(n: 8, nbits: 8) }.must_raise ArgumentError
  end

  it "combines with ordinary bit fields before and after it" do
    packet_class = Class.new(BinData::Record) do
      bit3 :pre
      posit :p, n: 8, es: 2
      bit5 :post
    end

    packet = packet_class.new
    packet.pre = 0b101
    packet.p = Rational(1, 1)
    packet.post = 0b10010

    bytes = "\xA8\x12".b
    _(packet.to_binary_s).must_equal_binary bytes
    _(packet.num_bytes).must_equal 2

    read = packet_class.read(bytes)
    _(read.pre).must_equal 0b101
    _(read.p).must_equal Rational(1, 1)
    _(read.post).must_equal 0b10010
  end
end
