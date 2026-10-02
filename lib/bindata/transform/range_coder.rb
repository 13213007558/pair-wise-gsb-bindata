module BinData
  module Transform
    # Transforms a data stream using range coding with a fixed frequency
    # table.  This transform is self contained and does not require any
    # external compression library.
    #
    #   class RangeCodedRecord < BinData::Record
    #     uint8 :data_length, value: -> { coded.length }
    #     section :coded, transform: -> { BinData::Transform::RangeCoder.new(FREQ_TABLE, data_length) },
    #                     type: [:string, read_length: :data_length]
    #   end
    #
    # The frequency table and the number of decoded bytes are both
    # provided by the declaration.  The decoder therefore knows exactly
    # how many symbols to decode and stops at the end of the encoded
    # data without relying on the end of the underlying stream.  This
    # allows several range coded sections to sit back to back in the one
    # stream, even when that stream is not seekable.
    #
    # == Parameters
    #
    # +frequencies+:: maps byte values (0 - 255) to their frequency.
    #                 Either a hash of byte => frequency or an array of
    #                 256 frequencies.  A byte with zero frequency can
    #                 never be encoded.  The cumulative frequencies must
    #                 not exceed MAX_TOTAL_FREQUENCY, which is the
    #                 precision limit of this 32 bit range coder.
    # +data_length+:: the number of bytes in the decoded data.  Zero
    #                 represents empty content and encodes to zero bytes.
    class RangeCoder < BinData::IO::Transform
      transform_changes_stream_length!

      # Maximum permitted total of all frequencies in the table.
      MAX_TOTAL_FREQUENCY = 1 << 16

      # The encoder and decoder renormalise whenever the range drops
      # below this threshold.  The condition depends only on the range,
      # which both sides track identically, so the decoder consumes
      # exactly as many bytes as the encoder produces: 4 bytes of
      # initial state plus one byte per renormalisation.
      TOP = 1 << 24

      # Width in bytes of the decoder's initial code window.  The
      # encoder flushes exactly this many bytes after the final symbol.
      WINDOW_SIZE = 4

      def initialize(frequencies, data_length)
        super()
        @freq = sanitize_frequencies(frequencies)
        @total = @freq.sum
        if @total > MAX_TOTAL_FREQUENCY
          raise ArgumentError, "total frequency #{@total} exceeds precision limit of #{MAX_TOTAL_FREQUENCY}"
        end
        @cumulative = @freq.each_with_object([0]) { |f, cum| cum << cum.last + f }
        @data_length = sanitize_data_length(data_length)
        if @data_length > 0 && @total.zero?
          raise ArgumentError, "frequency table must contain a positive frequency"
        end
        @decoded = 0
        @encoded = 0
      end

      def read(n)
        if n > @data_length - @decoded
          raise IOError, "read past end of range coded data"
        end

        start_decoder if @data_length > 0 && @code.nil?

        bytes = []
        bytes << decode_byte while bytes.size < n
        @decoded += n
        bytes.pack('C*')
      end

      def write(data)
        start_encoder if @low.nil?
        data.each_byte { |byte| encode_byte(byte) }
      end

      def after_read_transform
        if @decoded != @data_length
          raise IOError, "didn't read all data"
        end
      end

      def after_write_transform
        if @encoded != @data_length
          raise IOError, "expected to write #{@data_length} bytes but wrote #{@encoded}"
        end
        return if @encoded.zero?

        # The final state is flushed as exactly WINDOW_SIZE more bytes
        # than were shifted out during renormalisation.
        flush = @low.to_s(16).rjust((@shifts + WINDOW_SIZE) * 2, "0")
        write_encoded_bytes([flush].pack("H*"))
      end

      #-------------
      private

      def sanitize_frequencies(frequencies)
        table = ::Array.new(256, 0)
        case frequencies
        when ::Hash
          frequencies.each do |byte, freq|
            unless byte.is_a?(Integer) && byte.between?(0, 255)
              raise ArgumentError, "frequency table key #{byte.inspect} is not a byte value"
            end
            table[byte] = sanitize_frequency(freq)
          end
        when ::Array
          unless frequencies.size == 256
            raise ArgumentError, "frequency table must contain 256 entries"
          end
          frequencies.each_with_index do |freq, byte|
            table[byte] = sanitize_frequency(freq)
          end
        else
          raise ArgumentError, "frequency table must be a hash or an array"
        end
        table
      end

      def sanitize_frequency(freq)
        unless freq.is_a?(Integer) && freq >= 0
          raise ArgumentError, "frequency #{freq.inspect} must be a non-negative integer"
        end
        freq
      end

      def sanitize_data_length(data_length)
        # may be a BinData primitive when taken from a data field
        length = data_length.respond_to?(:to_int) ? data_length.to_int : data_length
        unless length.is_a?(::Integer) && length >= 0
          raise ArgumentError, "data length #{data_length.inspect} must be a non-negative integer"
        end
        length
      end

      def start_encoder
        @low = 0
        @range = (1 << (WINDOW_SIZE * 8)) - 1
        @encoded = 0
        @shifts = 0
      end

      def encode_byte(byte)
        freq = @freq[byte]
        if freq.zero?
          raise ArgumentError, "byte #{byte} has zero frequency and can not be encoded"
        end

        @range /= @total
        @low += @cumulative[byte] * @range
        @range *= freq
        renormalize_encoder
        @encoded += 1
      end

      def renormalize_encoder
        while @range < TOP
          @low <<= 8
          @range <<= 8
          @shifts += 1
        end
      end

      def start_decoder
        @code = 0
        WINDOW_SIZE.times { @code = (@code << 8) | read_encoded_byte }
        @range = (1 << (WINDOW_SIZE * 8)) - 1
        @decoded = 0
      end

      def decode_byte
        @range /= @total
        cum = @code / @range
        byte = byte_for_cumulative_frequency(cum)
        @code -= @cumulative[byte] * @range
        @range *= @freq[byte]
        renormalize_decoder
        byte
      end

      def renormalize_decoder
        while @range < TOP
          @code = ((@code << 8) | read_encoded_byte) & ((1 << (WINDOW_SIZE * 8)) - 1)
          @range <<= 8
        end
      end

      def byte_for_cumulative_frequency(cum)
        lo = 0
        hi = 255
        while lo < hi
          mid = (lo + hi + 1) / 2
          if @cumulative[mid] <= cum
            lo = mid
          else
            hi = mid - 1
          end
        end
        lo
      end

      def read_encoded_byte
        data = chain_read(1)
        raise EOFError, "end of file reached" if data.nil? || data.empty?

        data.unpack1('C')
      end

      def write_encoded_bytes(data)
        chain_write(data)
      end
    end
  end
end
