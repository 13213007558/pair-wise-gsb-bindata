#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))
require 'bindata/arithmetic_codec'

require File.expand_path(File.join("support", "reference_arithmetic"), File.dirname(__FILE__))

describe "BinData::ArithmeticCodec" do
  AC = BinData::ArithmeticCodec

  def static_roundtrip(symbols, frequencies)
    model = AC::Model.new(frequencies)
    enc = AC::Encoder.new
    symbols.each { |s| enc.encode(s, model.cumulative) }
    payload = enc.finish(model.end_symbol, model.cumulative, symbols.length)

    dec = AC::Decoder.new(payload, symbols.length)
    out = Array.new(symbols.length) { dec.decode(model.cumulative) }
    dec.finish(model.end_symbol, model.cumulative)

    [payload, out]
  end

  def adaptive_roundtrip(symbols, num_symbols, **opts)
    e = AC::Encoder.new
    em = AC::AdaptiveModel.new(num_symbols, **opts)
    symbols.each do |s|
      e.encode(s, em.cumulative)
      em.update_symbol(s)
    end
    payload = e.finish(em.end_symbol, em.cumulative, symbols.length)

    d = AC::Decoder.new(payload, symbols.length)
    dm = AC::AdaptiveModel.new(num_symbols, **opts)
    out = symbols.length.times.map do
      s = d.decode(dm.cumulative)
      dm.update_symbol(s)
      s
    end
    d.finish(dm.end_symbol, dm.cumulative)

    [payload, out]
  end

  describe "constants" do
    it "uses a 31 bit interval" do
      _(AC::PRECISION).must_equal 31
      _(AC::FULL_RANGE).must_equal 1 << 31
      _(AC::MAX_FREQUENCY).must_equal (1 << 31) - 1
    end
  end

  describe "round trip" do
    it "round trips a skewed mix of symbols" do
      srand(42)
      freqs = [60, 30, 9, 1]
      syms = Array.new(2000) { |i| i < 1200 ? 0 : rand(3) }
      payload, out = static_roundtrip(syms, freqs)
      _(out).must_equal syms
      _(payload.bytesize).must_be :<, syms.length
    end

    it "round trips a long string of identical symbols" do
      syms = [0] * 100_000
      payload, out = static_roundtrip(syms, [99, 1])
      _(out).must_equal syms
      # 100k highly probable symbols compress to a handful of bytes.
      _(payload.bytesize).must_be :<, 200
    end

    it "round trips low frequency symbols" do
      freqs = [1, 1, 998]
      syms = [0, 1, 0, 0, 1, 0, 1, 1, 0]
      payload, out = static_roundtrip(syms, freqs)
      _(out).must_equal syms
      # The two rare symbols each cost about 10 bits.
      _(payload.bytesize).must_be :<=, syms.length + 4
    end

    it "round trips an empty sequence" do
      payload, out = static_roundtrip([], [80, 20])
      _(out).must_equal []
      _(payload.bytesize).must_equal 1
    end

    it "round trips a uniform 256 symbol alphabet (no compression)" do
      srand(7)
      freqs = [1] * 257
      syms = Array.new(2000) { rand(256) }
      payload, out = static_roundtrip(syms, freqs)
      _(out).must_equal syms
      _(payload.bytesize).must_be :>=, syms.length
    end

    it "round trips an adaptive model" do
      srand(99)
      syms = Array.new(5000) { rand(8) }
      _payload, out = adaptive_roundtrip(syms, 8)
      _(out).must_equal syms
    end

    it "adaptive coding compresses a skewed sequence" do
      srand(123)
      syms = Array.new(10_000) { rand < 0.97 ? 0 : rand(1...16) }
      payload, out = adaptive_roundtrip(syms, 16)
      _(out).must_equal syms
      _(payload.bytesize).must_be :<, syms.length / 4
    end

    it "scales models whose total exceeds the precision limit" do
      # 256 data symbols (all positive frequency) plus the end marker
      big = [0] + (1..257).map { |i| i * 10_000_000 }
      _(big.length).must_equal 258
      srand(11)
      syms = Array.new(3000) { rand(256) }

      enc = AC::Encoder.new
      syms.each { |s| enc.encode(s, big) }
      payload = enc.finish(256, big, syms.length)

      dec = AC::Decoder.new(payload, syms.length)
      out = syms.length.times.map { dec.decode(big) }
      dec.finish(256, big)
      _(out).must_equal syms
    end

    it "codes zero padding bits as zero" do
      model = AC::Model.new([50, 50])
      enc = AC::Encoder.new
      enc.encode(0, model.cumulative)
      payload = enc.finish(1, model.cumulative, 1)
      # The final nibble of the padded last byte is zero.
      _(payload.getbyte(-1) & 0x0f).must_equal 0
    end
  end

  describe "independent reference cross check" do
    def cross_check(symbols, cumulative_tables, end_symbol)
      prod = AC::Encoder.new
      ref = ReferenceArithmetic::Encoder.new
      symbols.each_with_index do |s, i|
        cum = cumulative_tables[i]
        prod.encode(s, cum)
        ref.encode(s, cum)
      end
      final_cum = cumulative_tables[symbols.length] ||
                  cumulative_tables.last

      prod_bytes = prod.finish(end_symbol, final_cum, symbols.length)
      ref_bytes = ref.finish(end_symbol, final_cum)

      # identical bytes
      _(prod_bytes).must_equal ref_bytes

      # each decoder reads the other's bytes
      d1 = AC::Decoder.new(ref_bytes, symbols.length)
      d2 = ReferenceArithmetic::Decoder.new(prod_bytes)
      out1 = symbols.length.times.map do |i|
        d1.decode(final_cum_for(cumulative_tables, i))
      end
      out2 = symbols.length.times.map do |i|
        d2.decode(final_cum_for(cumulative_tables, i))
      end
      _(out1).must_equal symbols
      _(out2).must_equal symbols
    end

    def final_cum_for(tables, i)
      tables[i] || tables.last
    end

    it "agrees on bytes for a static model" do
      srand(1)
      freqs = [700, 200, 90, 10]
      cum = [0]
      freqs.each { |f| cum << cum.last + f }
      syms = Array.new(3000) { rand(3) }
      cross_check(syms, ::Hash.new(cum), 3)
    end

    it "agrees on bytes for position dependent models" do
      srand(2)
      syms = Array.new(1000) { rand(4) }
      tables = (syms.length + 1).times.map do |i|
        # varying totals and skews, all within the precision range;
        # 4 data symbols plus the end marker (index 4)
        base = (i % 50) + 1
        [0, 50 * base, 70 * base, 90 * base, 95 * base, 100 * base]
      end
      cross_check(syms, tables, 4)
    end

    it "agrees on bytes for the empty sequence" do
      cum = [0, 80, 100]
      cross_check([], [cum], 1)
    end

    it "agrees on bytes for long identical runs" do
      cum = [0, 9999, 10000]
      cross_check([0] * 20_000, ::Hash.new(cum), 1)
    end

    it "agrees after frequency scaling of totals over the precision limit" do
      srand(3)
      # 4 data symbols plus end marker at index 4; total 2.5 billion > 2**31
      big = [0, 500_000_000, 1_000_000_000, 1_500_000_000,
             2_000_000_000, 2_500_000_000]
      syms = Array.new(2000) { rand(4) }
      cross_check(syms, ::Hash.new(big), 4)
    end

    it "agrees on bytes for totals close to the precision limit" do
      srand(4)
      # 4 data symbols plus end marker at index 4; total below 2**31
      big = [0, 400_000_000, 800_000_000, 1_200_000_000,
             1_600_000_000, 2_000_000_000]
      syms = Array.new(2000) { rand(4) }
      cross_check(syms, ::Hash.new(big), 4)
    end

    it "survives random fuzzing against the reference" do
      rng = Random.new(2026)
      200.times do
        nsymbols = 1 + rng.rand(8)
        raw = Array.new(nsymbols) { rng.rand(1000) }
        raw << 1 + rng.rand(1000) # end marker, always positive
        cum = [0]
        raw.each { |f| cum << cum.last + f }

        length = rng.rand(120)
        syms = Array.new(length) { rng.rand(nsymbols) }
        tables = ::Hash.new(cum)

        if rng.rand(2).zero?
          # occasionally use changing tables
          tables = (length + 1).times.map do
            v = [0]
            raw.each { |f| v << v.last + [1, f + rng.rand(3) - 1].max }
            v
          end
          tables.each { |t| t[-1] = t[-2] + 1 if t[-1] <= t[-2] }
          syms.each_with_index do |_s, i|
            t = tables[i]
            while t[syms[i] + 1] == t[syms[i]]
              syms[i] = rng.rand(nsymbols)
            end
          end
        end

        cross_check(syms, tables, nsymbols)
      end
    end

    it "agrees on bytes for adaptive model tables" do
      rng = Random.new(77)
      nsym = 6
      syms = Array.new(4000) { rng.rand(8) < 7 ? 0 : rng.rand(1...nsym) }

      model = AC::AdaptiveModel.new(nsym, max_total: 512)
      prod = AC::Encoder.new
      ref = ReferenceArithmetic::Encoder.new
      tables = []
      syms.each do |s|
        cum = model.cumulative
        tables << cum
        prod.encode(s, cum)
        ref.encode(s, cum)
        model.update_symbol(s)
      end
      final_cum = model.cumulative

      prod_bytes = prod.finish(model.end_symbol, final_cum, syms.length)
      ref_bytes = ref.finish(model.end_symbol, final_cum)
      _(prod_bytes).must_equal ref_bytes

      # a freshly adapted decoder model must reconstruct the sequence
      dm = AC::AdaptiveModel.new(nsym, max_total: 512)
      d = AC::Decoder.new(prod_bytes, syms.length)
      out = syms.length.times.map do |i|
        s = d.decode(dm.cumulative)
        dm.update_symbol(s)
        s
      end
      d.finish(dm.end_symbol, dm.cumulative)
      _(out).must_equal syms
    end
  end

  describe "invalid models and symbols" do
    def expect_invalid
      err = assert_raises(AC::InvalidModelError) { yield }
      err
    end

    it "rejects non integer frequencies" do
      expect_invalid { AC::Model.new([1, "x"]) }
    end

    it "rejects negative frequencies" do
      expect_invalid { AC::Model.new([10, -1]) }
    end

    it "rejects a zero total" do
      expect_invalid { AC::Model.new([0, 0]) }
    end

    it "rejects a zero frequency end marker" do
      expect_invalid { AC::Model.new([10, 0]) }
    end

    it "rejects fewer than two entries" do
      expect_invalid { AC::Model.new([10]) }
    end

    it "allows zero frequency data symbols but not coding them" do
      model = AC::Model.new([50, 0, 1])
      err = expect_invalid { AC::Encoder.new.encode(1, model.cumulative) }
      _(err.message).must_match(/zero frequency/)
    end

    it "rejects symbols outside the model range before coding" do
      model = AC::Model.new([50, 50, 1])
      enc = AC::Encoder.new
      expect_invalid { enc.encode(3, model.cumulative) }
      expect_invalid { enc.encode(-1, model.cumulative) }
    end

    it "rejects a decreasing cumulative table" do
      enc = AC::Encoder.new
      expect_invalid { enc.encode(0, [0, 50, 30, 100]) }
    end

    it "rejects a non array cumulative table" do
      enc = AC::Encoder.new
      expect_invalid { enc.encode(0, 42) }
    end

    it "rejects a zero frequency end marker" do
      enc = AC::Encoder.new
      enc.encode(0, [0, 50, 51, 51])
      # marker at index 2 has zero frequency
      expect_invalid { enc.finish(2, [0, 50, 51, 51], 1) }
    end

    it "rejects mismatched finish counts" do
      model = AC::Model.new([50, 1])
      enc = AC::Encoder.new
      enc.encode(0, model.cumulative)
      expect_invalid { enc.finish(1, model.cumulative, 2) }
    end
  end

  describe "truncated and corrupt input" do
    def payload_for(symbols, freqs)
      model = AC::Model.new(freqs)
      enc = AC::Encoder.new
      symbols.each { |s| enc.encode(s, model.cumulative) }
      enc.finish(model.end_symbol, model.cumulative, symbols.length)
    end

    it "rejects an empty payload" do
      assert_raises(IOError) { AC::Decoder.new("") }
    end

    it "detects a payload cut off mid stream" do
      model = AC::Model.new([60, 30, 9, 1])
      good = payload_for([0, 1, 2, 0, 1] * 20, [60, 30, 9, 1])
      # truncate deep inside the coded stream
      cut = good[0, good.bytesize / 2]
      dec = AC::Decoder.new(cut, 100)
      err = assert_raises(IOError) do
        100.times { dec.decode(model.cumulative) }
        dec.finish(3, model.cumulative)
      end
      _(err.message).must_match(/end marker|count/)
    end

    it "detects a count mismatch" do
      model = AC::Model.new([60, 30, 9, 1])
      good = payload_for([0, 1], [60, 30, 9, 1])
      dec = AC::Decoder.new(good, 99)
      2.times { dec.decode(model.cumulative) }
      assert_raises(IOError) { dec.finish(3, model.cumulative) }
    end
  end

  describe "AdaptiveModel" do
    it "keeps independent instances in sync when updated in order" do
      a = AC::AdaptiveModel.new(4)
      b = AC::AdaptiveModel.new(4)
      srand(31)
      500.times do
        s = rand < 0.9 ? 0 : rand(1...4)
        a.update_symbol(s)
        b.update_symbol(s)
        _(a.cumulative).must_equal b.cumulative
      end
    end

    it "rejects bad parameters" do
      assert_raises(AC::InvalidModelError) { AC::AdaptiveModel.new(0) }
      assert_raises(AC::InvalidModelError) {
        AC::AdaptiveModel.new(4, initial_frequency: 0)
      }
      assert_raises(AC::InvalidModelError) {
        AC::AdaptiveModel.new(4, max_total: 2)
      }
    end

    it "halves frequencies when max_total is reached" do
      m = AC::AdaptiveModel.new(1, initial_frequency: 1, max_total: 4)
      100.times { m.update_symbol(0) }
      _(m.cumulative.last).must_be :<=, 4
      _(m.cumulative.last).must_be :>=, 2
    end

    it "rescales many times over a long skewed run" do
      payload, out = adaptive_roundtrip([0] * 50_000, 4, max_total: 64)
      _(out).must_equal [0] * 50_000
      _(payload.bytesize).must_be :<, 2000
    end
  end
end
