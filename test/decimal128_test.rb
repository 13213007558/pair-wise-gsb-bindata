#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))
require 'bigdecimal'


describe "BinData::Decimal128 DPD codec" do
  # Hand-computed from the DPD compression table in IEEE 754-2008.
  it "encodes declets per the published DPD table" do
    _(BinData::Decimal128.dpd_encode(0, 0, 0)).must_equal 0x000
    _(BinData::Decimal128.dpd_encode(0, 0, 5)).must_equal 0x005
    _(BinData::Decimal128.dpd_encode(0, 0, 9)).must_equal 0x009
    _(BinData::Decimal128.dpd_encode(0, 9, 0)).must_equal 0x01A
    _(BinData::Decimal128.dpd_encode(9, 0, 0)).must_equal 0x08C
    _(BinData::Decimal128.dpd_encode(1, 2, 3)).must_equal 0x0A3
    _(BinData::Decimal128.dpd_encode(9, 9, 9)).must_equal 0x0FF
    _(BinData::Decimal128.dpd_encode(3, 9, 5)).must_equal 0x1DB
    _(BinData::Decimal128.dpd_encode(9, 3, 5)).must_equal 0x2BD
    _(BinData::Decimal128.dpd_encode(9, 9, 5)).must_equal 0x2DF
    _(BinData::Decimal128.dpd_encode(3, 9, 9)).must_equal 0x19F
    _(BinData::Decimal128.dpd_encode(9, 3, 9)).must_equal 0x1BF
  end

  it "decodes declets per the published DPD table" do
    _(BinData::Decimal128.dpd_decode(0x000)).must_equal [0, 0, 0]
    _(BinData::Decimal128.dpd_decode(0x005)).must_equal [0, 0, 5]
    _(BinData::Decimal128.dpd_decode(0x01A)).must_equal [0, 9, 0]
    _(BinData::Decimal128.dpd_decode(0x08C)).must_equal [9, 0, 0]
    _(BinData::Decimal128.dpd_decode(0x0A3)).must_equal [1, 2, 3]
    _(BinData::Decimal128.dpd_decode(0x0FF)).must_equal [9, 9, 9]
    _(BinData::Decimal128.dpd_decode(0x1DB)).must_equal [3, 9, 5]
    _(BinData::Decimal128.dpd_decode(0x2BD)).must_equal [9, 3, 5]
    _(BinData::Decimal128.dpd_decode(0x2DF)).must_equal [9, 9, 5]
    _(BinData::Decimal128.dpd_decode(0x19F)).must_equal [3, 9, 9]
    _(BinData::Decimal128.dpd_decode(0x1BF)).must_equal [9, 3, 9]
  end

  it "round trips all 1000 canonical declets" do
    1000.times do |n|
      digits = [n / 100, (n / 10) % 10, n % 10]
      _(BinData::Decimal128.dpd_decode(BinData::Decimal128.dpd_encode(*digits))).must_equal digits
    end
  end

  it "encodes 1000 distinct canonical declets" do
    encodings = (0...1000).map { |n| BinData::Decimal128.dpd_encode(n / 100, (n / 10) % 10, n % 10) }
    _(encodings.uniq.length).must_equal 1000
  end

  it "decodes every 10 bit pattern to valid digits" do
    1024.times do |declet|
      digits = BinData::Decimal128.dpd_decode(declet)
      _(digits.length).must_equal 3
      digits.each { |d| _(d.between?(0, 9)).must_equal true }
    end
  end
end

describe "BinData::Decimal128 quantum preservation" do

  it "keeps 1.20 and 1.2 as distinct representations" do
    v120 = BinData::Decimal128.decode(BinData::Decimal128.encode("1.20").first)
    v12 = BinData::Decimal128.decode(BinData::Decimal128.encode("1.2").first)
    _(v120.coefficient).must_equal 120
    _(v120.exponent).must_equal(-2)
    _(v12.coefficient).must_equal 12
    _(v12.exponent).must_equal(-1)
    _(v120.same_representation?(v12)).must_equal false
    _(v120).must_equal v12   # numerically equal
    _(v120.to_s).must_equal "1.20"
    _(v12.to_s).must_equal "1.2"
  end

  it "preserves the quantum of zero" do
    value = BinData::Decimal128.decode(BinData::Decimal128.encode("0.00").first)
    _(value.coefficient).must_equal 0
    _(value.exponent).must_equal(-2)
    _(value.to_s).must_equal "0.00"
  end

  it "does not normalise trailing zeros on decode" do
    value = BinData::Decimal128.decode(BinData::Decimal128.encode("1.2300E+5").first)
    _(value.coefficient).must_equal 12300
    _(value.exponent).must_equal 1
  end
end

describe "BinData::Decimal128 rounding" do

  # Expected results computed independently with IEEE 754 decimal128
  # arithmetic (34 digit precision, Emin -6143, Emax 6144).
  ROUNDING_CASES = [
    # [input, round_mode, expected coefficient, expected exponent]
    ["1234567890123456789012345678901234.5", :half_even, 1234567890123456789012345678901234, 0],
    ["1234567890123456789012345678901234.5", :half_up,   1234567890123456789012345678901235, 0],
    ["1234567890123456789012345678901234.5", :half_down, 1234567890123456789012345678901234, 0],
    ["1234567890123456789012345678901234.5", :down,     1234567890123456789012345678901234, 0],
    ["1234567890123456789012345678901234.5", :up,       1234567890123456789012345678901235, 0],
    ["1234567890123456789012345678901234.5", :ceiling,  1234567890123456789012345678901235, 0],
    ["1234567890123456789012345678901234.5", :floor,    1234567890123456789012345678901234, 0],
    ["1234567890123456789012345678901233.5", :half_even, 1234567890123456789012345678901234, 0],
    ["1234567890123456789012345678901234.50001", :half_even, 1234567890123456789012345678901235, 0],
    ["-1234567890123456789012345678901234.5", :half_even, -1234567890123456789012345678901234, 0],
    ["-1234567890123456789012345678901234.5", :ceiling,  -1234567890123456789012345678901234, 0],
    ["-1234567890123456789012345678901234.5", :floor,    -1234567890123456789012345678901235, 0],
    ["-1234567890123456789012345678901234.5", :up,       -1234567890123456789012345678901235, 0],
    ["9999999999999999999999999999999999.5", :half_even, 1000000000000000000000000000000000, 1],
    ["9999999999999999999999999999999999.5", :down,      9999999999999999999999999999999999, 0],
    ["1.23456789012345678901234567890123456789", :half_even, 1234567890123456789012345678901235, -33],
  ]

  it "rounds the coefficient according to the caller selected mode" do
    ROUNDING_CASES.each do |str, mode, expected_coeff, expected_exp|
      bits, status = BinData::Decimal128.encode(str, round_mode: mode)
      value = BinData::Decimal128.decode(bits)
      signed_coeff = value.sign * value.coefficient
      _(signed_coeff).must_equal expected_coeff, "#{str} (#{mode}) coefficient"
      _(value.exponent).must_equal expected_exp, "#{str} (#{mode}) exponent"
      _(status.inexact?).must_equal true
      _(status.rounded?).must_equal true
    end
  end

  it "rejects an unknown rounding mode" do
    _(proc { BinData::Decimal128.encode("1.5", round_mode: :bankers) }).must_raise ArgumentError
  end

  it "reports no flags for exact encodings" do
    _bits, status = BinData::Decimal128.encode("1.20")
    _(status.empty?).must_equal true
  end
end

describe "BinData::Decimal128 exponent range handling" do

  it "clamps large exponents by shifting the coefficient" do
    bits, status = BinData::Decimal128.encode("1E+6112")
    value = BinData::Decimal128.decode(bits)
    _(value.coefficient).must_equal 10
    _(value.exponent).must_equal 6111
    _(status.to_a).must_equal [:clamped]

    bits, status = BinData::Decimal128.encode("1E+6144")
    value = BinData::Decimal128.decode(bits)
    _(value.coefficient).must_equal 10**33
    _(value.exponent).must_equal 6111
    _(status.to_a).must_equal [:clamped]
  end

  it "clamps the exponent of zero" do
    _bits, status = BinData::Decimal128.encode("0E+9999")
    _(status.to_a).must_equal [:clamped]
    _bits, status = BinData::Decimal128.encode("0E-9999")
    _(status.to_a).must_equal [:clamped]
  end

  it "encodes subnormal numbers" do
    bits, status = BinData::Decimal128.encode("1E-6176")
    value = BinData::Decimal128.decode(bits)
    _(value.coefficient).must_equal 1
    _(value.exponent).must_equal(-6176)
    _(status.to_a).must_equal [:subnormal]
  end

  it "rounds into the subnormal range" do
    bits, status = BinData::Decimal128.encode("1.5E-6176")
    value = BinData::Decimal128.decode(bits)
    _(value.coefficient).must_equal 2
    _(value.exponent).must_equal(-6176)
    _(status.to_a.sort).must_equal %i[inexact rounded subnormal underflow]
  end

  it "underflows to zero" do
    bits, status = BinData::Decimal128.encode("1E-6200")
    value = BinData::Decimal128.decode(bits)
    _(value.coefficient).must_equal 0
    _(value.exponent).must_equal(-6176)
    _(status.to_a.sort).must_equal %i[clamped inexact rounded subnormal underflow]
  end

  it "keeps the sign of an underflowed zero" do
    bits, _status = BinData::Decimal128.encode("-1E-6200")
    value = BinData::Decimal128.decode(bits)
    _(value.zero?).must_equal true
    _(value.negative?).must_equal true
  end

  it "overflows to infinity by default" do
    bits, status = BinData::Decimal128.encode("9.9999999999999999999999999999999999E+6144")
    value = BinData::Decimal128.decode(bits)
    _(value.infinity?).must_equal true
    _(status.to_a.sort).must_equal %i[inexact overflow rounded]
  end

  it "rounds down to the maximum finite value without overflow when it fits" do
    bits, status = BinData::Decimal128.encode("9.9999999999999999999999999999999999E+6144", round_mode: :down)
    value = BinData::Decimal128.decode(bits)
    _(value.finite?).must_equal true
    _(value.coefficient).must_equal 10**34 - 1
    _(value.exponent).must_equal 6111
    _(status.to_a.sort).must_equal %i[inexact rounded]
  end

  it "overflows to the maximum finite value when rounding toward zero" do
    bits, status = BinData::Decimal128.encode("1.1E+6145", round_mode: :down)
    value = BinData::Decimal128.decode(bits)
    _(value.finite?).must_equal true
    _(value.coefficient).must_equal 10**34 - 1
    _(value.exponent).must_equal 6111
    _(status.to_a.sort).must_equal %i[inexact overflow rounded]
  end

  it "overflows according to the sign and rounding mode" do
    bits, _ = BinData::Decimal128.encode("9.9999999999999999999999999999999999E+6144", round_mode: :floor)
    _(BinData::Decimal128.decode(bits).finite?).must_equal true
    bits, _ = BinData::Decimal128.encode("-9.9999999999999999999999999999999999E+6144", round_mode: :floor)
    value = BinData::Decimal128.decode(bits)
    _(value.infinity?).must_equal true
    _(value.negative?).must_equal true
    bits, _ = BinData::Decimal128.encode("-9.9999999999999999999999999999999999E+6144", round_mode: :ceiling)
    _(BinData::Decimal128.decode(bits).finite?).must_equal true
  end
end

describe "BinData::Decimal128::Value" do

  it "parses and prints without losing the quantum" do
    ["0", "-0", "0.00", "1", "-1", "1.20", "123.456", "-987.654E+10",
     "1E-6176", "1.2345E+6000", "9999999999999999999999999999999999",
     "Infinity", "-Infinity", "NaN", "NaN123", "sNaN", "sNaN456", "-NaN7"].each do |str|
      value = BinData::Decimal128::Value.parse(str)
      _(BinData::Decimal128::Value.parse(value.to_s).same_representation?(value)).must_equal true,
        "round trip of #{str} via #{value.to_s}"
    end
  end

  it "parses alternate forms" do
    _(BinData::Decimal128::Value.parse(".5")).must_equal BinData::Decimal128::Value.parse("0.5")
    _(BinData::Decimal128::Value.parse("1.")).must_equal BinData::Decimal128::Value.parse("1")
    _(BinData::Decimal128::Value.parse("+1.5")).must_equal BinData::Decimal128::Value.parse("1.5")
    _(BinData::Decimal128::Value.parse("1.5e2")).must_equal BinData::Decimal128::Value.parse("150")
    _(BinData::Decimal128::Value.parse("inf")).must_equal BinData::Decimal128::Value.infinity
    _(BinData::Decimal128::Value.parse("  1.5  ")).must_equal BinData::Decimal128::Value.parse("1.5")
  end

  it "rejects invalid strings" do
    ["", "abc", "1.2.3", "1e", "--1", "1_000"].each do |str|
      _(proc { BinData::Decimal128::Value.parse(str) }).must_raise ArgumentError
    end
  end

  it "coerces integers" do
    v = BinData::Decimal128::Value.coerce(-42)
    _(v.sign).must_equal(-1)
    _(v.coefficient).must_equal 42
    _(v.exponent).must_equal 0
  end

  it "coerces rationals with decimal denominators" do
    v = BinData::Decimal128::Value.coerce(Rational(3, 40))
    _(v.coefficient).must_equal 75
    _(v.exponent).must_equal(-3)
  end

  it "rejects rationals without a finite decimal expansion" do
    _(proc { BinData::Decimal128::Value.coerce(Rational(1, 3)) }).must_raise ArgumentError
  end

  it "coerces BigDecimal without passing through Float" do
    v = BinData::Decimal128::Value.coerce(BigDecimal("1.21"))
    _(v.coefficient).must_equal 121
    _(v.exponent).must_equal(-2)
    _(BinData::Decimal128::Value.coerce(BigDecimal("NaN")).nan?).must_equal true
    _(BinData::Decimal128::Value.coerce(BigDecimal("-Infinity")).infinity?).must_equal true
  end

  it "rejects Float" do
    _(proc { BinData::Decimal128::Value.coerce(1.5) }).must_raise ArgumentError
    _(proc { BinData::Decimal128::Value.coerce(0.0) }).must_raise ArgumentError
  end

  it "compares numerically" do
    _(BinData::Decimal128::Value.parse("1.20")).must_be :==, BinData::Decimal128::Value.parse("1.2")
    _(BinData::Decimal128::Value.parse("-1")).must_be :<, BinData::Decimal128::Value.parse("0")
    _(BinData::Decimal128::Value.parse("2")).must_be :>, BinData::Decimal128::Value.parse("-10")
    _(BinData::Decimal128::Value.parse("-Infinity")).must_be :<, BinData::Decimal128::Value.parse("-999")
    _(BinData::Decimal128::Value.parse("Infinity")).must_be :>, BinData::Decimal128::Value.parse("9E+6144")
    _(BinData::Decimal128::Value.parse("0")).must_be :==, BinData::Decimal128::Value.parse("-0.00")
    _(BinData::Decimal128::Value.parse("NaN") <=> BinData::Decimal128::Value.parse("1")).must_be_nil
    _(BinData::Decimal128::Value.parse("NaN")).wont_equal BinData::Decimal128::Value.parse("NaN")
  end

  it "distinguishes representations" do
    v120 = BinData::Decimal128::Value.parse("1.20")
    v12 = BinData::Decimal128::Value.parse("1.2")
    _(v120.same_representation?(v12)).must_equal false
    _(v120.eql?(v12)).must_equal false
    _(v120.same_representation?(BinData::Decimal128::Value.parse("1.20"))).must_equal true
    _(BinData::Decimal128::Value.parse("0").same_representation?(BinData::Decimal128::Value.parse("-0"))).must_equal false
  end

  it "exposes the quantum and adjusted exponent" do
    _(BinData::Decimal128::Value.parse("1.20").quantum).must_equal Rational(1, 100)
    _(BinData::Decimal128::Value.parse("1.20").adjusted_exponent).must_equal 0
    _(BinData::Decimal128::Value.parse("123").adjusted_exponent).must_equal 2
  end

  it "represents NaN payloads and signaling NaNs" do
    v = BinData::Decimal128::Value.nan(payload: 123, signaling: true, sign: -1)
    _(v.nan?).must_equal true
    _(v.signaling?).must_equal true
    _(v.payload).must_equal 123
    _(v.to_s).must_equal "-sNaN123"
  end

  it "rejects NaN payloads that do not fit on encode" do
    huge = BinData::Decimal128::Value.nan(payload: 10**33)
    _(proc { BinData::Decimal128.encode(huge) }).must_raise ArgumentError
  end
end

describe "BinData::Decimal128Le and BinData::Decimal128Be" do
  it "has a fixed size of 16 bytes" do
    _(BinData::Decimal128Le.new.num_bytes).must_equal 16
    _(BinData::Decimal128Be.new.num_bytes).must_equal 16
  end

  it "defaults to zero" do
    _(BinData::Decimal128Be.new.to_binary_s).must_equal_binary ["22080000000000000000000000000000"].pack("H*")
  end

  it "endianness only affects byte order, not the DPD mapping" do
    be = BinData::Decimal128Be.new("1.20").to_binary_s
    le = BinData::Decimal128Le.new("1.20").to_binary_s
    _(le).must_equal_binary be.reverse
    _(be).must_equal_binary ["220780000000000000000000000000a0"].pack("H*")
    _(le).must_equal_binary ["a0000000000000000000000000800722"].pack("H*")
  end

  it "round trips values through binary" do
    ["0", "1.20", "-987.654E+10", "1E-6176", "9.999999999999999999999999999999999E+6144",
     "Infinity", "-Infinity", "NaN", "sNaN456"].each do |str|
      [BinData::Decimal128Le, BinData::Decimal128Be].each do |klass|
        written = klass.new(str)
        read = klass.read(written.to_binary_s)
        _(read.value.same_representation?(BinData::Decimal128::Value.parse(str))).must_equal true,
          "#{klass} round trip of #{str}"
      end
    end
  end

  it "assigns integers, rationals and BigDecimals" do
    _(BinData::Decimal128Be.new(42).value.coefficient).must_equal 42
    _(BinData::Decimal128Be.new(Rational(1, 8)).value.to_s).must_equal "0.125"
    _(BinData::Decimal128Be.new(BigDecimal("1.21")).value.to_s).must_equal "1.21"
  end

  it "rejects Float values" do
    _(proc { BinData::Decimal128Be.new(1.5) }).must_raise ArgumentError
    obj = BinData::Decimal128Be.new
    _(proc { obj.value = 2.5 }).must_raise ArgumentError
  end

  it "exposes the encode status" do
    obj = BinData::Decimal128Be.new("1.23456789012345678901234567890123456789")
    obj.to_binary_s
    _(obj.encode_status.inexact?).must_equal true
    _(obj.encode_status.overflow?).must_equal false

    exact = BinData::Decimal128Be.new("1.20")
    exact.to_binary_s
    _(exact.encode_status.empty?).must_equal true
  end

  it "honours the :round_mode parameter" do
    str = "1234567890123456789012345678901234.5"
    up = BinData::Decimal128Be.new(str, round_mode: :up)
    down = BinData::Decimal128Be.new(str, round_mode: :down)
    _(BinData::Decimal128Be.read(up.to_binary_s).value.coefficient)
      .must_equal 1234567890123456789012345678901235
    _(BinData::Decimal128Be.read(down.to_binary_s).value.coefficient)
      .must_equal 1234567890123456789012345678901234
  end

  it "is usable in a Record via the dsl" do
    klass = Class.new(BinData::Record) do
      decimal128_le :price
      decimal128_be :qty
    end
    obj = klass.new
    obj.price = "1.20"
    obj.qty = "3"
    read = klass.read(obj.to_binary_s)
    _(read.price.to_s).must_equal "1.20"
    _(read.qty.to_s).must_equal "3"
    _(obj.num_bytes).must_equal 32
  end
end



describe "BinData::Decimal128 public hex vectors" do

  # Published decimal128 (DPD) encodings, cross-checked against an
  # independent decimal implementation.
  VECTORS = {
    "0"                                      => "22080000000000000000000000000000",
    "-0"                                     => "a2080000000000000000000000000000",
    "1"                                      => "22080000000000000000000000000001",
    "-1"                                     => "a2080000000000000000000000000001",
    "9"                                      => "22080000000000000000000000000009",
    "123"                                    => "220800000000000000000000000000a3",
    "0.1"                                    => "2207c000000000000000000000000001",
    "0.5"                                    => "2207c000000000000000000000000005",
    "1.2"                                    => "2207c000000000000000000000000012",
    "1.20"                                   => "220780000000000000000000000000a0",
    "3.14159"                                => "2206c0000000000000000000000650d9",
    "9999999999999999999999999999999999"     => "6e080ff3fcff3fcff3fcff3fcff3fcff",
    "1E-6176"                                => "00000000000000000000000000000001",
    "1E+6111"                                => "43ffc000000000000000000000000001",
    "9.999999999999999999999999999999999E+6144" => "77ffcff3fcff3fcff3fcff3fcff3fcff",
    "Infinity"                               => "78000000000000000000000000000000",
    "-Infinity"                              => "f8000000000000000000000000000000",
    "NaN"                                    => "7c000000000000000000000000000000",
    "sNaN"                                   => "7e000000000000000000000000000000",
    "NaN123"                                 => "7c0000000000000000000000000000a3",
    "-NaN"                                   => "fc000000000000000000000000000000",
  }

  it "encodes values to the expected 128 bit patterns" do
    VECTORS.each do |str, hex|
      bits, _status = BinData::Decimal128.encode(str)
      _("%032x" % bits).must_equal hex, "encoding of #{str}"
    end
  end

  it "decodes the 128 bit patterns to the same representations" do
    VECTORS.each do |str, hex|
      value = BinData::Decimal128.decode(hex.to_i(16))
      expected = BinData::Decimal128::Value.parse(str)
      _(value.same_representation?(expected)).must_equal true,
        "decoding #{hex}: got #{value.inspect}, expected #{expected.inspect}"
    end
  end

  it "round trips through encode and decode" do
    VECTORS.each_key do |str|
      bits, _ = BinData::Decimal128.encode(str)
      value = BinData::Decimal128.decode(bits)
      bits2, _ = BinData::Decimal128.encode(value)
      _(bits2).must_equal bits, "round trip of #{str}"
    end
  end
end
