module BinData
  module Transform
    # HDLC-like framing with bit stuffing.
    #
    # The wire stream consists of frames delimited by the flag bit pattern
    # 01111110.  Five consecutive 1 bits in frame data are followed by a
    # stuffed 0.  Seven consecutive 1 bits abort the current frame.
    #
    # The inner stream contains frame data with its 16 bit CRC-CCITT FCS.
    # Stuffed bits are removed before the FCS is checked.  +bit_order+
    # selects whether wire bytes are transmitted most-significant bit first
    # (+:big+ / +:msb+) or least-significant bit first (+:little+ / +:lsb+).
    #
    # Invalid frames are reported to +on_invalid_frame+.  The receiver has
    # already discarded the frame when the callback runs, and continues
    # searching for the next opening flag.  Without a callback, an
    # InvalidFrameError is raised.  Reading after rescuing that error also
    # continues from the next frame.
    class HDLC < BinData::IO::Transform
      transform_changes_stream_length!

      FLAG_BITS = [0, 1, 1, 1, 1, 1, 1, 0].freeze
      FCS_LENGTH = 2
      READ_CHUNK_SIZE = 1

      def self.crc16(data, bit_order)
        crc = 0xffff
        polynomial = bit_order == :little ? 0x8408 : 0x1021

        data.each_byte do |input_byte|
          8.times do
            if bit_order == :little
              bit = crc & 1
              crc >>= 1
            else
              bit = (crc >> 15) & 1
              crc = (crc << 1) & 0xffff
            end
            if bit_order == :little
              input_bit = input_byte & 1
              input_byte >>= 1
            else
              input_bit = (input_byte >> 7) & 1
              input_byte = (input_byte << 1) & 0xff
            end
            crc ^= polynomial if bit != input_bit
          end
        end

        crc
      end

      class InvalidFrameError < BinData::ValidityError
        attr_reader :reason, :bit_range, :byte_range, :discard_range

        def initialize(reason, bit_range)
          @reason = reason
          @bit_range = bit_range
          start_byte = bit_range.begin / 8
          end_byte = bit_range.end / 8
          @byte_range = start_byte...end_byte
          @discard_range = @byte_range

          super("#{reason_message} in HDLC frame; " \
                "discarded bits #{bit_range.begin}...#{bit_range.end} " \
                "(bytes #{start_byte}...#{end_byte})")
        end

        private

        def reason_message
          case reason
          when :abort then "abort received"
          when :alignment then "frame is not byte aligned"
          when :too_short then "frame is shorter than its FCS"
          when :truncated then "truncated frame before closing flag"
          else "FCS mismatch"
          end
        end
      end

      class Decoder
        Event = ::Struct.new(:valid, :payload, :reason, :start_bit, :end_bit)

        attr_reader :bit_position

        def initialize(bit_order)
          @bit_order = bit_order
          @events = []
          reset_connection
        end

        def feed(data)
          data.each_byte do |byte|
            bits = @bit_order == :little ? 0.upto(7) : 7.downto(0)
            bits.each do |index|
              process_bit((byte >> index) & 1)
            end
          end
          drain_events
        end

        # Bits are supplied chronologically.  This allows callers to split a
        # stream on any bit boundary rather than only on byte boundaries.
        def feed_bits(bits)
          bits.each { |bit| process_bit(bit) }
          drain_events
        end

        def flush
          if @state == :frame && frame_started?
            report_invalid(:truncated, @frame_start, @bit_position)
          end
          reset_frame
          drain_events
        end

        private

        def reset_connection
          @state = :idle
          @bit_position = 0
          reset_frame
        end

        def reset_frame
          @frame_start = nil
          @payload = BitBuffer.new(@bit_order)
          @ones = 0
          @pending_zero = false
        end

        def frame_started?
          @payload.total_nbits.positive? || @pending_zero ||
            @ones.positive?
        end

        def process_bit(bit)
          current_position = @bit_position
          @bit_position += 1

          if bit == 1
            process_one(current_position)
          else
            process_zero(current_position)
          end
        end

        def process_one(position)
          @ones += 1

          if @state == :frame && @ones == 7
            report_invalid(:abort, @frame_start, position + 1)
            @state = :idle
            reset_frame
          end
        end

        def process_zero(position)
          if @ones == 6
            end_bit = position + 1
            if @state == :frame
              finish_frame(end_bit)
            else
              start_frame(end_bit - 8)
            end
          elsif @state == :frame
            if @ones == 5
              @payload.write_bit(0) if @pending_zero
              @payload.write_ones(5)
              @pending_zero = false
            else
              @payload.write_bit(0) if @pending_zero
              @payload.write_ones(@ones)
              @pending_zero = true
            end
          end

          @ones = 0
        end

        def start_frame(start_bit)
          @state = :frame
          @frame_start = start_bit
          @payload = BitBuffer.new(@bit_order)
          @ones = 0
          @pending_zero = false
        end

        def finish_frame(end_bit)
          nbits = @payload.total_nbits

          if nbits.zero?
            # A closing flag may also open the next back-to-back frame.
            start_frame(end_bit - 8)
            return
          end

          if nbits % 8 != 0
            reason = :alignment
          elsif nbits < FCS_LENGTH * 8
            reason = :too_short
          else
            content = @payload.string
            reason = :fcs unless valid_fcs?(content)
          end

          if reason.nil?
            @events << Event.new(true, content[0...-FCS_LENGTH], nil,
                                @frame_start, end_bit)
            # A valid closing flag may also open the next back-to-back frame.
            start_frame(end_bit - 8)
          else
            report_invalid(reason, @frame_start, end_bit)
            @state = :idle
            reset_frame
          end
        end

        def report_invalid(reason, start_bit, end_bit)
          @events << Event.new(false, nil, reason, start_bit, end_bit)
        end

        def drain_events
          @events.shift(@events.size)
        end

        def valid_fcs?(content)
          expected = @bit_order == :little ? 0xf0b8 : 0x1d0f
          HDLC.crc16(content, @bit_order) == expected
        end

        class BitBuffer
          attr_reader :nbits

          def total_nbits
            @bytes.size * 8 + @nbits
          end

          def initialize(bit_order)
            @bit_order = bit_order
            @bytes = create_binary_string
            @current_byte = 0
            @nbits = 0
          end

          def write_bit(bit)
            if @bit_order == :little
              @current_byte |= bit << @nbits
            else
              @current_byte = (@current_byte << 1) | bit
            end

            @nbits += 1
            flush_byte if @nbits == 8
          end

          def write_ones(count)
            count.times { write_bit(1) }
          end

          def string
            result = @bytes.dup
            result << @current_byte.chr if @nbits.positive?
            result
          end

          private

          def flush_byte
            @bytes << @current_byte.chr
            @current_byte = 0
            @nbits = 0
          end

          def create_binary_string
            String.new.force_encoding(Encoding::BINARY)
          end
        end
      end

      def initialize(bit_order: :little, on_invalid_frame: nil, on_error: nil)
        super()
        @bit_order = normalize_bit_order(bit_order)
        @on_invalid_frame = on_invalid_frame || on_error
      end

      def before_transform
        @decoder = Decoder.new(@bit_order)
        @read_buffer = create_empty_binary_string
        @write_buffer = create_empty_binary_string
      end

      def encode_frame(payload)
        private_encode_frame(payload)
      end

      def read(n = nil)
        while n.nil? || @read_buffer.bytesize < n
          data = chain_read(READ_CHUNK_SIZE)
          break if data.nil?
          consume_decoder_events(@decoder.feed(data))
        end

        if n.nil? || @read_buffer.bytesize < n
          consume_decoder_events(@decoder.flush)
        end

        return @read_buffer.slice!(0..-1) if n.nil?

        if @read_buffer.bytesize < n
          raise EOFError, "end of HDLC stream reached before #{n} bytes"
        end

        @read_buffer.slice!(0, n)
      end

      def write(data)
        @write_buffer << data
      end

      def after_write_transform
        chain_write(private_encode_frame(@write_buffer))
      end

      private

      def normalize_bit_order(bit_order)
        case bit_order
        when :big, :msb, :msb_first, :most_significant_bit_first then :big
        when :little, :lsb, :lsb_first, :least_significant_bit_first then :little
        else raise ArgumentError, "unknown HDLC bit order #{bit_order.inspect}"
        end
      end

      def consume_decoder_events(events)
        until events.empty?
          event = events.shift
          if event.valid
            @read_buffer << event.payload
          else
            error = InvalidFrameError.new(event.reason,
                                         event.start_bit...event.end_bit)
            if @on_invalid_frame
              @on_invalid_frame.call(error)
            else
              raise error
            end
          end
        end
      end

      def private_encode_frame(payload)
        content = payload.dup.force_encoding(Encoding::BINARY)
        fcs = HDLC.crc16(content, @bit_order) ^ 0xffff
        template = @bit_order == :little ? 'S<' : 'S>'
        content << [fcs].pack(template)

        bits = String.new.force_encoding(Encoding::BINARY)
        current_byte = 0
        nbits = 0
        consecutive_ones = 0

        emit = lambda do |bit|
          if @bit_order == :little
            current_byte |= bit << nbits
          else
            current_byte = (current_byte << 1) | bit
          end
          nbits += 1
          if nbits == 8
            bits << current_byte.chr
            current_byte = 0
            nbits = 0
          end
        end

        FLAG_BITS.each { |bit| emit.call(bit) }
        content.each_byte do |byte|
          8.times do |index|
            bit_index = @bit_order == :little ? index : 7 - index
            bit = (byte >> bit_index) & 1
            emit.call(bit)
            if bit == 1
              consecutive_ones += 1
              if consecutive_ones == 5
                emit.call(0)
                consecutive_ones = 0
              end
            else
              consecutive_ones = 0
            end
          end
        end
        FLAG_BITS.each { |bit| emit.call(bit) }

        while nbits.positive?
          emit.call(1)
        end
        bits
      end

    end
  end
end
