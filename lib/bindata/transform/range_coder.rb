module BinData
  module Transform
    # Transforms a data stream with a static table range coder.
    #
    # A range coder compresses a sequence of bytes according to the
    # frequency of each byte value.  This transform uses a fixed
    # frequency table, so both the frequency table and the length of
    # the original data must be known in advance and supplied by the
    # declaration.  No external compression library is required.
    #
    #   FREQ = [0] * 256
    #   FREQ[?a.ord] = 3
    #   FREQ[?b.ord] = 1
    #
    #   class RangeCodedRecord < BinData::Record
    #     section :s, transform: -> { BinData::Transform::RangeCoder.new(5, FREQ) } do
    #       string :data, read_length: 5
    #     end
    #   end
    #
    # The decoder knows the number of symbols to decode from the
    # declared length, so it stops exactly at the end of the encoded
    # data.  It neither reads ahead into the following data nor relies
    # on reaching the end of the stream.  This allows several range
    # coded sections to be placed back to back in the one stream, and
    # allows the stream to be unseekable in either direction.
    #
    # A byte value with zero frequency can not be encoded and will
    # raise an error when writing.
    class RangeCoder < BinData::IO::Transform
      transform_changes_stream_length!

      # The number of symbols in the frequency table, one per byte value.
      NUM_SYMBOLS = 256

      # Precision limit of the 32 bit range coder.  The cumulative
      # frequency of all symbols must not exceed this limit so that
      # every symbol is always assigned a non empty sub range.
      MAX_TOTAL_FREQUENCY = 1 << 16

      def initialize(read_length, frequencies)
        super()
        @read_length = validate_read_length(read_length)
        @frequencies = validate_frequencies(frequencies)
        @cumulative  = cumulative_frequencies(@frequencies)
        @total       = @cumulative.last
      end

      def read(n)
        @decoder ||= Decoder.new(@cumulative) { read_chain_byte }
        @decoded ||= create_empty_binary_string
        @num_decoded ||= 0

        while @decoded.bytesize < n && @num_decoded < @read_length
          @decoded << @decoder.decode_symbol
          @num_decoded += 1
        end

        @decoded.slice!(0, n)
      end

      def write(data)
        @write_buffer ||= create_empty_binary_string
        @write_buffer << data
      end

      def after_read_transform
        # Consume the bytes of an empty section even if nothing was read.
        @decoder ||= Decoder.new(@cumulative) { read_chain_byte }
        @decoded ||= create_empty_binary_string
        @num_decoded ||= 0

        unless @decoded.empty? && @num_decoded == @read_length
          raise IOError, "didn't read all data"
        end
      end

      def after_write_transform
        data = @write_buffer || create_empty_binary_string

        unless data.bytesize == @read_length
          raise IOError, "expected #{@read_length} bytes to write, got #{data.bytesize}"
        end

        encoder = Encoder.new
        data.each_byte do |byte|
          freq = @frequencies[byte]
          if freq.zero?
            raise ArgumentError, format("can not encode byte 0x%02x with zero frequency", byte)
          end
          encoder.encode(@cumulative[byte], freq, @total)
        end
        encoder.flush

        chain_write(encoder.output)
      end

      #-------------
      private

      def read_chain_byte
        byte = chain_read(1)
        raise EOFError, "End of file reached" if byte.nil? || byte.empty?

        byte.unpack1('C')
      end

      def validate_read_length(read_length)
        unless read_length.is_a?(::Integer) && read_length >= 0
          raise ArgumentError, "read_length must be a non negative integer"
        end

        read_length
      end

      def validate_frequencies(frequencies)
        unless frequencies.is_a?(::Array) && frequencies.size == NUM_SYMBOLS
          raise ArgumentError, "frequencies must be an array of #{NUM_SYMBOLS} entries"
        end

        frequencies.each_with_index do |freq, symbol|
          unless freq.is_a?(::Integer) && freq >= 0
            raise ArgumentError, "frequency of symbol #{symbol} must be a non negative integer"
          end
        end

        frequencies
      end

      def cumulative_frequencies(frequencies)
        cumulative = [0]
        frequencies.each do |freq|
          cumulative << cumulative.last + freq
        end

        total = cumulative.last
        if total.zero?
          raise ArgumentError, "frequency table must not be empty"
        end
        if total > MAX_TOTAL_FREQUENCY
          raise ArgumentError, "total frequency #{total} exceeds limit of #{MAX_TOTAL_FREQUENCY}"
        end

        cumulative
      end

      # A carry less 32 bit range encoder.  Emits one byte for every
      # renormalisation step and a final four bytes when flushed.
      class Encoder
        TOP  = 1 << 24
        BOT  = 1 << 16
        MASK = 0xFFFF_FFFF

        attr_reader :output

        def initialize
          @low    = 0
          @range  = MASK
          @output = "".b
        end

        def encode(cum_freq, freq, total)
          @range /= total
          @low    = (@low + cum_freq * @range) & MASK
          @range *= freq
          normalize
        end

        def flush
          4.times do
            emit_byte
            @low = (@low << 8) & MASK
          end
        end

        #-------------
        private

        def normalize
          while (@low ^ (@low + @range)) < TOP || (@range < BOT && (@range = -@low & (BOT - 1); true))
            emit_byte
            @low   = (@low << 8) & MASK
            @range = (@range << 8) & MASK
          end
        end

        def emit_byte
          @output << ((@low >> 24) & 0xFF)
        end
      end

      # The matching decoder.  Mirrors the encoder renormalisation
      # exactly, so it consumes precisely the number of bytes that the
      # encoder produced - never more, never less.
      class Decoder
        TOP  = 1 << 24
        BOT  = 1 << 16
        MASK = 0xFFFF_FFFF

        def initialize(cumulative, &read_byte)
          @cumulative = cumulative
          @total      = cumulative.last
          @read_byte  = read_byte

          @low   = 0
          @range = MASK
          @code  = 0
          4.times { @code = ((@code << 8) | @read_byte.call) & MASK }
        end

        def decode_symbol
          @range /= @total
          count  = (@code - @low) / @range
          symbol = find_symbol(count)

          cum_freq = @cumulative[symbol]
          freq     = @cumulative[symbol + 1] - cum_freq

          @low    = (@low + cum_freq * @range) & MASK
          @range *= freq
          normalize

          symbol
        end

        #-------------
        private

        def find_symbol(count)
          if count >= @total
            raise IOError, "corrupt range coded data"
          end

          lo = 0
          hi = @cumulative.size - 1
          while lo + 1 < hi
            mid = (lo + hi) / 2
            if @cumulative[mid] <= count
              lo = mid
            else
              hi = mid
            end
          end
          lo
        end

        def normalize
          while (@low ^ (@low + @range)) < TOP || (@range < BOT && (@range = -@low & (BOT - 1); true))
            @code  = ((@code << 8) | @read_byte.call) & MASK
            @low   = (@low << 8) & MASK
            @range = (@range << 8) & MASK
          end
        end
      end
    end
  end
end
