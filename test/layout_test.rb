#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))

describe BinData::Layout, ".varint_width" do
  it "is one byte for small values" do
    _(BinData::Layout.varint_width(0)).must_equal 1
    _(BinData::Layout.varint_width(1)).must_equal 1
    _(BinData::Layout.varint_width(127)).must_equal 1
  end

  it "crosses width boundaries at powers of 128" do
    _(BinData::Layout.varint_width(128)).must_equal 2
    _(BinData::Layout.varint_width(16_383)).must_equal 2
    _(BinData::Layout.varint_width(16_384)).must_equal 3
    _(BinData::Layout.varint_width((1 << 64) - 1)).must_equal 10
  end

  it "rejects negative values" do
    _ { BinData::Layout.varint_width(-1) }.must_raise BinData::Layout::UnsupportedExpressionError
  end

  it "rejects non integer values" do
    _ { BinData::Layout.varint_width(1.5) }.must_raise BinData::Layout::UnsupportedExpressionError
  end
end

describe BinData::Layout::Expression do
  it "builds constants from integers" do
    expr = BinData::Layout::Expression.build(5)
    _(expr.evaluate({})).must_equal 5
  end

  it "builds references from symbols" do
    expr = BinData::Layout::Expression.build(:len)
    _(expr.evaluate(len: 42)).must_equal 42
    _(expr.references).must_equal [:len]
  end

  it "builds compound expressions from arrays" do
    expr = BinData::Layout::Expression.build([:add, 1, [:mul, 2, :x], [:align_up, :y, 4]])
    _(expr.evaluate(x: 3, y: 5)).must_equal(1 + 6 + 8)
    _(expr.references.sort).must_equal [:x, :y]
  end

  it "builds varint width expressions" do
    expr = BinData::Layout::Expression.build([:varint_width, :len])
    _(expr.evaluate(len: 127)).must_equal 1
    _(expr.evaluate(len: 128)).must_equal 2
  end

  it "builds expressions with factory methods" do
    expr = BinData::Layout.align_up(
             BinData::Layout.add(BinData::Layout.encoded_width(:len), 3), 4)
    _(expr.evaluate(len: 0)).must_equal 4
    _(expr.evaluate(len: 127)).must_equal 4
    _(expr.evaluate(len: 128)).must_equal 8
  end

  it "rejects subtraction" do
    _ { BinData::Layout::Expression.build([:sub, :x, 1]) }.must_raise BinData::Layout::UnsupportedExpressionError
  end

  it "rejects division" do
    _ { BinData::Layout::Expression.build([:div, :x, 2]) }.must_raise BinData::Layout::UnsupportedExpressionError
  end

  it "rejects negative constants" do
    _ { BinData::Layout::Expression.build(-1) }.must_raise BinData::Layout::UnsupportedExpressionError
    _ { BinData::Layout::Expression.build([:add, :x, -1]) }.must_raise BinData::Layout::UnsupportedExpressionError
  end

  it "rejects non integer constants" do
    _ { BinData::Layout::Expression.build(1.5) }.must_raise BinData::Layout::UnsupportedExpressionError
  end

  it "rejects arbitrary procs" do
    _ { BinData::Layout::Expression.build(-> { 1 }) }.must_raise BinData::Layout::UnsupportedExpressionError
  end

  it "rejects non constant multipliers" do
    _ { BinData::Layout::Expression.build([:mul, :x, 2]) }.must_raise BinData::Layout::UnsupportedExpressionError
    _ { BinData::Layout::Expression.build([:mul, -2, :x]) }.must_raise BinData::Layout::UnsupportedExpressionError
  end

  it "rejects non positive alignments" do
    _ { BinData::Layout::Expression.build([:align_up, :x, 0]) }.must_raise BinData::Layout::UnsupportedExpressionError
    _ { BinData::Layout::Expression.build([:align_up, :x, -4]) }.must_raise BinData::Layout::UnsupportedExpressionError
    _ { BinData::Layout::Expression.build([:align_up, :x, :y]) }.must_raise BinData::Layout::UnsupportedExpressionError
  end

  it "rejects empty sums" do
    _ { BinData::Layout::Expression.build([:add]) }.must_raise BinData::Layout::UnsupportedExpressionError
  end
end

describe BinData::Layout::Solver do
  it "solves constants" do
    solver = BinData::Layout::Solver.new
    solver.declare(:len, 5)
    _(solver.solve).must_equal(len: 5)
  end

  it "solves self inclusive varint lengths" do
    solver = BinData::Layout::Solver.new
    solver.declare(:len, [:add, [:varint_width, :len], 10])
    _(solver.solve).must_equal(len: 11)
  end

  it "restabilises when crossing the 127/128 width boundary" do
    { 125 => 126, 126 => 127, 127 => 129, 128 => 130 }.each_pair do |content, expected|
      solver = BinData::Layout::Solver.new
      solver.declare(:len, [:add, [:varint_width, :len], content])
      _(solver.solve[:len]).must_equal expected
    end
  end

  it "restabilises when crossing the 16383/16384 width boundary" do
    { 16_381 => 16_383, 16_382 => 16_385, 16_383 => 16_386 }.each_pair do |content, expected|
      solver = BinData::Layout::Solver.new
      solver.declare(:len, [:add, [:varint_width, :len], content])
      _(solver.solve[:len]).must_equal expected
    end
  end

  it "solves alignment expressions" do
    solver = BinData::Layout::Solver.new
    solver.declare(:len, [:align_up, [:add, [:varint_width, :len], 6], 4])
    _(solver.solve[:len]).must_equal 8
  end

  it "lets alignment absorb a width boundary crossing" do
    solver = BinData::Layout::Solver.new
    solver.declare(:len, [:align_up, [:add, [:varint_width, :len], 126], 4])
    _(solver.solve[:len]).must_equal 128
  end

  it "solves field offsets that depend on a solved length" do
    solver = BinData::Layout::Solver.new
    solver.declare(:len, [:add, [:varint_width, :len], 10])
    solver.declare(:payload_offset, [:varint_width, :len])
    solver.declare(:trailer_offset, [:add, :payload_offset, 10])
    solver.declare(:double_header, [:mul, 2, :payload_offset])

    solved = solver.solve
    _(solved[:len]).must_equal 11
    _(solved[:payload_offset]).must_equal 1
    _(solved[:trailer_offset]).must_equal 11
    _(solved[:double_header]).must_equal 2
  end

  it "solves nested self inclusive lengths bottom up" do
    solver = BinData::Layout::Solver.new
    solver.declare(:inner, [:add, [:varint_width, :inner], 5])
    solver.declare(:outer, [:add, [:varint_width, :outer], :inner, 2])

    solved = solver.solve
    _(solved[:inner]).must_equal 6
    _(solved[:outer]).must_equal 9
  end

  it "raises NoStableSolutionError when the layout cannot stabilise" do
    solver = BinData::Layout::Solver.new(max_iterations: 10)
    solver.declare(:len, [:add, :len, 1])
    _ { solver.solve }.must_raise BinData::Layout::NoStableSolutionError
  end

  it "raises NoStableSolutionError for mutually growing quantities" do
    solver = BinData::Layout::Solver.new(max_iterations: 10)
    solver.declare(:a, [:add, :b, 1])
    solver.declare(:b, [:add, :a, 1])
    _ { solver.solve }.must_raise BinData::Layout::NoStableSolutionError
  end

  it "raises LengthOverflowError when a length exceeds the maximum" do
    solver = BinData::Layout::Solver.new(max_length: 1_000)
    solver.declare(:len, [:mul, 2, [:add, :len, 1]])
    _ { solver.solve }.must_raise BinData::Layout::LengthOverflowError
  end

  it "raises LengthOverflowError for oversized constants" do
    solver = BinData::Layout::Solver.new(max_length: 5)
    solver.declare(:len, 6)
    _ { solver.solve }.must_raise BinData::Layout::LengthOverflowError
  end

  it "raises on references to undeclared quantities" do
    solver = BinData::Layout::Solver.new
    solver.declare(:len, [:add, :unknown, 1])
    _ { solver.solve }.must_raise ArgumentError
  end
end
