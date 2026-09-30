# An independent reference implementation of the documented
# arithmetic coding rules.  It manipulates the coded stream as a string
# of '0'/'1' bits instead of packed bytes, so it shares no
# implementation with BinData::ArithmeticCodec.  Used by the tests to
# cross check exact emitted bytes and cross decoder compatibility.
module ReferenceArithmetic
  PRECISION = 31
  FULL = 1 << PRECISION
  HALF = 1 << (PRECISION - 1)
  QUARTER = 1 << (PRECISION - 2)
  MAX_TOTAL = FULL - 1

  # Independent formulation of the documented frequency scaling:
  # non zero symbols keep at least 1; floor scale, then trim the
  # surplus off the widest symbols.
  def self.scale(cumulative)
    cum = cumulative
    return cum if cum.last <= MAX_TOTAL

    freqs = cum.each_cons(2).map { |a, b| b - a }
    total = cum.last
    scaled = freqs.map { |f| f.zero? ? 0 : [1, f * MAX_TOTAL / total].max }

    while (over = scaled.sum - MAX_TOTAL).positive?
      # tie breaking must match the production rule exactly (first
      # widest symbol with frequency above 1)
      idx = nil
      widest = 1
      scaled.each_with_index do |f, i|
        if f > widest
          widest = f
          idx = i
        end
      end
      raise "unscalable model" if idx.nil?
      scaled[idx] -= [over, scaled[idx] - 1].min
    end

    out = [0]
    scaled.each { |f| out << out.last + f }
    out
  end

  class Encoder
    def initialize
      @low = 0
      @high = FULL - 1
      @pending = 0
      @bits = +""
    end

    def encode(symbol, cumulative)
      cum = ReferenceArithmetic.scale(cumulative)
      total = cum.last
      range = @high - @low + 1
      @high = @low + range * cum[symbol + 1] / total - 1
      @low  = @low + range * cum[symbol] / total
      renorm
    end

    def finish(end_symbol, cumulative)
      encode(end_symbol, cumulative)
      @pending += 1
      if @low < QUARTER
        follow(0)
      else
        follow(1)
      end
      pad = (8 - @bits.length % 8) % 8
      @bits << "0" * pad
      [@bits].pack("B*")
    end

    private

    def renorm
      loop do
        if @high < HALF
          follow(0)
        elsif @low >= HALF
          @low -= HALF
          @high -= HALF
          follow(1)
        elsif @low >= QUARTER && @high < 3 * QUARTER
          @pending += 1
          @low -= QUARTER
          @high -= QUARTER
        else
          break
        end
        @low = (@low << 1) & (FULL - 1)
        @high = ((@high << 1) | 1) & (FULL - 1)
      end
    end

    def follow(bit)
      @bits << bit.to_s
      @pending.times { @bits << (1 - bit).to_s }
      @pending = 0
    end
  end

  class Decoder
    def initialize(payload)
      @bits = payload.unpack1("B*")
      @pos = 0
      @value = PRECISION.times.inject(0) { |v| (v << 1) | next_bit }
      @low = 0
      @high = FULL - 1
    end

    def decode(cumulative)
      cum = ReferenceArithmetic.scale(cumulative)
      total = cum.last
      range = @high - @low + 1
      scaled = ((@value - @low + 1) * total - 1) / range
      symbol = (0...cum.length - 1).find { |s| scaled < cum[s + 1] }

      @high = @low + range * cum[symbol + 1] / total - 1
      @low  = @low + range * cum[symbol] / total
      renorm
      symbol
    end

    private

    def next_bit
      b = @bits[@pos]
      @pos += 1
      b ? b.to_i : 0
    end

    def renorm
      loop do
        if @high < HALF
          # nothing
        elsif @low >= HALF
          @low -= HALF
          @high -= HALF
          @value -= HALF
        elsif @low >= QUARTER && @high < 3 * QUARTER
          @low -= QUARTER
          @high -= QUARTER
          @value -= QUARTER
        else
          break
        end
        @low = (@low << 1) & (FULL - 1)
        @high = ((@high << 1) | 1) & (FULL - 1)
        @value = ((@value << 1) | next_bit) & (FULL - 1)
      end
    end
  end
end
