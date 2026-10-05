require 'bindata/base'

module BinData
  # A lossless block-delta encoded integer array.
  #
  #   require 'bindata'
  #
  #   values = Array.new(1000) { |i| i }
  #   values[500] = 1 << 200
  #   arr = BinData::BlockIntArray.new(values)
  #   encoded = arr.to_binary_s
  #
  #   decoded = BinData::BlockIntArray.read(encoded)
  #   decoded[500] # reads only the containing block
  #
  # Version 1 is exclusively little endian.  Its header contains magic
  # <tt>"BDBA"</tt>, version 1, one reserved zero byte, block size (u16),
  # payload end offset (u64) and total value count (u64).  Each 21-byte
  # directory entry contains block length (u16), common width (u8), payload
  # offset (u64), payload size (u64), and exception count (u16).
  #
  # A block payload contains the signed reference value in ZigZag LEB128,
  # followed by the signed common deltas packed as contiguous LSB-first bit
  # lanes.  Ascending u16 local indices identify exceptional deltas; their
  # signed values follow in ZigZag LEB128.  Tail blocks may be shorter than
  # the configured block size.
  #
  # Exception deltas are variable-length integers, so they are never wrapped,
  # clamped, shifted modulo 2**n, or otherwise truncated.
  #
  # Parameters:
  # <tt>:block_size</tt>:: Number of values per block, from 1 to 65535.
  #                        Defaults to 64.
  # <tt>:common_nbits</tt>:: Optional signed width to test for each non-reference
  #                        delta.  Values outside it remain exceptional; the
  #                        width is not used to truncate input.
  class BlockIntArray < BinData::Base
    include Enumerable

    arg_processor :block_int_array

    MAGIC = "BDBA".b
    FORMAT_VERSION = 1
    DIRECTORY_ENTRY_SIZE = 21
    MAX_BLOCK_SIZE = 65_535

    default_parameters block_size: 64
    optional_parameters :block_size, :common_nbits

    def initialize_instance
      @values = []
      @data = nil
      @directory = nil
      @count = 0
    end

    def clear?
      @data.nil? && @values.empty?
    end

    def assign(array)
      values = Kernel.Array(array)
      @values = values.map { |value| Codec.integer!(value) }
      @data = nil
      @directory = nil
      @count = @values.length
      self
    end

    def snapshot
      @data ? to_a : @values.dup
    end

    def length
      @count
    end
    alias size length

    def empty?
      length.zero?
    end

    def [](index)
      return nil unless index.respond_to?(:to_int)

      index = index.to_int
      index += length if index.negative?
      return nil unless index >= 0 && index < length
      return @values[index] unless @data

      block_index = index / block_size
      local_index = index % block_size
      block = @directory.fetch(block_index)
      resolved = Codec.resolve_block(block, @data)
      Codec.value_at(resolved, local_index, @data)
    end
    alias at []

    def each
      return enum_for(:each) unless block_given?
      return @values.each { |value| yield value } unless @data

      @directory.each do |block|
        Codec.decode_block(block, @data).each { |value| yield value }
      end
      self
    end

    def do_read(io) # :nodoc:
      header = io.readbytes(24)
      magic, version, _reserved, encoded_block_size, payload_end, count =
        header.unpack('a4CCvQ<Q<')

      raise ValidityError, "invalid BlockIntArray magic" unless magic == MAGIC
      raise ValidityError, "unsupported BlockIntArray version #{version}" unless
        version == FORMAT_VERSION
      raise ValidityError, "invalid BlockIntArray block size" unless
        encoded_block_size == block_size

      block_count = count.zero? ? 0 : (count + block_size - 1) / block_size
      data_start = header.bytesize + block_count * DIRECTORY_ENTRY_SIZE
      raise ValidityError, "invalid BlockIntArray payload offset" unless
        payload_end >= data_start

      directory_bytes = io.readbytes(block_count * DIRECTORY_ENTRY_SIZE)
      payload_size = payload_end - data_start
      payload = payload_size.zero? ? String.new.b : io.readbytes(payload_size)
      directory = Codec.parse_directory(directory_bytes, count, block_size,
                                        data_start, payload_end)

      @data = header + directory_bytes + payload
      @directory = directory
      @count = count
      @values = []
    end

    def do_write(io) # :nodoc:
      io.writebytes(Codec.encode(@values, block_size, fixed_width))
    end

    def do_num_bytes # :nodoc:
      Codec.encode(@values, block_size, fixed_width).bytesize
    end

    private

    def block_size
      eval_parameter(:block_size)
    end

    def fixed_width
      has_parameter?(:common_nbits) ? eval_parameter(:common_nbits) : nil
    end

    module Codec
      ResolvedBlock = Struct.new(:count, :width, :reference, :packed_offset,
                                 :packed_size, :indices_offset, :indices,
                                 :delta_offsets, keyword_init: true)

      module_function

      def encode(values, block_size, fixed_width)
        encoded_blocks = values.each_slice(block_size).map do |slice|
          encode_block(slice, fixed_width)
        end

        block_count = encoded_blocks.length
        data_start = 24 + block_count * DIRECTORY_ENTRY_SIZE
        offset = data_start
        directory = String.new.b
        payload = String.new.b

        encoded_blocks.each do |encoded|
          size = encoded[:payload].bytesize
          directory << [encoded[:count], encoded[:width], offset, size,
                        encoded[:exceptions]].pack('vCQ<Qv')
          payload << encoded[:payload]
          offset += size
        end

        header = [MAGIC, FORMAT_VERSION, 0, block_size, offset, values.length]
                 .pack('a4CCvQ<Q<')
        header + directory + payload
      end

      def parse_directory(bytes, count, block_size, data_start, payload_end)
        entries = []
        remaining = count
        expected_offset = data_start

        while bytes.bytesize >= DIRECTORY_ENTRY_SIZE
          entry = bytes.byteslice(0, DIRECTORY_ENTRY_SIZE)
          bytes = bytes.byteslice(DIRECTORY_ENTRY_SIZE..)
          block_count, width, offset, size, exception_count = entry.unpack('vCQ<Qv')

          unless block_count.positive? && block_count <= block_size &&
                 block_count <= remaining && size.positive? &&
                 offset == expected_offset && offset + size <= payload_end &&
                 (remaining == block_count ? offset + size == payload_end : true)
            raise ValidityError, "invalid BlockIntArray block length"
          end
          unless width <= 64 && exception_count < block_count
            raise ValidityError, "invalid BlockIntArray directory entry"
          end

          entries << [block_count, width, offset, exception_count, size]
          remaining -= block_count
          expected_offset = offset + size
        end

        starts_at_payload = entries.empty? ? data_start == payload_end :
                            entries.first.at(2) == data_start
        unless remaining.zero? && bytes.empty? && starts_at_payload
          raise ValidityError, "invalid BlockIntArray directory"
        end

        entries
      end

      def value_at(block, local_index, data)
        return block.reference if local_index.zero?

        value = block.reference
        exception_rank = 0
        regular_rank = 0

        (1..local_index).each do |position|
          if exception_rank < block.indices.length &&
             block.indices[exception_rank] == position
            value += signed_leb128_at(data, block.delta_offsets.fetch(exception_rank))
            exception_rank += 1
          else
            value += unpack_signed_at(data, block, regular_rank)
            regular_rank += 1
          end
        end

        value
      end

      def decode_block(entry, data)
        block = resolve_block(entry, data)
        values = ::Array.new(block.count)
        value = block.reference
        exception_rank = 0
        regular_rank = 0

        values[0] = value
        (1...block.count).each do |local_index|
          if exception_rank < block.indices.length &&
             block.indices[exception_rank] == local_index
            value += signed_leb128_at(data, block.delta_offsets.fetch(exception_rank))
            exception_rank += 1
          else
            value += unpack_signed_at(data, block, regular_rank)
            regular_rank += 1
          end
          values[local_index] = value
        end

        values
      end

      def resolve_block(entry, data)
        count, width, payload_offset, exception_count, entry_size = entry
        if payload_offset + entry_size > data.bytesize
          raise ValidityError, "truncated BlockIntArray block"
        end

        reference, reference_size = read_signed_leb128(data, payload_offset)
        regular_count = count - 1 - exception_count
        packed_size = (regular_count * width + 7) / 8
        packed_offset = payload_offset + reference_size
        indices_offset = packed_offset + packed_size
        indices_bytes = data.byteslice(indices_offset, exception_count * 2)
        indices = indices_bytes&.unpack('v*') || []
        delta_offsets = []
        offset = indices_offset + exception_count * 2

        packed_end = packed_offset + packed_size
        packed_value = data.byteslice(packed_offset, packed_size)
        used_bits = regular_count * width
        lane_padding_ok =
          if packed_size.zero?
            true
          else
            (used_bits...(packed_size * 8)).all? do |absolute_bit|
              byte = packed_value.getbyte(absolute_bit / 8)
              ((byte >> (absolute_bit % 8)) & 1).zero?
            end
          end

        unless lane_padding_ok && packed_end == indices_offset &&
               indices_offset + exception_count * 2 <= payload_offset + entry_size &&
               indices.length == exception_count &&
               indices.all? { |index| index > 0 && index < count } &&
               indices.each_cons(2).all? { |left, right| left < right }
          raise ValidityError, "invalid BlockIntArray exception table"
        end

        exception_count.times do |rank|
          delta_offsets[rank] = offset
          _, leb_size = read_signed_leb128(data, offset)
          offset += leb_size
        end

        unless offset == payload_offset + entry_size
          raise ValidityError, "invalid BlockIntArray block size"
        end

        ResolvedBlock.new(count: count, width: width, reference: reference,
                          packed_offset: packed_offset, packed_size: packed_size,
                          indices_offset: indices_offset, indices: indices,
                          delta_offsets: delta_offsets)
      end

      def integer!(value)
        unless value.is_a?(Integer)
          raise ArgumentError,
                "BlockIntArray values must be Integers, got #{value.class}"
        end

        value
      end

      def encode_block(values, fixed_width)
        reference = values.first || 0
        deltas = values.each_cons(2).map { |previous, current| current - previous }
        width = fixed_width || choose_width(deltas)
        regular = ::Array.new
        exceptions = ::Array.new

        deltas.each_with_index do |delta, local_index|
          if signed_fit?(delta, width)
            regular << delta
          else
            exceptions << [local_index + 1, delta]
          end
        end

        payload = encode_signed_leb128(reference)
        payload << pack_signed(regular, width)
        payload << exceptions.map(&:first).pack('v*')
        exceptions.each { |_, delta| payload << encode_signed_leb128(delta) }

        { count: values.length, width: width, exceptions: exceptions.length,
          payload: payload }
      end

      def choose_width(deltas)
        (0..64).min_by do |width|
          exceptions = deltas.reject { |delta| signed_fit?(delta, width) }
          regular_count = deltas.length - exceptions.length
          exception_bytes = exceptions.sum do |delta|
            encode_signed_leb128(delta).bytesize
          end
          (regular_count * width + 7) / 8 + exceptions.length * 2 + exception_bytes
        end
      end

      def signed_fit?(value, width)
        return value.zero? if width.zero?

        minimum = -(1 << (width - 1))
        maximum = (1 << (width - 1)) - 1
        value >= minimum && value <= maximum
      end

      def pack_signed(values, width)
        return String.new.b if values.empty? || width.zero?

        byte_count = (values.length * width + 7) / 8
        words = ::Array.new((byte_count + 7) / 8, 0)
        values.each_with_index do |value, value_index|
          unsigned = value & ((1 << width) - 1)
          bit_position = value_index * width

          while bit_position % 64 != 0 && unsigned != 0
            word_index = bit_position / 64
            word_bit = bit_position % 64
            available = 64 - word_bit
            bits = [available, width - (bit_position - value_index * width), 64].min
            chunk = unsigned & ((1 << bits) - 1)
            words[word_index] |= chunk << word_bit
            unsigned >>= bits
            bit_position += bits
          end

          while unsigned != 0
            word_index = bit_position / 64
            chunk = unsigned & ((1 << 64) - 1)
            words[word_index] |= chunk
            unsigned >>= 64
            bit_position += 64
          end
        end
        words.pack('Q<*').byteslice(0, byte_count)
      end

      def unpack_signed_at(data, block, rank)
        width = block.width
        return 0 if width.zero?

        bit_offset = rank * width
        value = 0
        width.times do |bit|
          absolute_bit = bit_offset + bit
          byte = data.getbyte(block.packed_offset + (absolute_bit / 8))
          value |= ((byte >> (absolute_bit % 8)) & 1) << bit
        end

        value -= (1 << width) if value >= (1 << (width - 1))
        value
      end

      def signed_leb128_at(data, offset)
        value, = read_signed_leb128(data, offset)
        value
      end

      def read_signed_leb128(data, offset)
        value = 0
        shift = 0
        size = 0

        loop do
          byte = data.getbyte(offset + size)
          raise ValidityError, "truncated BlockIntArray signed LEB128 value" if byte.nil?

          size += 1
          value |= (byte & 0x7f) << shift
          return [zigzag_decode(value), size] if byte < 0x80

          shift += 7
        end
      end

      def encode_signed_leb128(value)
        unsigned = zigzag_encode(value)
        bytes = ::Array.new

        loop do
          byte = unsigned & 0x7f
          unsigned >>= 7
          if unsigned != 0 || byte >= 0x40
            bytes << (byte | 0x80)
          else
            bytes << byte
            return bytes.pack('C*')
          end
        end
      end

      def zigzag_encode(value)
        if value.negative?
          ((-value) << 1) - 1
        else
          value << 1
        end
      end

      def zigzag_decode(value)
        (value >> 1) ^ -(value & 1)
      end
    end
  end

  class BlockIntArrayArgProcessor < BaseArgProcessor
    def sanitize_parameters!(_obj_class, params) # :nodoc:
      params.must_be_integer(:block_size, :common_nbits)

      if params.has_parameter?(:block_size)
        block_size = params[:block_size]
        unless block_size.positive? && block_size <= BlockIntArray::MAX_BLOCK_SIZE
          raise ArgumentError,
                ":block_size must be between 1 and #{BlockIntArray::MAX_BLOCK_SIZE}"
        end
      end

      if params.has_parameter?(:common_nbits)
        width = params[:common_nbits]
        unless width >= 0 && width <= 64
          raise ArgumentError, ":common_nbits must be between 0 and 64"
        end
      end
    end
  end
end
