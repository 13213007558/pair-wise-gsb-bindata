require 'bindata/io'

module BinData
  module Transform
    # Systematic Reed-Solomon erasure coding over GF(2^8).
    #
    # The encoded stream starts with a self describing header.  Data blocks
    # are stored first, followed by parity blocks.  A short final data block
    # is zero padded.  Erased block positions are supplied by the caller; this
    # transform does not attempt to locate or correct unknown errors.
    #
    # Positions are zero based block indexes across data and parity blocks.
    class ReedSolomon < BinData::IO::Transform
      transform_changes_stream_length!

      MAGIC = "BDRS1".dup.force_encoding(Encoding::BINARY).freeze
      VERSION = 1
      HEADER_FORMAT = "a5CCCCQ>"
      HEADER_SIZE = 17
      SHORT_FINAL_BLOCK = 0x01

      class ErasureError < IOError; end
      class FormatError < IOError; end

      module GF256
        POLYNOMIAL = 0x11d

        EXP = ::Array.new(512, 1)
        LOG = ::Array.new(256, 0)

        value = 1
        255.times do |index|
          EXP[index] = value
          LOG[value] = index
          value <<= 1
          value ^= POLYNOMIAL if value >= 256
        end
        EXP[255] = 1
        256.upto(511) { |index| EXP[index] = EXP[index - 255] }

        def self.multiply(left, right)
          return 0 if left.zero? || right.zero?
          EXP[LOG[left] + LOG[right]]
        end

        def self.inverse(value)
          raise ArgumentError, "zero has no multiplicative inverse" if value.zero?
          EXP[255 - LOG[value]]
        end
      end

      def self.encode(data, data_shards, parity_shards)
        new(data_shards: data_shards, parity_shards: parity_shards).send(:encode_stream, data)
      end

      def self.decode(encoded, erased_shards = [])
        new(erased_shards: erased_shards).send(:decode_stream, encoded)
      end

      def initialize(*args, **options)
        super()

        positional_data_shards, positional_parity_shards, positional_erasures = args
        @data_shards = options.fetch(:data_shards) do
          options[:k] || options[:data_blocks] || positional_data_shards
        end
        @parity_shards = options.fetch(:parity_shards) do
          options[:m] || options[:parity_blocks] || positional_parity_shards
        end
        @erased_shards = normalize_erasures(
          options[:erased_shards] ||
            options[:erased_blocks] ||
            options[:erasures] ||
            options[:missing_shards] ||
            options[:missing_blocks] ||
            positional_erasures ||
            []
        )
      end

      def read(length)
        @read ||= decode_remaining_stream
        if length.nil?
          @read.slice!(0, @read.bytesize)
        else
          result = @read.slice!(0, length)
          raise IOError, "data truncated" if result.nil? || result.bytesize < length
          result
        end
      end

      def num_bytes_remaining
        @read ? @read.bytesize : chain_num_bytes_remaining
      end

      def write(data)
        @write ||= ::String.new.force_encoding(Encoding::BINARY)
        @write << data.to_s.dup.force_encoding(Encoding::BINARY)
      end

      def after_read_transform
        return unless @read
        raise IOError, "didn't read all data" unless @read.empty?
      end

      def after_write_transform
        chain_write(encode_stream(@write || ::String.new.force_encoding(Encoding::BINARY)))
      end

      private

      def normalize_erasures(erasures)
        erasures = erasures.to_a.map do |position|
          unless position.is_a?(Integer)
            raise ArgumentError, "erasure positions must be integers"
          end
          position
        end

        if erasures.any?(&:negative?) || erasures.uniq.size != erasures.size
          raise ArgumentError, "erasure positions must be unique non-negative integers"
        end

        erasures
      end

      def validate_parameters!
        unless @data_shards.is_a?(Integer) && @parity_shards.is_a?(Integer)
          raise ArgumentError, "data_shards and parity_shards are required"
        end
        unless @data_shards.positive? && @parity_shards.positive?
          raise ArgumentError, "data_shards and parity_shards must be positive"
        end
        if @data_shards + @parity_shards > 256
          raise ArgumentError, "data_shards and parity_shards cannot exceed 256 blocks"
        end
      end

      def encode_stream(data)
        validate_parameters!
        unless @erased_shards.empty?
          raise ArgumentError, "erased_shards cannot be specified when encoding"
        end

        data = data.to_s.dup.force_encoding(Encoding::BINARY)
        shard_size = shard_size_for(data.bytesize, @data_shards)
        return header_for(0, shard_size) if data.empty?
        data_blocks = data_blocks_for(data, shard_size)
        parity_blocks = parity_blocks_for(data_blocks)

        header_for(data.bytesize, shard_size) + data_blocks.join + parity_blocks.join
      end

      def decode_remaining_stream
        validate_erasure_count!(@parity_shards)
        encoded = chain_read(HEADER_SIZE)
        if encoded.nil? || encoded.bytesize < HEADER_SIZE
          raise FormatError, "Reed-Solomon header is truncated"
        end

        data_shards, parity_shards, original_length, shard_size = parse_header(encoded)
        total_shards = data_shards + parity_shards
        validate_erasure_positions!(total_shards, parity_shards)

        surviving_shards = (total_shards - @erased_shards.size) * shard_size
        payload = chain_read(surviving_shards)
        if payload.nil? || payload.bytesize != surviving_shards
          raise FormatError, "Reed-Solomon payload is truncated"
        end

        recover_data(payload, data_shards, total_shards, shard_size, original_length)
      end

      def decode_stream(encoded)
        io = BinData::IO.create_string_io(encoded.to_s)
        prepend_to_chain(BinData::IO::RawIO.new(io))
        result = read(nil)
        after_read_transform
        result
      end

      def parse_header(header)
        magic, version, data_shards, parity_shards, flags, original_length =
          header.unpack(HEADER_FORMAT)

        unless magic == MAGIC && version == VERSION
          raise FormatError, "invalid Reed-Solomon header"
        end
        if data_shards.zero? || parity_shards.zero? ||
           data_shards + parity_shards > 256
          raise FormatError, "invalid Reed-Solomon shard counts"
        end
        unless original_length.is_a?(::Integer) && original_length >= 0
          raise FormatError, "invalid Reed-Solomon original length"
        end
        unless @data_shards.nil? || @data_shards == data_shards
          raise FormatError, "Reed-Solomon data_shards mismatch"
        end
        unless @parity_shards.nil? || @parity_shards == parity_shards
          raise FormatError, "Reed-Solomon parity_shards mismatch"
        end
        if flags & ~SHORT_FINAL_BLOCK != 0
          raise FormatError, "unsupported Reed-Solomon flags"
        end

        shard_size = shard_size_for(original_length, data_shards)
        short_final_block = short_final_block?(original_length, shard_size, data_shards)
        unless (flags & SHORT_FINAL_BLOCK != 0) == short_final_block
          raise FormatError, "invalid Reed-Solomon short block flag"
        end

        [data_shards, parity_shards, original_length, shard_size]
      end

      def validate_erasure_positions!(total_shards, parity_shards)
        if @erased_shards.any? { |position| position >= total_shards }
          raise ErasureError, "erasure position is outside the encoding group"
        end
        if @erased_shards.size > parity_shards
          raise ErasureError,
            "#{@erased_shards.size} erasures exceed recovery capacity of #{parity_shards}"
        end
      end

      def validate_erasure_count!(parity_shards)
        if parity_shards
          return if @erased_shards.size <= parity_shards
          capacity = parity_shards
        else
          return if @erased_shards.size <= 255
          capacity = 255
        end

        raise ErasureError,
          "#{@erased_shards.size} erasures exceed recovery capacity of #{capacity}"
      end

      def shard_size_for(length, data_shards)
        return 0 if length.zero?
        (length + data_shards - 1) / data_shards
      end

      def short_final_block?(length, shard_size, data_shards)
        length.positive? && length < shard_size * data_shards
      end

      def header_for(length, shard_size)
        flags = short_final_block?(length, shard_size, @data_shards) ? SHORT_FINAL_BLOCK : 0
        [MAGIC, VERSION, @data_shards, @parity_shards, flags, length].pack(HEADER_FORMAT)
      end

      def data_blocks_for(data, shard_size)
        ::Array.new(@data_shards) do |index|
          block = data.byteslice(index * shard_size, shard_size) || "".b.dup
          block.ljust(shard_size, "\x00".b)
        end
      end

      def parity_blocks_for(data_blocks)
        ::Array.new(@parity_shards) do |parity_index|
          parity_row = @data_shards + parity_index
          parity = ::Array.new(data_blocks.first.bytesize, 0)

          data_blocks.each_with_index do |block, data_index|
            coefficient = cauchy_coefficient(parity_row, data_index)
            block.bytes.each_with_index do |byte, offset|
              parity[offset] ^= GF256.multiply(coefficient, byte)
            end
          end

          parity.pack("C*").force_encoding(Encoding::BINARY)
        end
      end

      def cauchy_coefficient(row, column)
        GF256.inverse(row ^ column)
      end

      def recover_data(payload, data_shards, total_shards, shard_size, original_length)
        return "".b.dup if original_length.zero?

        erased = @erased_shards
        survivors = surviving_blocks(payload, total_shards, shard_size)
        missing_data_blocks = (0...data_shards).select { |index| erased.include?(index) }

        recovered = {}
        unless missing_data_blocks.empty?
          selected_positions = survivors.keys.sort.first(data_shards)
          selected_blocks = selected_positions.map { |position| survivors.fetch(position) }
          matrix = selected_positions.map { |position| generator_row(position, data_shards) }
          inverse = invert_matrix(matrix)

          missing_data_blocks.each do |missing_position|
            missing_row = generator_row(missing_position, data_shards)
            coefficients = reconstruct_coefficients(missing_row, inverse)
            recovered[missing_position] = multiply_blocks(coefficients, selected_blocks, shard_size)
          end
        end

        data_blocks = ::Array.new(data_shards) do |index|
          recovered.fetch(index) { survivors.fetch(index) }
        end
        data_blocks.join.byteslice(0, original_length)
      end

      def surviving_blocks(payload, total_shards, shard_size)
        survivors = {}
        offset = 0

        total_shards.times do |position|
          next if @erased_shards.include?(position)
          survivors[position] = payload.byteslice(offset, shard_size)
          offset += shard_size
        end

        survivors
      end

      def generator_row(position, data_shards)
        if position < data_shards
          ::Array.new(data_shards, 0).tap { |row| row[position] = 1 }
        else
          ::Array.new(data_shards) { |column| cauchy_coefficient(position, column) }
        end
      end

      def invert_matrix(matrix)
        size = matrix.size
        augmented = matrix.map.with_index do |row, index|
          identity = ::Array.new(size, 0)
          identity[index] = 1
          row + identity
        end

        size.times do |column|
          pivot_row = (column...size).find { |row| augmented[row][column] != 0 }
          raise FormatError, "Reed-Solomon coding matrix is singular" unless pivot_row
          augmented[column], augmented[pivot_row] = augmented[pivot_row], augmented[column]

          pivot = augmented[column][column]
          inverse_pivot = GF256.inverse(pivot)
          augmented[column] = augmented[column].map do |value|
            GF256.multiply(value, inverse_pivot)
          end

          size.times do |row|
            next if row == column
            factor = augmented[row][column]
            next if factor.zero?
            0.upto(2 * size - 1) do |offset|
              augmented[row][offset] ^=
                GF256.multiply(factor, augmented[column][offset])
            end
          end
        end

        augmented.map { |row| row[size..] }
      end

      def multiply_blocks(coefficients, blocks, shard_size)
        result = ::Array.new(shard_size, 0)

        coefficients.each_with_index do |coefficient, block_index|
          next if coefficient.zero?
          blocks.fetch(block_index).bytes.each_with_index do |byte, offset|
            result[offset] ^= GF256.multiply(coefficient, byte)
          end
        end

        result.pack("C*").force_encoding(Encoding::BINARY)
      end

      def reconstruct_coefficients(row, inverse)
        size = row.size
        ::Array.new(size) do |column|
          value = 0
          size.times do |index|
            value ^= GF256.multiply(row[index], inverse[index][column])
          end
          value
        end
      end
    end
  end
end
