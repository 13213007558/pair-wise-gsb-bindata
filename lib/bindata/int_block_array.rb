require 'bindata/base_primitive'

module BinData
  # A block encoded array of arbitrary Ruby integers.
  #
  # Each block stores a reference value, a commonly used signed bit width,
  # packed common differences, and an exception table for differences that do
  # not fit that width.  A block offset directory allows indexed reads to seek
  # directly to the required block without decoding any earlier block.
  #
  #   require 'bindata'
  #
  #   arr = BinData::IntBlockArray.new(block_size: 128, endian: :little)
  #   arr.assign([0, 1, -1, 1 << 200])
  #   binary = arr.to_binary_s
  #
  #   reader = BinData::IntBlockArray.read(binary)
  #   reader[3] #=> 1606938044258990275541962092341162602522202993782792835301376
  #
  # == Format version 1
  #
  # Multi-byte fields in the header and block offset directory use the byte
  # order recorded in the flags field.  All values are byte aligned except the
  # packed common differences, which are bit packed.  Little endian bit fields
  # pack the least significant bit first; big endian bit fields pack the most
  # significant bit first.
  #
  # The fixed header is:
  #
  #   Offset Size Field
  #   0      4    Magic, always "IBA1"
  #   4      1    Version, always 1
  #   5      1    Flags; bit 0 is 0 for little endian and 1 for big endian,
  #               all other bits must be zero
  #   6      2    Block size, between 1 and 65535
  #   8      4    Number of array elements
  #   12     8    Payload size in bytes (directory and blocks, not header)
  #   20     4    Number of blocks
  #
  # The payload starts with one unsigned 64 bit offset for every block.
  # Offsets are relative to the first byte after the directory.  The first
  # offset must be zero and offsets must strictly increase.
  #
  # Each block contains:
  #
  #   Size Field
  #   var  Reference value, signed ZigZag LEB128
  #   1    Common signed bit width, 0 through 64
  #   2    Number of exception entries
  #   var  Packed common differences, padded to a byte boundary
  #   var  Exception entries, sorted by local index
  #
  # Local index 0 stores the reference value directly.  Every later local
  # index stores value[index] - reference.  A common difference uses the
  # common bit width.  An exception entry stores its unsigned LEB128 local
  # index and its complete signed ZigZag LEB128 difference.  The encoder never
  # truncates an exception; values larger than signed 64 bit are therefore
  # preserved.  A truncated header or directory raises IOError while opening
  # the array.  A truncated block, packed field, or varint raises IOError when
  # that block is decoded; random access only decodes the selected block, while
  # sequential access decodes every block.  A final partial block is permitted
  # and contains only the elements left after all full blocks.  Trailing bytes
  # after the declared length are left unread so the type can be followed by
  # another field.
  class IntBlockArray < BasePrimitive
    optional_parameters :block_size, :endian
    arg_processor :int_block_array

    MAGIC = "IBA1"
    VERSION = 1
    HEADER_SIZE = 24
    DEFAULT_BLOCK_SIZE = 1024

    def initialize_instance
      @value = nil
      @codec = nil
      @encoded_data = nil
    end

    def clear?
      @codec.nil?
    end

    def assign(array)
      unless array.is_a?(::Array)
        raise ArgumentError, "can't assign #{array.class} to #{debug_name}"
      end

      values = array.dup
      values.each do |value|
        unless value.is_a?(Integer)
          raise ArgumentError, "all elements must be Integers"
        end
      end

      super(values)
      @codec = nil
      @encoded_data = nil
    end

    def snapshot
      @value ||= @codec ? @codec.decode_all : sensible_default
    end

    def [](index, length = nil)
      if @codec && length.nil? && index.is_a?(Integer)
        random_value(index)
      elsif length
        snapshot[index, length]
      else
        snapshot[index]
      end
    end

    def slice(index, length = nil)
      self[index, length]
    end

    def at(index)
      self[index]
    end

    def length
      snapshot.length
    end
    alias size length

    def empty?
      length.zero?
    end

    def each(&block)
      snapshot.each(&block)
    end

    def to_ary
      snapshot.dup
    end

    def value_at(index)
      self[index]
    end

    def do_read(io)
      header = io.readbytes(HEADER_SIZE)
      payload_size = Codec.read_payload_size(header)
      data = header + io.readbytes(payload_size)
      @codec = Codec.new(data)
      @value = nil
      @encoded_data = data
    end

    def value_to_binary_string(_value)
      encoded_data
    end

    def do_write(io)
      io.writebytes(encoded_data)
    end

    def do_num_bytes
      encoded_data.bytesize
    end

    def encoded_data
      @encoded_data ||= Codec.encode(
        snapshot,
        eval_parameter(:block_size),
        eval_parameter(:endian).endian
      )
    end

    def sensible_default
      []
    end

    private

    def random_value(index)
      index += @codec.count if index.negative?
      return nil if index.negative? || index >= @codec.count

      @codec.value_at(index)
    end

    class Codec
      class << self
        def encode(values, block_size, endian)
          block_bytes = []
          offsets = []
          blocks_size = 0

          values.each_slice(block_size) do |block_values|
            offsets << blocks_size
            bytes = encode_block(block_values, endian)
            block_bytes << bytes
            blocks_size += bytes.bytesize
          end

          directory = offsets.pack(offset_directive(endian) + '*')
          payload = directory + block_bytes.join
          count = values.length
          raise ArgumentError, "array is too large to encode" unless count <= 0xffffffff

          header = [
            IntBlockArray::MAGIC,
            IntBlockArray::VERSION,
            endian == :big ? 1 : 0,
            block_size,
            count,
            payload.bytesize,
            offsets.length
          ].pack(header_directive(endian))

          header + payload
        end

        def read_payload_size(header)
          ensure_header_length(header)
          endian = (header.getbyte(5) & 1).zero? ? :little : :big
          header.unpack1(payload_size_directive(endian))
        end

        private

        def encode_block(values, endian)
          reference = values.first
          differences = values[1..].map { |value| value - reference }
          width, exceptions = best_width_and_exceptions(differences)
          regular = differences.reject.with_index do |_, offset|
            exceptions.key?(offset + 1)
          end
          packed = write_packed(regular, width, endian)

          bytes = ::String.new(encoding: Encoding::BINARY)
          bytes.concat(write_svarint(reference))
          bytes << width.chr
          bytes.concat([exceptions.length].pack(count_directive(endian)))
          bytes << packed
          exceptions.each do |local_index, difference|
            bytes.concat(write_uvarint(local_index))
            bytes.concat(write_svarint(difference))
          end
          bytes
        end

        def best_width_and_exceptions(differences)
          best = nil

          (0..64).each do |width|
            exceptions = {}
            differences.each_with_index do |difference, offset|
              local_index = offset + 1
              unless fits_width?(difference, width)
                exceptions[local_index] = difference
              end
            end

            regular_count = differences.length - exceptions.length
            packed_bytes = (regular_count * width + 7) / 8
            exception_bytes = exceptions.sum do |index, difference|
              uvarint_size(index) + svarint_size(difference)
            end
            candidate = packed_bytes + exception_bytes

            if best.nil? || candidate < best.first
              best = [candidate, width, exceptions]
            end
          end

          [best[1], best[2]]
        end

        def fits_width?(value, width)
          return value.zero? if width.zero?

          limit = 1 << (width - 1)
          value >= -limit && value < limit
        end

        def write_uvarint(value)
          raise ArgumentError, "unsigned varint values must be non-negative" if value.negative?

          bytes = ::String.new(encoding: Encoding::BINARY)
          loop do
            byte = value & 0x7f
            value >>= 7
            if value.zero?
              bytes << byte.chr
              return bytes
            end
            bytes << (byte | 0x80).chr
          end
        end

        def write_svarint(value)
          write_uvarint((value << 1) ^ (value < 0 ? -1 : 0))
        end

        def uvarint_size(value)
          size = 1
          size += 1 until (value >>= 7).zero?
          size
        end

        def svarint_size(value)
          uvarint_size((value << 1) ^ (value < 0 ? -1 : 0))
        end

        def header_directive(endian)
          endian == :big ? 'a4CCnNQ>N' : 'a4CCvVQ<V'
        end

        def payload_size_directive(endian)
          endian == :big ? '@12Q>' : '@12Q<'
        end

        def offset_directive(endian)
          endian == :big ? 'Q>' : 'Q<'
        end

        def count_directive(endian)
          endian == :big ? 'n' : 'v'
        end

        def write_packed(values, width, endian)
          return "" if width.zero? || values.empty?

          bytes = ::String.new(encoding: Encoding::BINARY)
          accumulator = 0
          bits_in_accumulator = 0

          values.each do |value|
            width.times do |bit_index|
              bit = if endian == :big
                      (value >> (width - 1 - bit_index)) & 1
                    else
                      (value >> bit_index) & 1
                    end

              if endian == :big
                accumulator = (accumulator << 1) | bit
              else
                accumulator |= bit << bits_in_accumulator
              end
              bits_in_accumulator += 1

              if bits_in_accumulator == 8
                bytes << accumulator.chr
                accumulator = 0
                bits_in_accumulator = 0
              end
            end
          end

          if endian == :big && bits_in_accumulator.nonzero?
            bytes << ((accumulator << (8 - bits_in_accumulator)) & 0xff).chr
          elsif bits_in_accumulator.nonzero?
            bytes << accumulator.chr
          end
          bytes
        end
      end

      attr_reader :count

      def initialize(data)
        @data = data
        parse_header
        parse_directory
      end

      def decode_all
        result = []
        block_count.times do |block_index|
          result.concat(decode_block(block_index))
        end
        result
      end

      def value_at(index)
        block_index = index / block_size
        local_index = index % block_size
        decode_block(block_index)[local_index]
      end

      private

      attr_reader :block_size, :block_count, :offsets, :endian

      def parse_header
        self.class.send(:ensure_header_length, @data)
        magic = @data.byteslice(0, 4)
        raise IOError, "unknown integer block array magic" unless magic == IntBlockArray::MAGIC

        version = @data.getbyte(4)
        unless version == IntBlockArray::VERSION
          raise IOError, "unsupported integer block array version #{version}"
        end

        flags = @data.getbyte(5)
        raise IOError, "reserved integer block array flags are nonzero" unless (flags & ~1).zero?
        @endian = flags == 1 ? :big : :little

        @block_size = read_fixed_at(6, 2, 'n', 'v')
        unless @block_size.between?(1, 65535)
          raise IOError, "block size is outside the valid range"
        end

        @count = read_fixed_at(8, 4, 'N', 'V')
        payload_size = read_fixed_at(12, 8, 'Q>', 'Q<')
        @block_count = read_fixed_at(20, 4, 'N', 'V')
        expected_size = IntBlockArray::HEADER_SIZE + payload_size

        if @data.bytesize < expected_size
          raise IOError, "data is truncated"
        elsif @data.bytesize > expected_size
          raise IOError, "trailing bytes after integer block array"
        end

        expected_block_count = @count.zero? ? 0 : (@count - 1) / @block_size + 1
        unless @block_count == expected_block_count
          raise IOError, "block count does not match element count"
        end

        @blocks_size = payload_size - @block_count * 8
        raise IOError, "block offset directory is truncated" if @blocks_size.negative?
      end

      def parse_directory
        directory_size = @block_count * 8
        directory = @data.byteslice(IntBlockArray::HEADER_SIZE, directory_size)
        @offsets = directory.unpack(endian == :big ? 'Q>*' : 'Q<*')

        return if @block_count.zero?

        raise IOError, "first block offset must be zero" unless @offsets.first.zero?

        (1...@offsets.length).each do |index|
          next if @offsets[index] > @offsets[index - 1]

          raise IOError, "block offsets must be strictly increasing"
        end

        unless @offsets.last < @blocks_size
          raise IOError, "last block offset is outside block data"
        end
      end

      def decode_block(block_index)
        unless block_index >= 0 && block_index < @block_count
          raise IOError, "block index is outside block data"
        end

        local_count = [block_size, count - block_index * block_size].min
        block_data_start = IntBlockArray::HEADER_SIZE + @block_count * 8
        block_start = block_data_start + offsets[block_index]
        block_end = if block_index + 1 < block_count
                      block_data_start + offsets[block_index + 1]
                    else
                      @data.bytesize
                    end

        pos = block_start
        reference, pos = read_svarint(pos, block_end)

        width = read_byte(pos)
        pos += 1
        unless width.between?(0, 64)
          raise IOError, "common bit width is outside the valid range"
        end

        exception_count = read_fixed_at(pos, 2, 'n', 'v')
        pos += 2
        regular_count = local_count - 1 - exception_count
        if regular_count.negative?
          raise IOError, "exception count exceeds block element count"
        end

        packed_size = (regular_count * width + 7) / 8
        packed_start = pos
        packed_end = packed_start + packed_size
        if packed_end > block_end
          raise IOError, "packed common differences are truncated"
        end
        packed = @data.byteslice(packed_start, packed_size)
        pos = packed_end

        values = ::Array.new(local_count)
        values[0] = reference

        exceptions = {}
        exception_count.times do
          local_index, next_pos = read_uvarint(pos, block_end)
          pos = next_pos
          unless local_index.between?(1, local_count - 1)
            raise IOError, "exception index is outside the block"
          end
          if exceptions.key?(local_index)
            raise IOError, "exception index is duplicated"
          end

          difference, next_pos = read_svarint(pos, block_end)
          pos = next_pos
          exceptions[local_index] = difference
        end

        unless exceptions.keys == exceptions.keys.sort
          raise IOError, "exception table must be sorted by index"
        end

        packed_ordinal = 0
        (1...local_count).each do |local_index|
          if exceptions.key?(local_index)
            values[local_index] = reference + exceptions[local_index]
          else
            values[local_index] = reference + read_packed_value(packed, width, packed_ordinal)
            packed_ordinal += 1
          end
        end

        raise IOError, "trailing bytes in block" unless pos == block_end
        values
      end

      def read_fixed_at(offset, size, big_directive, little_directive)
        bytes = @data.byteslice(offset, size)
        if bytes.nil? || bytes.bytesize < size
          raise IOError, "data is truncated"
        end

        bytes.unpack1(endian == :big ? big_directive : little_directive)
      end

      def read_byte(pos)
        byte = @data.getbyte(pos)
        raise IOError, "data is truncated" if byte.nil?
        byte
      end

      def read_uvarint(pos, limit)
        value = 0
        shift = 0
        continuation_seen = false

        loop do
          raise IOError, "data is truncated" if pos >= limit

          byte = @data.getbyte(pos)
          pos += 1
          chunk = byte & 0x7f

          if byte <= 0x7f
            if continuation_seen && chunk.zero?
              raise IOError, "unsigned varint is not minimally encoded"
            end
            return [value | (chunk << shift), pos]
          end

          value |= chunk << shift
          shift += 7
          continuation_seen = true
        end
      end

      def read_svarint(pos, limit)
        zigzag, pos = read_uvarint(pos, limit)
        value = zigzag.even? ? zigzag / 2 : -(zigzag >> 1) - 1
        [value, pos]
      end

      def read_packed_value(bytes, width, ordinal)
        return 0 if width.zero?

        value = 0
        first_bit = ordinal * width

        if endian == :little
          width.times do |bit_index|
            bit_position = first_bit + bit_index
            byte_index = bit_position / 8
            byte_offset = bit_position % 8
            value |= ((bytes.getbyte(byte_index) >> byte_offset) & 1) << bit_index
          end
        else
          width.times do |bit_index|
            bit_position = first_bit + bit_index
            byte_index = bit_position / 8
            byte_offset = bit_position % 8
            value = (value << 1) | ((bytes.getbyte(byte_index) >> (7 - byte_offset)) & 1)
          end
        end

        sign_extend(value, width)
      end

      def sign_extend(value, width)
        sign_bit = 1 << (width - 1)
        if value & sign_bit == 0
          value
        else
          value - (1 << width)
        end
      end

      def self.ensure_header_length(data)
        if data.nil? || data.bytesize < IntBlockArray::HEADER_SIZE
          raise IOError, "data is truncated"
        end
      end
      private_class_method :ensure_header_length
    end

    private_constant :Codec
  end

  class IntBlockArrayArgProcessor < BaseArgProcessor
    def sanitize_parameters!(_obj_class, params)
      params[:block_size] = params.fetch(:block_size, IntBlockArray::DEFAULT_BLOCK_SIZE)
      unless params[:block_size].is_a?(Integer) &&
             params[:block_size].between?(1, 65535)
        raise ArgumentError, "block_size must be an Integer between 1 and 65535"
      end

      params[:endian] = :little unless params.has_key?(:endian)
      params.sanitize_endian(:endian)
    end
  end
end
