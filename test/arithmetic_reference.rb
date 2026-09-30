# Independent arithmetic coding reference used solely by the test suite.
#
# This is a from scratch transcription of the classic Witten, Neal & Cleary
# (1987) "E1/E2/E3" integer coder.  It deliberately shares no code with
# BinData::ArithmeticCodec: the register updates, bit IO, frequency
# normalisation and the decode loop are written in the textbook's idiom so
# that byte identical output is a meaningful cross check.
#
# The parameters are pinned to the BinData specification:
#   * 32 bit code registers, MSB first bit packing
#   * total frequency <= 65536, frequencies are rescaled up below 16384
#   * one reserved end of stream symbol of frequency 1
#   * final flush followed by zero padding of the last byte
class ReferenceArithmeticCoder
  CODE_BITS   = 32
  TOP         = 1 << CODE_BITS
  HALF        = 1 << (CODE_BITS - 1)
  QUARTER     = 1 << (CODE_BITS - 2)
  MAX_TOTAL   = 1 << 16
  MIN_TOTAL   = 1 << 14

  class BadStream < StandardError; end

  # A static or adaptive model.  +table+ is an ordered array of
  # +[symbol, frequency]+ pairs.  EOS is appended automatically.
  class Model
    attr_reader :end_symbol

    def initialize(table, end_symbol = :eos, &updater)
      @table = table.map { |sym, freq| [sym, freq.to_i] }
      @end_symbol = end_symbol
      @updater = updater
    end

    def frequencies
      @table.map { |sym, freq| [sym, freq] }
    end

    def update(symbol)
      @updater.call(self, symbol) if @updater
    end

    def increment!(symbol)
      entry = @table.detect { |sym, _| sym == symbol }
      raise "unknown symbol" unless entry
      entry[1] += 1
    end
  end

  def self.encode(model, symbols)
    new.tap { |c| c.run_encode(model, symbols) }.bytes
  end

  def self.decode(model, bytes)
    new.run_decode(model, bytes)
  end

  def initialize
    @out = []
  end

  def bytes
    @out.map(&:chr).join.force_encoding(Encoding::BINARY)
  end

  def run_encode(model, symbols)
    low = 0
    high = TOP - 1
    pending = 0
    @bit_buffer = 0
    @bit_count = 0

    emit = lambda do |bit|
      @bit_buffer = (@bit_buffer << 1) | bit
      @bit_count += 1
      if @bit_count == 8
        @out << @bit_buffer
        @bit_buffer = 0
        @bit_count = 0
      end
    end

    plus_follow = lambda do |bit|
      emit.call(bit)
      pending.times { emit.call(1 - bit) }
      pending = 0
    end

    tables = proc do
      ranges, total = normalised_ranges(model)
      [ranges, total]
    end

    symbols.each do |symbol|
      ranges, total = tables.call
      r_low, r_high = ranges.fetch(symbol) { raise "symbol #{symbol.inspect} impossible" }
      span = high - low + 1
      high = low + (span * r_high) / total - 1
      low  = low + (span * r_low) / total

      loop do
        if high < HALF
          plus_follow.call(0)
        elsif low >= HALF
          plus_follow.call(1)
          low -= HALF
          high -= HALF
        elsif low >= QUARTER && high < 3 * QUARTER
          pending += 1
          low -= QUARTER
          high -= QUARTER
        else
          break
        end
        low <<= 1
        high = (high << 1) + 1
      end

      model.update(symbol)
    end

    ranges, total = tables.call
    r_low, r_high = ranges.fetch(model.end_symbol)
    span = high - low + 1
    high = low + (span * r_high) / total - 1
    low  = low + (span * r_low) / total

    # renormalise after the end marker exactly like a normal symbol; this
    # guarantees the interval straddles the midpoint before the final flush
    loop do
      if high < HALF
        plus_follow.call(0)
      elsif low >= HALF
        plus_follow.call(1)
        low -= HALF
        high -= HALF
      elsif low >= QUARTER && high < 3 * QUARTER
        pending += 1
        low -= QUARTER
        high -= QUARTER
      else
        break
      end
      low <<= 1
      high = (high << 1) + 1
    end

    pending += 1
    if low < QUARTER
      plus_follow.call(0)
    else
      plus_follow.call(1)
    end

    if @bit_count.nonzero?
      @out << ((@bit_buffer << (8 - @bit_count)) & 0xff)
    end
  end

  def run_decode(model, raw)
    data = raw.b
    bit_index = 0
    read_bit = lambda do
      byte = bit_index / 8
      b =
        if byte < data.bytesize
          (data.getbyte(byte) >> (7 - (bit_index % 8))) & 1
        else
          0
        end
      bit_index += 1
      raise BadStream, "truncated stream" if bit_index > data.bytesize * 8 + CODE_BITS * 2 + 16
      b
    end

    low = 0
    high = TOP - 1
    value = 0
    CODE_BITS.times { value = (value << 1) | read_bit.call }

    result = []
    loop do
      ranges, total = normalised_ranges(model)
      span = high - low + 1
      cumulative = ((value - low + 1) * total - 1) / span
      raise BadStream, "cumulative out of range" unless cumulative >= 0 && cumulative < total

      symbol = ranges.detect { |_, (lo, hi)| cumulative >= lo && cumulative < hi }&.first
      raise BadStream, "no symbol for cumulative" if symbol.nil?
      break if symbol == model.end_symbol

      r_low, r_high = ranges.fetch(symbol)
      high = low + (span * r_high) / total - 1
      low  = low + (span * r_low) / total

      loop do
        if high < HALF
          # lower half
        elsif low >= HALF
          value -= HALF
          low -= HALF
          high -= HALF
        elsif low >= QUARTER && high < 3 * QUARTER
          value -= QUARTER
          low -= QUARTER
          high -= QUARTER
        else
          break
        end
        low <<= 1
        high = (high << 1) + 1
        value = ((value << 1) & (TOP - 1)) | read_bit.call
      end

      result << symbol
      model.update(symbol)
    end

    result
  end

  private

  # Returns +[hash(symbol => [low, high]), total]+ including EOS.
  def normalised_ranges(model)
    pairs = model.frequencies
    pairs.each do |sym, freq|
      raise "bad frequency for #{sym.inspect}: #{freq}" unless freq.is_a?(Integer) && freq.positive?
      raise "symbol collides with EOS" if sym == model.end_symbol
    end

    freqs = pairs.map(&:last)
    freqs = freqs.map { |f| (f + 1) / 2 } while freqs.sum + 1 > MAX_TOTAL

    if freqs.sum < MIN_TOTAL
      real_total = freqs.sum
      factor = (MAX_TOTAL - 1) / real_total
      freqs = freqs.map { |f| f * factor }
      extra = (MAX_TOTAL - 1) - freqs.sum
      i = 0
      while extra.positive?
        freqs[i % freqs.length] += 1
        extra -= 1
        i += 1
      end
    end

    ranges = {}
    cum = 0
    pairs.each_with_index do |(sym, _), i|
      ranges[sym] = [cum, cum + freqs[i]]
      cum += freqs[i]
    end
    ranges[model.end_symbol] = [cum, cum + 1]

    [ranges, cum + 1]
  end
end
