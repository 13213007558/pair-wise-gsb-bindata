require 'bindata'
require 'minitest/autorun'

describe BinData::Decimal128Be do
  def roundtrip(value)
    obj = BinData::Decimal128Be.new(value)
    bytes = obj.to_binary_s
    _(bytes.length).must_equal 16
    BinData::Decimal128Be.read(bytes)
  end

  it 'encodes and decodes a finite decimal preserving quantum' do
    value = BinData::Decimal128Value.finite(750, -2, significant_digits: 3)
    obj = BinData::Decimal128Be.new(value)
    _(obj.to_binary_s.unpack1('H*')).must_equal '0a0780000000000000000000000003d0'
    read = BinData::Decimal128Be.read(obj.to_binary_s)
    _(read.coefficient).must_equal 750
    _(read.exponent).must_equal(-2050)
    _(read.to_s).must_equal '-7.50'
  end

  it 'stores NaN and Infinity payloads' do
    nan = BinData::Decimal128Be.read(BinData::Decimal128Codec.pack(0x7c000000000000000000000000000001))
    _(nan).must_be :qnan?
    _(nan.payload).must_equal 1
    infinity = BinData::Decimal128Be.read(BinData::Decimal128Codec.pack(0x78000000000000000000000000000000))
    _(infinity).must_be :infinity?
  end

  it 'rounds with caller selected mode and returns status' do
    value = BinData::Decimal128Value.parse('12345678901234567890123456789012345', rounding: :down)
    _(value.coefficient).must_equal 1234567890123456789012345678901234
    _(value.status[:rounded]).must_equal true
    _(value.status[:inexact]).must_equal true
  end

  it 'supports big and little endian byte ordering' do
    be = BinData::Decimal128Be.new(BinData::Decimal128Value.finite(1, 0, significant_digits: 1)).to_binary_s
    le = BinData::Decimal128Le.new(BinData::Decimal128Value.finite(1, 0, significant_digits: 1)).to_binary_s
    _(le).must_equal be.reverse
  end

  it 'roundtrips arbitrary decimal values through integer arithmetic' do
    [[1,0],[123,-2],[9999999999999999999999999999999999,-6176]].each do |coefficient, exponent|
      value = BinData::Decimal128Value.finite(coefficient, exponent, significant_digits: coefficient.to_s.length)
      read = roundtrip(value)
      _(read.coefficient).must_equal coefficient
      _(read.exponent).must_equal exponent
    end
  end
end
