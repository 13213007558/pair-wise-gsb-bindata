module BinData
  # Arithmetic coding for BinData fields.
  #
  # This module implements a static-model, integer arithmetic coder with
  # carry handling (Witten / Neal / Cleary style, using the "follow" /
  # E3 underflow algorithm).  Symbols are small integers (e.g. enum
  # values); the caller supplies a cumulative frequency model for each
  # symbol position, so the model used may depend on previously
  # processed fields.
  #
  # Coded payload format (all bits are MSB first):
  #
  #   * the arithmetic coded symbols,
  #   * the terminating code produced when the end marker is coded,
  #   * zero padding bits (always 0) up to the next byte boundary.
  #
  # The payload carries no framing (no symbol or byte counts); callers
  # frame it themselves (the BinData::Arith field prepends a small
  # header).  Decoding a payload that was cut off mid stream is
  # detected by the end marker check in Decoder#finish.
  #
  # The model is never shared as mutable state between encoder and
  # decoder: BinData::ArithmeticCodec::Model is stateless, and a
  # BinData::ArithmeticCodec::AdaptiveModel is constructed independently
  # on each side.  Both endpoints must code / decode symbols in the same
  # order and call +update_symbol+ in that same order.
  module ArithmeticCodec
    # Number of value bits of the integer interval.  With 31 bits the
    # widest intermediate product (range * frequency) stays within 62
    # bits, well inside Ruby integer range (and 64 bit platforms).
    PRECISION = 31

    # Half / quarter points and full width of the coding interval.
    HALF = 1 << (PRECISION - 1)
    QUARTER = 1 << (PRECISION - 2)
    FULL_RANGE = 1 << PRECISION

    # Maximum permitted total frequency.  A model whose frequency total
    # is larger than this is scaled down (see #scaled_cumulative).
    MAX_FREQUENCY = FULL_RANGE - 1

    # Raised when a model returns frequencies that cannot be coded.
    class InvalidModelError < ArgumentError; end

    # Pure arithmetic helpers shared by the encoder and decoder.
    module IntervalMath
      private

      # Validates +cumulative+ and returns a copied array of integers.
      #
      # +cumulative+ is an array of cumulative frequencies, i.e.
      # cumulative[i] = sum(freq[0..i-1]); the last entry is the total.
      # Adjacent entries may be equal, meaning that symbol has zero
      # frequency and cannot be coded.
      def validate_cumulative(cumulative)
        unless cumulative.respond_to?(:[]) && cumulative.respond_to?(:length)
          raise InvalidModelError,
                "cumulative frequencies must be an array, " \
                "got #{cumulative.class}"
        end

        cum = cumulative.map { |f| to_frequency(f) }

        if cum.length < 2
          raise InvalidModelError,
                "model must contain at least one symbol " \
                "(plus the end marker)"
        end

        if cum.first != 0
          raise InvalidModelError,
                "first cumulative frequency must be 0, got #{cum.first}"
        end

        (1...cum.length).each do |i|
          if cum[i] < cum[i - 1]
            raise InvalidModelError,
                  "cumulative frequencies must be non decreasing"
          end
        end

        if cum.last.zero?
          raise InvalidModelError, "total frequency must be greater than 0"
        end

        cum
      end

      # Scales a cumulative frequency table so its total is at most
      # +max_total+.  Symbols with positive frequency keep a frequency
      # of at least 1 (low frequency symbols never disappear); rounding
      # surplus is trimmed deterministically from the widest symbols.
      def scaled_cumulative(cumulative, max_total = MAX_FREQUENCY)
        cum = validate_cumulative(cumulative)
        total = cum.last
        return cum if total <= max_total

        n = cum.length - 1
        freqs = ::Array.new(n) { |i| cum[i + 1] - cum[i] }

        scaled = freqs.map do |f|
          f.zero? ? 0 : [1, (f * max_total) / total].max
        end

        # Floor rounding plus the 1-frequency floor can overshoot
        # max_total; trim the excess from the widest symbols.
        while (excess = scaled.sum - max_total).positive?
          idx = widest_reducible_index(scaled)
          if idx.nil?
            raise InvalidModelError,
                  "model has #{scaled.count { |f| f.positive? }} non zero " \
                  "symbols, more than fit at precision #{PRECISION}"
          end
          scaled[idx] -= [excess, scaled[idx] - 1].min
        end

        result = [0]
        scaled.each { |f| result << result.last + f }
        result
      end

      def widest_reducible_index(freqs)
        idx = nil
        widest = 1
        freqs.each_with_index do |f, i|
          if f > widest
            widest = f
            idx = i
          end
        end
        idx
      end

      def to_frequency(value)
        unless value.respond_to?(:to_int)
          raise InvalidModelError,
                "frequency must be an integer, got #{value.inspect}"
        end
        freq = value.to_int
        if freq.negative?
          raise InvalidModelError,
                "frequency must be non negative, got #{freq}"
        end
        freq
      end
    end

    # Encodes a sequence of small integer symbols into a binary string.
    class Encoder
      include IntervalMath

      def initialize
        @low = 0
        @high = FULL_RANGE - 1
        @pending_bits = 0
        @bytes = ::String.new.force_encoding(Encoding::BINARY)
        @bit_buffer = 0
        @bit_count = 0
        @coded_count = 0
      end

      attr_reader :coded_count

      # Codes +symbol+ using +cumulative+ frequencies.  +symbol+ indexes
      # the symbols of the model (0 based); it must name a symbol with
      # positive frequency, otherwise InvalidModelError is raised before
      # any state change for this symbol is visible.
      def encode(symbol, cumulative)
        cum = scaled_cumulative(cumulative)
        s = symbol_index(symbol, cum)

        if cum[s + 1] == cum[s]
          raise InvalidModelError,
                "symbol #{symbol} has zero frequency and cannot be coded"
        end

        narrow(s, cum)
        renormalize
        @coded_count += 1
        self
      end

      # Codes the end marker and returns the coded payload: coded
      # symbols, terminating code and zero padding bits up to the next
      # byte boundary.  The payload carries no framing of its own.
      #
      # +end_symbol+ is the marker's index and +cumulative+ the model
      # in effect after the final symbol.  +num_symbols+ must equal the
      # number of symbols previously coded with #encode; it is used as
      # a self check only and is not written to the payload.
      def finish(end_symbol, cumulative, num_symbols)
        unless num_symbols.respond_to?(:to_int)
          raise InvalidModelError,
                "symbol count must be an integer, got #{num_symbols.inspect}"
        end
        count = num_symbols.to_int
        unless count == @coded_count && count >= 0
          raise InvalidModelError,
                "symbol count #{num_symbols} does not match " \
                "#{@coded_count} coded symbols"
        end

        cum = scaled_cumulative(cumulative)
        e = symbol_index(end_symbol, cum)
        if cum[e + 1] == cum[e]
          raise InvalidModelError,
                "end symbol #{end_symbol} must have positive frequency"
        end

        narrow(e, cum)
        renormalize

        # Standard Witten / Neal / Cleary flush: one more follow bit is
        # pending, then emit a prefix that lands wholly inside the
        # current interval.
        @pending_bits += 1
        if @low < QUARTER
          emit_bit(0)
          @pending_bits.times { emit_bit(1) }
        else
          emit_bit(1)
          @pending_bits.times { emit_bit(0) }
        end
        @pending_bits = 0

        flush_bits
        @bytes
      end

      private

      def symbol_index(symbol, cum)
        unless symbol.respond_to?(:to_int)
          raise InvalidModelError,
                "symbol must be an integer, got #{symbol.inspect}"
        end
        s = symbol.to_int
        nsymbols = cum.length - 1
        if s.negative? || s >= nsymbols
          raise InvalidModelError,
                "symbol #{symbol} is outside model range 0...#{nsymbols}"
        end
        s
      end

      def narrow(symbol, cum)
        total = cum.last
        range = @high - @low + 1
        @high = @low + (range * cum[symbol + 1]) / total - 1
        @low  = @low + (range * cum[symbol]) / total
      end

      def renormalize
        loop do
          if @high < HALF
            bit_plus_follow(0)
          elsif @low >= HALF
            @low -= HALF
            @high -= HALF
            bit_plus_follow(1)
          elsif @low >= QUARTER && @high < HALF + QUARTER
            @pending_bits += 1
            @low -= QUARTER
            @high -= QUARTER
          else
            break
          end

          @low = (@low << 1) & (FULL_RANGE - 1)
          @high = ((@high << 1) | 1) & (FULL_RANGE - 1)
        end
      end

      def bit_plus_follow(bit)
        emit_bit(bit)
        @pending_bits.times { emit_bit(bit ^ 1) }
        @pending_bits = 0
      end

      def emit_bit(bit)
        @bit_buffer = (@bit_buffer << 1) | (bit & 1)
        @bit_count += 1
        return unless @bit_count == 8

        @bytes << @bit_buffer.chr
        @bit_buffer = 0
        @bit_count = 0
      end

      # Pads the final output byte with zero bits.
      def flush_bits
        return if @bit_count.zero?

        @bit_buffer <<= (8 - @bit_count)
        @bytes << @bit_buffer.chr
        @bit_buffer = 0
        @bit_count = 0
      end
    end

    # Decodes a coded payload previously produced by Encoder#finish.
    class Decoder
      include IntervalMath

      # The minimum legal payload is a single padded byte (the empty
      # sequence coded with the end marker).
      MIN_PAYLOAD_BYTES = 1

      def initialize(payload, expected_count = nil)
        unless payload.respond_to?(:to_str)
          raise ArgumentError, "coded payload must be a binary string"
        end
        @payload = payload.to_str
        if @payload.bytesize < MIN_PAYLOAD_BYTES
          raise IOError, "truncated arithmetic coded payload"
        end

        @expected_count = expected_count
        @byte_index = 0
        @bit_index = 0
        # Number of zero bits supplied past the physical end of the
        # payload.  A complete record only needs a bounded amount of
        # zero fill (the initial value preload plus the terminating
        # marker decode); a corrupt / truncated stream that keeps
        # decoding symbols would run forever without this bound.
        @zero_fill = 0
        @zero_fill_budget = 4 * PRECISION

        @value = 0
        # Bits past the end of the payload are logically zero.  This is
        # not an error for a complete record: the encoder flush chooses
        # a code point whose canonical continuation is all zero bits.
        # Physical truncation is detected by the end marker and symbol
        # count checks in #finish (and by the framing in the BinData
        # container); excessive zero fill raises EOFError.
        PRECISION.times { @value = (@value << 1) | read_bit }

        @low = 0
        @high = FULL_RANGE - 1
        @count = 0
      end

      attr_reader :count, :expected_count
      # Decodes and returns the next symbol using +cumulative+
      # frequencies.  IOError is raised on a corrupt stream; callers
      # must invoke #finish afterwards to validate the record.
      def decode(cumulative)
        cum = scaled_cumulative(cumulative)
        total = cum.last

        range = @high - @low + 1
        scaled = (((@value - @low + 1) * total) - 1) / range

        idx = cum.index { |c| c > scaled }
        if idx.nil? || idx.zero?
          raise IOError, "arithmetic coded value outside model range"
        end
        symbol = idx - 1

        range = @high - @low + 1
        @high = @low + (range * cum[idx]) / total - 1
        @low  = @low + (range * cum[idx - 1]) / total

        renormalize
        @count += 1
        symbol
      end

      # Decodes the end marker, verifies it equals +end_symbol+ and
      # (when supplied to the constructor) checks the declared symbol
      # count.  A stream that ends early is decoded with zero filled
      # continuation bits; this can only yield the correct marker for a
      # genuinely complete payload, while a byte truncated or shifted
      # stream fails here.  Framing callers also enforce the exact
      # payload length at the IO layer.
      def finish(end_symbol, cumulative)
        marker = decode(cumulative)
        if marker != end_symbol.to_int
          raise IOError,
                "expected end marker #{end_symbol}, decoded symbol #{marker}"
        end
        if @count - 1 != @expected_count
          raise IOError,
                "symbol count mismatch: header says #{@expected_count}, " \
                "decoded #{@count - 1}"
        end

        @count - 1
      end

      private

      def renormalize
        loop do
          if @high < HALF
            # both ends in the lower half
          elsif @low >= HALF
            @low -= HALF
            @high -= HALF
            @value -= HALF
          elsif @low >= QUARTER && @high < HALF + QUARTER
            @low -= QUARTER
            @high -= QUARTER
            @value -= QUARTER
          else
            break
          end

          @low = (@low << 1) & (FULL_RANGE - 1)
          @high = ((@high << 1) | 1) & (FULL_RANGE - 1)
          @value = ((@value << 1) | read_bit) & (FULL_RANGE - 1)
        end
      end

      def read_bit
        byte = @payload.getbyte(@byte_index)
        if byte.nil?
          @zero_fill += 1
          if @zero_fill > @zero_fill_budget
            raise EOFError, "truncated arithmetic coded payload"
          end
          return 0
        end

        @zero_fill = 0
        bit = (byte >> (7 - @bit_index)) & 1
        @bit_index += 1
        if @bit_index == 8
          @bit_index = 0
          @byte_index += 1
        end
        bit
      end
    end

    # A static, stateless frequency model.  Given a list of per symbol
    # frequencies (the last entry being the end marker frequency), it
    # answers cumulative frequency queries.  Instances may be shared
    # freely between encoder and decoder because they hold no mutable
    # state.
    #
    #   model = BinData::ArithmeticCodec::Model.new([60, 30, 10, 1])
    #   # symbols 0, 1, 2 and end marker 3
    class Model
      include IntervalMath

      # +frequencies+ is [freq_symbol_0, freq_symbol_1, ..., freq_end].
      # A zero frequency means the symbol exists in the alphabet but
      # may not be coded.
      def initialize(frequencies)
        unless frequencies.respond_to?(:map)
          raise InvalidModelError,
                "frequencies must be an array, got #{frequencies.class}"
        end

        @frequencies = frequencies.map { |f| to_frequency(f) }
        if @frequencies.length < 2
          raise InvalidModelError,
                "model needs at least one data symbol and an end marker"
        end

        @cumulative = [0]
        @frequencies.each { |f| @cumulative << @cumulative.last + f }
        if @cumulative.last.zero?
          raise InvalidModelError, "total frequency must be greater than 0"
        end
        if @frequencies.last.zero?
          raise InvalidModelError, "end marker must have positive frequency"
        end

        @symbols = @frequencies.length - 1
      end

      attr_reader :symbols

      # Returns the (unscaled) cumulative frequency table.
      def cumulative
        @cumulative.dup
      end

      def end_symbol
        @symbols
      end

      def frequency(symbol)
        @frequencies[symbol]
      end

      # Validates that +symbol+ is a data symbol with positive
      # frequency and returns it as an integer.  Used to reject a value
      # before the containing record is written.
      def assert_valid_symbol!(symbol)
        unless symbol.respond_to?(:to_int)
          raise InvalidModelError,
                "symbol must be an integer, got #{symbol.inspect}"
        end
        s = symbol.to_int
        if s.negative? || s >= @symbols
          raise InvalidModelError,
                "symbol #{symbol} is outside model range 0...#{@symbols}"
        end
        if @frequencies[s].zero?
          raise InvalidModelError,
                "symbol #{symbol} has zero frequency and cannot be coded"
        end
        s
      end
    end

    # An adaptive frequency model maintained independently on each
    # side.  Both endpoints construct their own instance and call
    # +update_symbol+ after every coded symbol in the same order; the
    # two instances then hold identical frequencies without ever
    # sharing mutable state.
    #
    # All symbols (data symbols and the end marker) start at
    # +:initial_frequency+.  When the total reaches +:max_total+ all
    # frequencies are halved rounding up (so a symbol that has appeared
    # keeps a positive frequency) before the next increment.
    #
    #   model = BinData::ArithmeticCodec::AdaptiveModel.new(3, max_total: 2**14)
    class AdaptiveModel
      # +num_symbols+ counts data symbols only; the end marker is
      # added automatically.
      def initialize(num_symbols, initial_frequency: 1, max_total: 1 << 14)
        unless num_symbols.respond_to?(:to_int) && num_symbols.to_int.positive?
          raise InvalidModelError,
                "num_symbols must be a positive integer, got #{num_symbols.inspect}"
        end
        @symbols = num_symbols.to_int

        init = to_int(initial_frequency, :initial_frequency)
        if init < 1
          raise InvalidModelError,
                "initial_frequency must be >= 1, got #{init}"
        end

        max = to_int(max_total, :max_total)
        if max < @symbols + 1
          raise InvalidModelError,
                "max_total must be at least #{@symbols + 1}"
        end
        if max > MAX_FREQUENCY
          raise InvalidModelError,
                "max_total #{max} exceeds precision limit #{MAX_FREQUENCY}"
        end

        @max_total = max
        @frequencies = ::Array.new(@symbols + 1, init)
        @total = init * (@symbols + 1)
        if @total > @max_total
          raise InvalidModelError,
                "initial frequencies total #{@total} exceed max_total #{@max_total}"
        end
      end

      attr_reader :symbols, :total

      def end_symbol
        @symbols
      end

      def cumulative
        cum = [0]
        @frequencies.each { |f| cum << cum.last + f }
        cum
      end

      def frequency(symbol)
        @frequencies[symbol]
      end

      # Records that +symbol+ was just processed.  Call on both sides,
      # in the same order, immediately after coding / decoding.  The
      # end marker is never updated (it terminates the stream).
      def update_symbol(symbol)
        unless symbol.respond_to?(:to_int)
          raise InvalidModelError,
                "symbol must be an integer, got #{symbol.inspect}"
        end
        s = symbol.to_int
        if s.negative? || s >= @symbols
          raise InvalidModelError,
                "symbol #{symbol} is outside data range 0...#{@symbols}"
        end

        rescale_if_needed
        @frequencies[s] += 1
        @total += 1
        self
      end

      private

      def rescale_if_needed
        return if @total < @max_total

        @frequencies.map! { |f| ((f - 1) >> 1) + 1 }
        @total = @frequencies.sum
      end

      def to_int(value, name)
        unless value.respond_to?(:to_int)
          raise InvalidModelError,
                "#{name} must be an integer, got #{value.inspect}"
        end
        value.to_int
      end
    end
  end
end
