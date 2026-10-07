module BinData
  module Transform
    # Transforms a data stream with rANS (range Asymmetric Numeral Systems)
    # entropy coding over a finite (byte) alphabet using an integer
    # frequency table.
    #
    # Two layouts are supported:
    #
    # [:single]      a single rANS state encodes the whole stream.
    # [:interleaved] +states+ interleaved rANS states take turns encoding
    #                symbols.  The encoded result differs from the single
    #                state layout, but decodes to the same data.
    #
    # Symbols are encoded in reverse order, so decoding reproduces the
    # original sequence in forward order.  The final encoder states are
    # stored in the block and become the initial decoder states.  After a
    # successful decode, every state returns to the initial encoder state
    # and the renormalisation stream is fully consumed; anything else
    # indicates a corrupt stream.
    #
    # The block is self describing.  It records the layout, the number of
    # interleaved states, the quantisation rule (scale bits), the
    # frequency total and the integer frequency table, so the decoder
    # never relies on external defaults:
    #
    #   u8    layout        (0 = single state, 1 = interleaved states)
    #   u8    n_states      (number of interleaved states, 1 for single)
    #   u8    scale_bits    (frequencies are quantised to sum to 2**scale_bits)
    #   u16le n_symbols     (number of entries in the frequency table)
    #   n_symbols * (u8 symbol, u16le frequency)
    #   u32le freq_total    (sum of the frequency table, must equal 2**scale_bits)
    #   u32le n_data        (number of encoded symbols)
    #   n_states * u32le    (final state of each encoder)
    #   ...                 renormalisation byte stream (consumed in reverse)
    #
    # A symbol with zero frequency in the model can never be encoded.  If
    # the input contains such a symbol, the write fails before anything is
    # emitted.
    class Rans < BinData::IO::Transform
      transform_changes_stream_length!

      # Initial state and lower bound for renormalisation.
      LOWER_BOUND = 1 << 23

      # Encoder states are kept below 2**STATE_BITS.
      STATE_BITS = 32

      # Valid range for the quantisation rule.  Frequencies are stored as
      # u16, so the total 2**scale_bits must fit in 16 bits.
      MIN_SCALE_BITS = 4
      MAX_SCALE_BITS = 15

      LAYOUTS = { :single => 0, :interleaved => 1 }.freeze

      def initialize(read_length, layout: :single, states: 4, scale_bits: 12, frequencies: nil)
        super()
        unless LAYOUTS.key?(layout)
          raise ArgumentError, "layout must be one of #{LAYOUTS.keys.inspect}"
        end
        unless states.is_a?(Integer) && states >= 1 && states <= 256
          raise ArgumentError, "states must be an integer between 1 and 256"
        end
        unless scale_bits.is_a?(Integer) &&
               scale_bits >= MIN_SCALE_BITS && scale_bits <= MAX_SCALE_BITS
          raise ArgumentError,
                "scale_bits must be an integer between #{MIN_SCALE_BITS} and #{MAX_SCALE_BITS}"
        end

        @length = read_length
        @layout = layout
        @n_states = (layout == :interleaved) ? states : 1
        @scale_bits = scale_bits
        @frequencies = frequencies
      end

      def read(n)
        # The decoder takes every parameter from the block header; the
        # constructor arguments only affect encoding.
        @read ||= decode(chain_read(@length))
        @read.slice!(0...n)
      end

      def write(data)
        @write ||= create_empty_binary_string
        @write << data
      end

      def after_read_transform
        raise IOError, "didn't read all data" unless @read.empty?
      end

      def after_write_transform
        chain_write(encode(@write || create_empty_binary_string))
      end

      #-------------------------------------------------------------------
      private

      def encode(data)
        counts = model_counts(data)
        freq = quantize(counts)
        cum = cumulative(freq)

        data.each_byte do |byte|
          if freq[byte].nil?
            raise ValidityError,
                  "symbol #{byte} has zero frequency in the rANS model"
          end
        end

        bytes = data.bytes
        n_data = bytes.length
        states = ::Array.new(@n_states, LOWER_BOUND)
        renorm = []

        (n_data - 1).downto(0) do |i|
          sym = bytes[i]
          f = freq[sym]
          c = cum[sym]
          k = i % @n_states
          x = states[k]

          x_max = ((LOWER_BOUND >> @scale_bits) << 8) * f
          while x >= x_max
            renorm << (x & 0xff)
            x >>= 8
          end

          x = ((x / f) << @scale_bits) + (x % f) + c
          if x >= (1 << STATE_BITS)
            raise ValidityError, "rANS encoder state overflow"
          end
          states[k] = x
        end

        header = [LAYOUTS[@layout], @n_states, @scale_bits, freq.size].pack("C3S")
        freq.keys.sort.each { |s| header << [s, freq[s]].pack("Cv") }
        freq_total = freq.empty? ? 0 : (1 << @scale_bits)
        header << [freq_total, n_data].pack("V2")
        header << states.pack("V*")
        header << renorm.pack("C*")
        header
      end

      def decode(blob)
        layout, n_states, scale_bits, n_symbols = take(blob, 0, 5).unpack("C3S")
        unless LAYOUTS.value?(layout)
          raise IOError, "unsupported rANS layout #{layout}"
        end
        if n_states < 1 || (layout == LAYOUTS[:single] && n_states != 1)
          raise IOError, "invalid rANS state count #{n_states}"
        end
        unless scale_bits >= MIN_SCALE_BITS && scale_bits <= MAX_SCALE_BITS
          raise IOError, "invalid rANS scale bits #{scale_bits}"
        end
        scale = 1 << scale_bits

        offset = 5
        freq = {}
        n_symbols.times do
          sym, f = take(blob, offset, 3).unpack("Cv")
          offset += 3
          raise IOError, "zero frequency in rANS table" if f.zero?
          raise IOError, "duplicate symbol #{sym} in rANS table" if freq.key?(sym)
          freq[sym] = f
        end

        freq_total, n_data = take(blob, offset, 8).unpack("V2")
        offset += 8
        if freq.empty?
          unless freq_total.zero? && n_data.zero?
            raise IOError, "rANS block with empty table must be empty"
          end
        else
          unless freq_total == scale
            raise IOError, "rANS frequency total #{freq_total} is not 2**#{scale_bits}"
          end
          unless freq.values.sum == freq_total
            raise IOError, "rANS frequency table does not sum to #{freq_total}"
          end
        end

        states = take(blob, offset, 4 * n_states).unpack("V#{n_states}")
        offset += 4 * n_states

        cum = cumulative(freq)
        slot_symbol = []
        freq.keys.sort.each { |s| freq[s].times { slot_symbol << s } }

        out = []
        ptr = blob.length
        n_data.times do |i|
          k = i % n_states
          x = states[k]
          slot = x & (scale - 1)
          sym = slot_symbol[slot]
          raise IOError, "rANS slot #{slot} has no symbol" if sym.nil?
          out << sym

          x = freq[sym] * (x >> scale_bits) + slot - cum[sym]
          while x < LOWER_BOUND
            ptr -= 1
            raise IOError, "rANS renormalisation stream underflow" if ptr < offset
            x = (x << 8) | blob.getbyte(ptr)
          end
          states[k] = x
        end

        unless ptr == offset
          raise IOError, "trailing bytes in rANS renormalisation stream"
        end
        unless states.all? { |x| x == LOWER_BOUND }
          raise IOError, "rANS final states did not recover to the initial state"
        end

        out.pack("C*")
      end

      def take(blob, offset, length)
        chunk = blob.byteslice(offset, length)
        if chunk.nil? || chunk.bytesize < length
          raise IOError, "truncated rANS block"
        end
        chunk
      end

      # Returns the integer counts that define the model.  An explicit
      # model (array of 256 counts or hash of symbol => count) takes
      # precedence; otherwise counts are collected from the data.
      def model_counts(data)
        counts = ::Array.new(256, 0)
        if @frequencies
          if @frequencies.is_a?(Hash)
            @frequencies.each { |sym, count| counts[sym] = count }
          else
            @frequencies.each_with_index { |count, sym| counts[sym] = count }
          end
        else
          data.each_byte { |byte| counts[byte] += 1 }
        end
        counts
      end

      # Quantises counts so the frequencies sum to exactly 2**scale_bits.
      # Every symbol with a nonzero count keeps a frequency of at least 1.
      def quantize(counts)
        scale = 1 << @scale_bits
        present = counts.each_with_index.select { |count, _| count > 0 }
        return {} if present.empty?
        if present.size > scale
          raise ValidityError,
                "#{present.size} symbols do not fit in 2**#{@scale_bits} frequencies"
        end

        total = present.sum { |count, _| count }
        freq = {}
        present.each do |count, sym|
          f = (count * scale) / total
          f = 1 if f < 1
          freq[sym] = f
        end

        sum = freq.values.sum
        while sum < scale
          sym = present.max_by { |count, s| [count, -s] }.last
          freq[sym] += 1
          sum += 1
        end
        while sum > scale
          sym = freq.keys.select { |s| freq[s] > 1 }.max_by { |s| [freq[s], -s] }
          freq[sym] -= 1
          sum -= 1
        end
        freq
      end

      def cumulative(freq)
        cum = {}
        run = 0
        freq.keys.sort.each do |sym|
          cum[sym] = run
          run += freq[sym]
        end
        cum
      end
    end
  end
end
