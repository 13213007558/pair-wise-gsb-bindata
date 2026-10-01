#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))

describe BinData::LayoutSolver do
  let(:solver) { BinData::LayoutSolver.new }
  let(:expr)   { BinData::LayoutSolver::Expression }

  it "solves constant constraints" do
    solver.add_constraint(:total, expr.integer(42))
    _(solver.solve).must_equal(total: 42)
  end

  it "accepts plain integers as constraints" do
    solver.add_constraint(:total, 7)
    _(solver.solve).must_equal(total: 7)
  end

  it "solves a self inclusive varint length" do
    solver.add_constraint(:width, expr.variable(:total).varint_width)
    solver.add_constraint(:total, expr.integer(5) + expr.variable(:width))
    _(solver.solve).must_equal(width: 1, total: 6)
  end

  it "restabilises when the solution crosses a varint width boundary" do
    # 127 + 1 = 128, but 128 needs two varint bytes, so the stable
    # total is 129.
    solver.add_constraint(:width, expr.variable(:total).varint_width)
    solver.add_constraint(:total, expr.integer(127) + expr.variable(:width))
    _(solver.solve).must_equal(width: 2, total: 129)
  end

  it "stays below the boundary when the total fits" do
    solver.add_constraint(:width, expr.variable(:total).varint_width)
    solver.add_constraint(:total, expr.integer(126) + expr.variable(:width))
    _(solver.solve).must_equal(width: 1, total: 127)
  end

  it "restabilises across the 16383/16384 boundary" do
    solver.add_constraint(:width, expr.variable(:total).varint_width)
    solver.add_constraint(:total, expr.integer(16_383) + expr.variable(:width))
    _(solver.solve).must_equal(width: 3, total: 16_386)
  end

  it "solves offsets with alignment padding" do
    solver.add_constraint(:width, expr.variable(:total).varint_width)
    solver.add_constraint(:offset, expr.variable(:width).align_up(4))
    solver.add_constraint(:total, expr.variable(:offset) + 1)
    _(solver.solve).must_equal(width: 1, offset: 4, total: 5)
  end

  it "solves alignment that interacts with a width boundary" do
    # offset depends on the varint width, and the total crosses 128.
    solver.add_constraint(:width, expr.variable(:total).varint_width)
    solver.add_constraint(:offset, (expr.integer(126) + expr.variable(:width)).align_up(4))
    solver.add_constraint(:total, expr.variable(:offset) + 1)
    # width 1: offset = align_up(127, 4) = 128, total = 129.
    # 129 needs two varint bytes: offset = align_up(128, 4) = 128, total 129.
    _(solver.solve).must_equal(width: 2, offset: 128, total: 129)
  end

  it "supports multiplication" do
    solver.add_constraint(:x, expr.integer(3) * expr.integer(4))
    _(solver.solve).must_equal(x: 12)
  end

  it "supports integer on the left hand side of operators" do
    solver.add_constraint(:x, 3 + expr.integer(4))
    _(solver.solve).must_equal(x: 7)
  end

  it "solves several dependent variables" do
    solver.add_constraint(:a, expr.integer(1))
    solver.add_constraint(:b, expr.variable(:a) + 2)
    solver.add_constraint(:c, expr.variable(:b) * expr.variable(:a))
    _(solver.solve).must_equal(a: 1, b: 3, c: 3)
  end

  it "solves nested self inclusive lengths" do
    # inner total feeds into the outer total.
    solver.add_constraint(:inner_width, expr.variable(:inner).varint_width)
    solver.add_constraint(:inner, expr.integer(126) + expr.variable(:inner_width))
    solver.add_constraint(:outer_width, expr.variable(:outer).varint_width)
    solver.add_constraint(:outer, expr.variable(:inner) + expr.variable(:outer_width))
    _(solver.solve).must_equal(
      inner_width: 1, inner: 127, outer_width: 2, outer: 129)
  end

  describe "errors" do
    it "rejects negative constants" do
      _ { expr.integer(-1) }.must_raise BinData::LayoutSolver::UnsupportedExpressionError
    end

    it "rejects non integer terms" do
      _ { expr.integer("x") }.must_raise BinData::LayoutSolver::UnsupportedExpressionError
      _ { expr.integer(1.5) }.must_raise BinData::LayoutSolver::UnsupportedExpressionError
    end

    it "rejects subtraction" do
      _ { expr.integer(3) - 1 }.must_raise BinData::LayoutSolver::UnsupportedExpressionError
      _ { 3 - expr.integer(1) }.must_raise BinData::LayoutSolver::UnsupportedExpressionError
    end

    it "rejects division" do
      _ { expr.integer(3) / 1 }.must_raise BinData::LayoutSolver::UnsupportedExpressionError
    end

    it "rejects modulo" do
      _ { expr.integer(3) % 2 }.must_raise BinData::LayoutSolver::UnsupportedExpressionError
    end

    it "rejects exponentiation" do
      _ { expr.integer(3) ** 2 }.must_raise BinData::LayoutSolver::UnsupportedExpressionError
    end

    it "rejects non positive alignment" do
      _ { expr.integer(3).align_up(0) }.must_raise BinData::LayoutSolver::UnsupportedExpressionError
      _ { expr.integer(3).align_up(-4) }.must_raise BinData::LayoutSolver::UnsupportedExpressionError
      _ { expr.integer(3).align_up(2.5) }.must_raise BinData::LayoutSolver::UnsupportedExpressionError
    end

    it "rejects unsupported constraint terms" do
      _ { solver.add_constraint(:x, "nope") }.must_raise BinData::LayoutSolver::UnsupportedExpressionError
    end

    it "rejects unknown variables" do
      solver.add_constraint(:x, expr.variable(:y))
      _ { solver.solve }.must_raise BinData::LayoutSolver::UnsupportedExpressionError
    end

    it "rejects negative varint widths" do
      _ { BinData::LayoutSolver.varint_width(-1) }.must_raise BinData::LayoutSolver::UnsupportedExpressionError
    end

    it "raises UnstableLayoutError when the layout never stabilises" do
      solver.add_constraint(:x, expr.variable(:x) + 1)
      _ { solver.solve }.must_raise BinData::LayoutSolver::UnstableLayoutError
    end

    it "honours a custom iteration limit" do
      limited = BinData::LayoutSolver.new(max_iterations: 3)
      limited.add_constraint(:x, expr.variable(:x) + 1)
      _ { limited.solve }.must_raise BinData::LayoutSolver::UnstableLayoutError
    end

    it "raises LengthOverflowError when a solved value is too large" do
      limited = BinData::LayoutSolver.new(max_value: 100)
      limited.add_constraint(:x, expr.integer(101))
      _ { limited.solve }.must_raise BinData::LayoutSolver::LengthOverflowError
    end

    it "raises LengthOverflowError instead of running away" do
      limited = BinData::LayoutSolver.new(max_value: 150)
      limited.add_constraint(:x, expr.variable(:x) + 100)
      _ { limited.solve }.must_raise BinData::LayoutSolver::LengthOverflowError
    end
  end
end
