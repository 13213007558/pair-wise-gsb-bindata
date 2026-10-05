module BinData
  class FrameError < IOError
    attr_reader :discarded_range, :reason

    def initialize(message, reason:, discarded_range:)
      @discarded_range = discarded_range
      @reason = reason

      super(message)
    end
  end

  module Transform
    # HDLC-style bit stuffing.
    #
    # Frames are delimited by the bit sequence 01111110.  A zero inserted
    # after five consecutive one bits is removed while reading.  Seven
    # consecutive ones is an abort.  The frame check is validated on the
    # unstuffed data.
    #
    # Only the current raw byte and frame are buffered, so a complete
    # connection does not need to be held in memory.
    class HDLC < BinData::IO::Transform
      transform_changes_stream_length!

      DEFAULT_MAX_FRAME_BYTES = 65535
      READ_BLOCK_SIZE = 1

      def initialize(bit_order:, frame_check: :crc16,
                     max_frame_bytes: DEFAULT_MAX_FRAME_BYTES,
                     on_frame_error: nil)
        super()

        @bit_order = normalize_bit_order(bit_order)
        @frame_check = normalize_frame_check(frame_check)
        @max_frame_bytes = max_frame_bytes
        @on_frame_error = on_frame_error

        unless @frame_check.nil? || @frame_check == :crc16
          raise ArgumentError, "unsupported frame check #{frame_check.inspect}"
        end

        if on_frame_error && !on_frame_error.respond_to?(:call)
          raise ArgumentError, "on_frame_error must respond to #call"
        end
      end

      def before_transform
        reset_decoder
      end

      def read(n = nil)
        scan until frame_available? || source_eof?

        if frame_available?
          take_payload(n)
        elsif n
          raise EOFError, "End of file reached"
        else
          create_empty_binary_string
        end
      end

      def write(data)
        @write ||= create_empty_binary_string
        @write << data
      end

      def after_write_transform
        chain_write(frame_data(@write || create_empty_binary_string))
        @write = nil
      end

      # Returns the CRC-16 used by HDLC.  For +:little+ the CRC is reflected
      # and serialized least significant byte first.  For +:big+ it is not
      # reflected and serialized most significant byte first.
      def self.crc16(data, bit_order = :little)
        bit_order = normalize_bit_order(bit_order)
        crc = 0xffff

        if bit_order == :little
          data.each_byte do |byte|
            crc ^= byte
            8.times do
              crc = if crc.odd?
                      (crc >> 1) ^ 0x8408
                    else
                      crc >> 1
                    end
            end
          end
        else
          data.each_byte do |byte|
            crc ^= byte << 8
            8.times do
              crc <<= 1
              crc ^= 0x1021 unless (crc & 0x10000).zero?
              crc &= 0xffff
            end
          end
        end

        crc ^ 0xffff
      end

      #---------------
      private

      def self.normalize_bit_order(bit_order)
        case bit_order
        when :little, :lsb then :little
        when :big, :msb then :big
        else
          raise ArgumentError,
                "bit_order must be :little or :big, got #{bit_order.inspect}"
        end
      end

      def normalize_bit_order(bit_order)
        self.class.send(:normalize_bit_order, bit_order)
      end

      def normalize_frame_check(frame_check)
        unless frame_check.nil? || Symbol === frame_check ||
               frame_check.respond_to?(:to_str)
          raise ArgumentError,
                "frame_check must be :crc16, :none or nil"
        end

        frame_check = frame_check.to_sym unless frame_check.nil? || Symbol === frame_check
        return nil if frame_check == :none

        frame_check
      end

      def reset_decoder
        @mode = :hunt
        @ones = 0
        @awaiting_open_zero = false
        @consumed_bits = 0
        @frame_start_bit = nil
        @frame_bytes = []
        @frame_bit_count = 0
        @oversized = false
        @frame = nil
        @source_eof = false
        @pending_bits = []
      end

      def frame_available?
        !@frame.nil?
      end

      def source_eof?
        @source_eof
      end

      def take_payload(n)
        if n.nil?
          @frame.dup.tap { @frame = nil }
        elsif @frame.size < n
          raise IOError, "data truncated"
        else
          @frame.slice!(0, n).tap { @frame = nil if @frame.empty? }
        end
      end

      def scan
        return if frame_available?

        unless read_raw_bit
          @source_eof = true
          if frame_in_progress?
            report_frame_error("unterminated HDLC frame", :unterminated)
          end
        end
      end

      def read_raw_bit
        if @pending_bits.empty?
          chunk = chain_read(READ_BLOCK_SIZE)
          return false if chunk.nil? || chunk.empty?

          @pending_bits = bits_in_byte(chunk.unpack1('C'))
        end

        bit = @pending_bits.shift
        @consumed_bits += 1
        receive_raw_bit(bit)
        true
      end

      def bits_in_byte(byte)
        if @bit_order == :little
          (0...8).map { |index| (byte >> index) & 1 }
        else
          (0...8).map { |index| (byte >> (7 - index)) & 1 }
        end
      end

      def receive_raw_bit(bit)
        if @mode == :hunt
          receive_hunt_bit(bit)
        else
          receive_frame_bit(bit)
        end
      end

      def frame_in_progress?
        [:frame, :six_ones].include?(@mode)
      end

      def receive_hunt_bit(bit)
        if bit.zero?
          @ones = 0
          return
        end

        @ones += 1
        if @ones == 6
          @mode = :frame
          @ones = 0
          @awaiting_open_zero = true
          @frame_start_bit = @consumed_bits - 7
          start_frame
        elsif @ones >= 7
          @ones = 0
        end
      end

      def receive_frame_bit(bit)
        if @awaiting_open_zero
          if bit.zero?
            @awaiting_open_zero = false
            return
          else
            report_frame_error("HDLC frame aborted", :abort)
            return
          end
        end

        if bit.zero?
          receive_frame_zero
        else
          @ones += 1
          if @ones == 7
            report_frame_error("HDLC frame aborted", :abort)
          elsif @ones == 6
            @mode = :six_ones
          elsif @ones < 6
            append_decoded_bit(1)
          end
        end
      end

      def receive_frame_zero
        if @mode == :six_ones
          complete_closing_frame
        elsif @ones == 5
          @ones = 0
        else
          append_decoded_bit(0)
          @ones = 0
        end
      end

      def complete_closing_frame
        rollback_decoded_bits(6)
        complete_frame
        enter_hunt_state if frame_available?
      end

      def start_frame
        @frame_bytes = []
        @frame_bit_count = 0
        @oversized = false
      end

      def append_decoded_bit(bit)
        return if @oversized

        byte_index = @frame_bit_count / 8
        bit_index = if @bit_order == :little
                      @frame_bit_count % 8
                    else
                      7 - (@frame_bit_count % 8)
                    end

        @frame_bytes[byte_index] ||= 0
        @frame_bytes[byte_index] |= bit << bit_index
        @frame_bit_count += 1

        if @max_frame_bytes && decoded_byte_count > max_frame_bytes
          @oversized = true
          @frame_bytes = []
        end
      end

      def decoded_byte_count
        (@frame_bit_count + 7) / 8
      end

      def rollback_decoded_bits(nbits)
        new_count = [@frame_bit_count - nbits, 0].max
        full_bytes, remaining_bits = new_count.divmod(8)
        kept_bytes = @frame_bytes.first(full_bytes)

        if remaining_bits.positive?
          mask = if @bit_order == :little
                   (1 << remaining_bits) - 1
                 else
                   ((1 << remaining_bits) - 1) << (8 - remaining_bits)
                 end
          kept_bytes << (@frame_bytes[full_bytes] & mask)
        end

        @frame_bytes = kept_bytes
        @frame_bit_count = new_count
      end

      def max_frame_bytes
        value = @max_frame_bytes.respond_to?(:call) ?
                  @max_frame_bytes.call : @max_frame_bytes
        value&.to_int
      end

      def complete_frame
        if @frame_bit_count.zero?
          enter_hunt_state
          return
        end

        if @oversized
          report_frame_error("HDLC frame exceeds maximum size", :too_long)
        elsif (@frame_bit_count % 8).nonzero?
          report_frame_error("HDLC frame is not byte aligned", :not_aligned)
        elsif @frame_check == :crc16
          complete_checked_frame
        else
          deliver_frame(decoded_bytes)
        end
      end

      def complete_checked_frame
        if @frame_bit_count < 16
          report_frame_error("HDLC frame check is missing", :missing_frame_check)
          return
        end

        bytes = decoded_bytes
        payload = bytes[0...-2]
        check = bytes[-2..]
        expected = frame_check_bytes(payload)

        if check == expected
          deliver_frame(payload)
        else
          report_frame_error("HDLC frame check failed", :invalid_frame_check)
        end
      end

      def decoded_bytes
        @frame_bytes.pack('C*').force_encoding(Encoding::BINARY)
      end

      def frame_check_bytes(data)
        crc = self.class.crc16(data, @bit_order)
        values = if @bit_order == :little
                   [crc & 0xff, (crc >> 8) & 0xff]
                 else
                   [(crc >> 8) & 0xff, crc & 0xff]
                 end
        values.pack('CC')
      end

      def deliver_frame(payload)
        @frame = payload
        enter_hunt_state
      end

      def report_frame_error(message, reason)
        error = FrameError.new(message, reason: reason,
                              discarded_range: current_discarded_range)
        enter_hunt_state

        if @on_frame_error
          @on_frame_error.call(error)
        else
          raise error
        end
      end

      def current_discarded_range
        ending_bit = @consumed_bits
        start_bit = @frame_start_bit || ending_bit
        [start_bit, ending_bit]
      end

      def enter_hunt_state
        @mode = :hunt
        @ones = 0
        @awaiting_open_zero = false
        @frame_start_bit = nil
        @frame_bytes = []
        @frame_bit_count = 0
        @oversized = false
      end

      def frame_data(data)
        checked = add_frame_check(data)
        bits = flag_bits + stuffed_bits(checked) + flag_bits
        bits.concat([1] * ((8 - (bits.length % 8)) % 8))
        pack_bits(bits)
      end

      def add_frame_check(data)
        return data if @frame_check.nil?

        data.dup.force_encoding(Encoding::BINARY) << frame_check_bytes(data)
      end

      def flag_bits
        [0, 1, 1, 1, 1, 1, 1, 0]
      end

      def stuffed_bits(data)
        result = []
        ones = 0

        data.each_byte do |byte|
          bits_in_byte(byte).each do |bit|
            result << bit
            if bit.zero?
              ones = 0
            else
              ones += 1
              if ones == 5
                result << 0
                ones = 0
              end
            end
          end
        end

        result
      end

      def pack_bits(bits)
        values = bits.each_slice(8).map do |slice|
          slice.each_with_index.inject(0) do |byte, (bit, index)|
            shift = @bit_order == :little ? index : 7 - index
            byte | (bit << shift)
          end
        end

        values.pack('C*')
      end
    end
  end
end
