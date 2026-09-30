module BinData
  # Arithmetic coding primitives used by +BinData::Arithmetic+.
  #
  # This is a self contained implementation of the classic integer range
  # (carry-less, "E1/E2/E3") arithmetic coder.  It does not depend on the
  # rest of BinData so that it can be cross checked against an independent
  # reference encoder.
  #
  # == Integer interval precision
  #
  # All interval arithmetic uses +PRECISION+ (32) bit unsigned integers.
  # The probability interval is the half open integer range +[low, high)+
  # inside +[0, TOP)+ where
  #
  #   TOP  = 1 << PRECISION
  #   HALF = 1 << (PRECISION - 1)
  #   QTR  = 1 << (PRECISION - 2)
  #
  # Renormalisation keeps the interval inside +[0, TOP)+ with the standard
  # E1/E2/E3 rules.  The 32 bit precision is more than enough for the
  # frequency limits below: after every renormalisation the range is at
  # least +QTR+, and +QTR / MAX_FREQUENCY+ is still 2**14, so every unit of
  # frequency maps to an integer wide sub interval.
  #
  # == Frequency scaling
  #
  # Models expose cumulative frequencies (see
  # +BinData::ArithmeticCodec::Model+).  Before each symbol is coded the
  # table is normalised deterministically (encoder and decoder run the
  # exact same pure function of the model table):
  #
  # * every symbol claimed possible by the model keeps a frequency of at
  #   least one, which is what lets low frequency symbols be coded;
  # * if the real symbol total plus the end marker would exceed
  #   +MAX_FREQUENCY+ (65536), all frequencies are halved rounding upwards
  #   (so possible symbols survive) until the table fits;
  # * if the real symbol total is below +MIN_FREQUENCY+ (16384), all
  #   frequencies are multiplied by a common factor and the leftover units
  #   are spread round robin from the first symbol, using all available
  #   precision without changing relative frequencies materially.
  #
  # == End marker
  #
  # A reserved end of stream symbol (+END_OF_STREAM+) is appended to every
  # normalised table with a frequency of one.  The encoder emits it after
  # the last real symbol and the decoder stops when it reaches it.  Real
  # symbol values must not collide with the model's end marker value.
  #
  # == Bit packing
  #
  # The bit stream is big endian, most significant bit first.  After all
  # symbols (including the end marker) have been coded the encoder performs
  # the standard flush (emit one more bit that selects the quarter
  # containing +low+, plus any pending opposite bits) and then pads the
  # final byte with zero bits.  A decoder reads zero bits past the end of
  # the byte string, up to a bounded safety limit: legal finalisation only
  # needs bits inside the encoded bytes, so exceeding the limit means the
  # stream was truncated before its end marker.  (A truncated stream can
  # occasionally decode to a shorter, self consistent record; in that case
  # no error is raised, exactly as with any non integrity checked code.)
  module ArithmeticCodec
    # Raised when a model hands the coder a frequency table it cannot use.
    class InvalidFrequencyError < ArgumentError; end

    # Raised when a coded stream cannot be decoded (truncation, corruption).
    class CorruptedStreamError < IOError; end

    PRECISION     = 32
    TOP           = 1 << PRECISION
    HALF          = 1 << (PRECISION - 1)
    QTR           = 1 << (PRECISION - 2)
    MAX_FREQUENCY = 1 << 16
    MIN_FREQUENCY = 1 << 14

    # Internal symbol used to mark the end of a coded record.  Models never
    # see this value; they see their own (or the default) end marker.
    END_OF_STREAM = nil

    class << self
      # Normalises +cumulative+ (a flat array of +[sym, low, high]+ triples
      # as returned by +Model#cumulative_frequencies+) into
      # +[lookup, total]+ where +lookup+ maps each symbol (including
      # +end_symbol+) to its +[low, high]+ cumulative range and +total+ is
      # the cumulative total including the end marker.
      def normalize(cumulative, end_symbol)
        symbols, freqs = parse(cumulative, end_symbol)

        if symbols.length + 1 > MAX_FREQUENCY
          raise InvalidFrequencyError,
                "model has #{symbols.length} symbols, maximum is " \
                "#{MAX_FREQUENCY - 1}"
        end

        freqs = scale_down(freqs) while freqs.sum + 1 > MAX_FREQUENCY
        freqs = scale_up(freqs) if freqs.sum < MIN_FREQUENCY

        lookup = {}
        total = 0
        symbols.each_with_index do |sym, i|
          lookup[sym] = [total, total + freqs[i]]
          total += freqs[i]
        end
        lookup[end_symbol] = [total, total + 1]

        [lookup, total + 1]
      end

      # Encodes +symbols+ using +model+ and returns a binary String.  The
      # model may be adaptive: its +#update+ method (if present) is called
      # after every symbol in coding order.  The model is consumed by this
      # call; pass a freshly created instance.
      def encode(model, symbols)
        encoder = Encoder.new
        state   = ModelState.new(model)

        symbols.each do |symbol|
          bounds, total = state.bounds_for(symbol)
          encoder.encode_symbol(bounds, total)
          state.observe(symbol)
        end

        bounds, total = state.bounds_for(END_OF_STREAM)
        encoder.encode_symbol(bounds, total)
        encoder.finish
      end

      # Decodes binary +data+ using +model+ and returns the real symbol
      # values in coding order.  The model is consumed by this call; pass a
      # freshly created instance.
      def decode(model, data)
        decoder = Decoder.new(data)
        state   = ModelState.new(model)
        symbols = []

        loop do
          total = state.total
          cumulative = decoder.decode_cumulative(total)
          symbol = state.symbol_for_cumulative(cumulative)
          break if symbol == END_OF_STREAM

          bounds, = state.bounds_for(symbol)
          decoder.decode_symbol(bounds, total)
          symbols << symbol
          state.observe(symbol)
        end

        symbols
      end

      #------ normalisation helpers

      private

      def parse(cumulative, end_symbol)
        unless cumulative.is_a?(::Array)
          raise InvalidFrequencyError,
                "cumulative frequencies must be an array, got #{cumulative.class}"
        end
        raise InvalidFrequencyError, "model has no symbols" if cumulative.empty?
        unless (cumulative.length % 3).zero?
          raise InvalidFrequencyError,
                "cumulative frequencies must be [sym, low, high, ...] triples"
        end

        entries = cumulative.each_slice(3).to_a
        symbols = []
        freqs = []
        seen = {}
        prev_high = 0

        entries.each do |sym, low, high|
          if sym.nil? || sym == end_symbol
            raise InvalidFrequencyError,
                  "symbol #{sym.inspect} collides with the end of stream marker"
          end
          if seen.key?(sym)
            raise InvalidFrequencyError,
                  "symbol #{sym.inspect} appears more than once in the model"
          end
          seen[sym] = true
          unless low.is_a?(::Integer) && high.is_a?(::Integer)
            raise InvalidFrequencyError,
                  "frequencies for #{sym.inspect} must be integers"
          end
          if low != prev_high
            raise InvalidFrequencyError,
                  "cumulative frequencies must be contiguous: #{sym.inspect} " \
                  "starts at #{low}, expected #{prev_high}"
          end
          if high <= low
            raise InvalidFrequencyError,
                  "symbol #{sym.inspect} has non positive frequency"
          end

          symbols << sym
          freqs << high - low
          prev_high = high
        end

        [symbols, freqs]
      end

      def scale_down(freqs)
        freqs.map { |f| (f + 1) / 2 }
      end

      def scale_up(freqs)
        target = MAX_FREQUENCY - 1
        total = freqs.sum
        factor = target / total
        scaled = freqs.map { |f| f * factor }

        remaining = target - scaled.sum
        i = 0
        while remaining.positive?
          scaled[i % scaled.length] += 1
          remaining -= 1
          i += 1
        end

        scaled
      end
    end

    # Per record view of a model.  This is the only object that talks to the
    # caller's model and it is always created privately for one coding run,
    # so encoder and decoder never share mutable model state.
    class ModelState
      def initialize(model)
        unless model.respond_to?(:cumulative_frequencies)
          raise ArgumentError,
                "model must respond to #cumulative_frequencies, got #{model.class}"
        end
        @model = model
        @end_symbol = end_marker_for(model)
        rebuild
      end

      attr_reader :total

      # Returns +[[low, high], total]+ for a real symbol or the end marker.
      def bounds_for(symbol)
        symbol = @end_symbol if symbol == END_OF_STREAM
        bounds = @lookup[symbol]
        unless bounds
          raise InvalidFrequencyError,
                "symbol #{symbol.inspect} has zero frequency in the current model"
        end
        [bounds, @total]
      end

      # Returns the symbol whose cumulative range contains +cumulative+.
      # Entries are sorted by their cumulative low, so binary search them.
      def symbol_for_cumulative(cumulative)
        index = @entries.bsearch_index { |_, low, _| low > cumulative }
        index = index ? index - 1 : @entries.length - 1
        sym, low, high = @entries[index]
        cumulative >= low && cumulative < high ? sym : END_OF_STREAM
      end

      # Feeds +symbol+ back to an adaptive model and rebuilds the table.
      # Encoder and decoder call this in exactly the same order.
      def observe(symbol)
        return unless @model.respond_to?(:update)

        @model.update(symbol)
        rebuild
      end

      private

      def end_marker_for(model)
        if model.respond_to?(:end_symbol)
          model.end_symbol
        else
          # a symbol value that cannot appear accidentally
          :__bindata_arithmetic_end_of_stream__
        end
      end

      def rebuild
        @lookup, @total =
          ArithmeticCodec.normalize(@model.cumulative_frequencies, @end_symbol)

        @entries = @lookup.map do |sym, (low, high)|
          sym == @end_symbol ? [END_OF_STREAM, low, high] : [sym, low, high]
        end
        @entries.sort_by! { |_, low, _| low }
      end
    end

    # Bit level arithmetic encoder.
    class Encoder
      def initialize
        @low     = 0
        @high    = ArithmeticCodec::TOP
        @pending = 0
        @bytes   = ::String.new.force_encoding(Encoding::BINARY)
        @byte    = 0
        @nbits   = 0
      end

      def encode_symbol((cum_low, cum_high), total)
        range = @high - @low
        @high = @low + (range * cum_high) / total
        @low  = @low + (range * cum_low)  / total

        loop do
          if @high <= ArithmeticCodec::HALF
            emit_bit_plus_pending(0)
          elsif @low >= ArithmeticCodec::HALF
            emit_bit_plus_pending(1)
            @low  -= ArithmeticCodec::HALF
            @high -= ArithmeticCodec::HALF
          elsif @low >= ArithmeticCodec::QTR &&
                @high <= 3 * ArithmeticCodec::QTR
            @pending += 1
            @low  -= ArithmeticCodec::QTR
            @high -= ArithmeticCodec::QTR
          else
            break
          end

          @low  <<= 1
          @high <<= 1
        end
      end

      def finish
        @pending += 1
        if @low < ArithmeticCodec::QTR
          emit_bit_plus_pending(0)
        else
          emit_bit_plus_pending(1)
        end
        flush_byte
        @bytes
      end

      private

      def emit_bit_plus_pending(bit)
        emit_bit(bit)
        @pending.times { emit_bit(1 - bit) }
        @pending = 0
      end

      def emit_bit(bit)
        @byte = (@byte << 1) | bit
        @nbits += 1
        return unless @nbits == 8

        @bytes << @byte.chr
        @byte  = 0
        @nbits = 0
      end

      def flush_byte
        return unless @nbits.positive?

        # pad the rest of the final byte with zero bits
        @byte <<= (8 - @nbits)
        @bytes << @byte.chr
      end
    end

    # Bit level arithmetic decoder.  A bounded number of zero bits past the
    # end of the data stand in for the final byte's padding; asking for
    # significantly more means the stream was truncated before the end
    # marker could be decoded.
    class Decoder
      # How many zero bits may be consumed past the end of the data.  This
      # is a generous multiple of the register precision so any legal
      # finalisation finishes while truncated input is rejected promptly.
      TRAILING_ZERO_LIMIT = PRECISION * 2 + 16

      def initialize(data)
        @data = data.to_s.dup.force_encoding(Encoding::BINARY)
        @pos  = 0
        @past_end_bits = 0
        @low  = 0
        @high = ArithmeticCodec::TOP
        @value = 0
        ArithmeticCodec::PRECISION.times { @value = (@value << 1) | read_bit }
      end

      # Returns the cumulative frequency selected by the current interval.
      def decode_cumulative(total)
        range = @high - @low
        cumulative = (((@value - @low) + 1) * total - 1) / range
        if cumulative.negative? || cumulative >= total
          raise CorruptedStreamError,
                "decoded cumulative frequency #{cumulative} is outside 0...#{total}"
        end
        cumulative
      end

      def decode_symbol((cum_low, cum_high), total)
        range = @high - @low
        @high = @low + (range * cum_high) / total
        @low  = @low + (range * cum_low)  / total

        loop do
          if @high <= ArithmeticCodec::HALF
            # interval entirely in the lower half
          elsif @low >= ArithmeticCodec::HALF
            @value -= ArithmeticCodec::HALF
            @low  -= ArithmeticCodec::HALF
            @high -= ArithmeticCodec::HALF
          elsif @low >= ArithmeticCodec::QTR &&
                @high <= 3 * ArithmeticCodec::QTR
            @value -= ArithmeticCodec::QTR
            @low  -= ArithmeticCodec::QTR
            @high -= ArithmeticCodec::QTR
          else
            break
          end

          @low  <<= 1
          @high <<= 1
          @value = (@value << 1) & (ArithmeticCodec::TOP - 1)
          @value |= read_bit
        end
      end

      private

      def read_bit
        byte_index = @pos >> 3
        if byte_index < @data.bytesize
          bit = (@data.getbyte(byte_index) >> (7 - (@pos & 7))) & 1
        else
          @past_end_bits += 1
          if @past_end_bits > TRAILING_ZERO_LIMIT
            raise CorruptedStreamError,
                  "arithmetic stream is truncated (no end of stream marker)"
          end
          bit = 0
        end
        @pos += 1
        bit
      end
    end

    # A small adaptive frequency model.  Callers may use this or provide
    # their own object responding to +#cumulative_frequencies+ and
    # optionally +#update+ and +#end_symbol+.
    #
    # +symbols+ lists every value that may be coded.  All frequencies start
    # at one; +#update+ raises the frequency of the observed symbol.
    class Model
      def initialize(symbols)
        raise ArgumentError, "symbols must not be empty" if symbols.empty?

        @symbols = symbols.dup
        @counts = {}
        @symbols.each do |sym|
          if @counts.key?(sym)
            raise ArgumentError, "duplicate symbol #{sym.inspect}"
          end
          @counts[sym] = 1
        end
      end

      # Flat array of +[sym, low, high, ...]+ cumulative bounds, in the
      # order the symbols were given to the constructor.
      def cumulative_frequencies
        cumulative = []
        total = 0
        @symbols.each do |sym|
          freq = @counts[sym]
          cumulative.concat([sym, total, total + freq])
          total += freq
        end
        cumulative
      end

      # Adaptive update: the observed symbol becomes one unit more likely.
      def update(symbol)
        unless @counts.key?(symbol)
          raise InvalidFrequencyError,
                "unknown symbol #{symbol.inspect} for adaptive model"
        end
        @counts[symbol] += 1
      end

      # Returns all frequencies to their initial value of one.
      def reset
        @symbols.each { |sym| @counts[sym] = 1 }
      end
    end
  end
end
