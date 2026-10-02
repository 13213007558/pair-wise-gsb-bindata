module BinData
  module Transform
    # Systematic Reed-Solomon erasure coding over GF(256).
    #
    # The encoded stream starts with a self describing header followed by
    # +data_shards + parity_shards+ equal-sized shards.  The final data shard
    # is zero padded.  The padding and original length are stored in the
    # header, so only the positions of omitted shards must be supplied when
    # reading.
    #
    #   require 'bindata/transform/reed_solomon'
    #
    #   obj = BinData::Section.new(
    #     transform: -> { BinData::Transform::ReedSolomon.new(4, 2) },
    #     type: [:string, read_length: data.length]
    #   )
    #
    #   frame = obj.to_binary_s
    #
    #   obj = BinData::Section.new(
    #     transform: -> { BinData::Transform::ReedSolomon.new(missing_shards: [0, 5]) },
    #     type: [:string, read_length: data.length]
    #   )
    #   obj.read(frame_with_two_shards_removed)
    #
    # Only known erasures are handled.  If surviving shards are inconsistent,
    # or if more shards than parity shards are missing, an IOError is raised
    # before decoded data is returned.
    class ReedSolomon < BinData::IO::Transform
      transform_changes_stream_length!

      HEADER_IDENTIFIER = "RS1".dup.force_encoding(Encoding::BINARY).freeze
      HEADER_FORMAT = "a3CCNN".freeze
      HEADER_SIZE = 13
      MAX_SHARDS = 255
      MAX_LENGTH = (1 << 32) - 1

      module GF256
        PRIMITIVE_POLYNOMIAL = 0x11d

        EXP = ::Array.new(512, 1)
        LOG = ::Array.new(256, 0)

        value = 1
        1.upto(254) do |i|
          value <<= 1
          value ^= PRIMITIVE_POLYNOMIAL if value >= 256
          value &= 0xff
          EXP[i] = value
          LOG[value] = i
        end

        255.upto(511) do |i|
          EXP[i] = EXP[i % 255]
        end

        def self.multiply(left, right)
          return 0 if left.zero? || right.zero?
          exponent = LOG[left] + LOG[right]
          EXP[exponent % 255]
        end

        def self.power(value, exponent)
          return 1 if exponent.zero?
          return 0 if value.zero?
          EXP[(LOG[value] * exponent) % 255]
        end

        def self.inverse(value)
          EXP[255 - LOG[value]]
        end

        def self.invert_matrix(matrix)
          size = matrix.size
          augmented = matrix.map.with_index do |row, index|
            identity = ::Array.new(size, 0)
            identity[index] = 1
            row.dup.concat(identity)
          end

          size.times do |column|
            pivot = (column...size).find { |row| !augmented[row][column].zero? }
            raise IOError, "Reed-Solomon matrix is singular" unless pivot

            if column != pivot
              augmented[column], augmented[pivot] =
                augmented[pivot], augmented[column]
            end

            pivot_inverse = inverse(augmented[column][column])
            augmented[column] = augmented[column].map { |entry| multiply(entry, pivot_inverse) }

            size.times do |row_index|
              next if row_index == column

              factor = augmented[row_index][column]
              next if factor.zero?

              (2 * size).times do |index|
                augmented[row_index][index] ^= multiply(factor, augmented[column][index])
              end
            end
          end

          augmented.map { |row| row[size...(2 * size)] }
        end
      end

      def self.validate_parameters(data_shards, parity_shards)
        unless data_shards.is_a?(Integer) && data_shards >= 1 && data_shards <= MAX_SHARDS
          raise ArgumentError, "data_shards must be between 1 and #{MAX_SHARDS}"
        end

        unless parity_shards.is_a?(Integer) && parity_shards >= 0 &&
               data_shards + parity_shards <= MAX_SHARDS
          raise ArgumentError,
                "parity_shards must be non-negative and data_shards + parity_shards " \
                  "must not exceed #{MAX_SHARDS}"
        end
      end

      def initialize(data_shards = nil, parity_shards = nil, missing_shards: nil)
        super()
        @data_shards = data_shards
        @parity_shards = parity_shards
        @missing = coerce_missing(missing_shards)
        @write = create_empty_binary_string
      end

      def read(length = nil)
        decoded

        if length.nil?
          @read.slice!(0...@read.bytesize)
        else
          @read.slice!(0...length)
        end
      end

      def write(data)
        @write << data
      end

      def after_read_transform
        decoded
        raise IOError, "didn't read all data" unless @read.empty?
      end

      def after_write_transform
        unless @missing.empty?
          raise ArgumentError, "missing_shards can only be supplied when reading"
        end

        data_shards_count = @data_shards
        parity_shards_count = @parity_shards
        self.class.validate_parameters(data_shards_count, parity_shards_count)

        original = @write
        unless original.bytesize <= MAX_LENGTH
          raise ArgumentError, "Reed-Solomon data exceeds 32-bit length field"
        end

        shard_length = shard_length_for(original.bytesize, data_shards_count)
        data_shards = partition(original, data_shards_count, shard_length)
        parity_shards = ::Array.new(parity_shards_count) do |row|
          parity_shard(data_shards, data_shards_count + row, shard_length)
        end

        header = [HEADER_IDENTIFIER, data_shards_count, parity_shards_count,
                  original.bytesize, shard_length].pack(HEADER_FORMAT)
        chain_write(header)
        (data_shards + parity_shards).each do |shard|
          chain_write(shard.pack("C*"))
        end
      end

      private

      def read_exactly(length)
        data = create_empty_binary_string

        while data.bytesize < length
          chunk = chain_read(length - data.bytesize)
          if chunk.nil? || chunk.empty?
            raise IOError, "Reed-Solomon data is truncated"
          end

          data << chunk
        end

        data
      end

      def coerce_missing(missing)
        values = case missing
                 when nil
                   []
                 when Array
                   missing.dup
                 when Range
                   missing.to_a
                 else
                   if missing.respond_to?(:to_a)
                     missing.to_a
                   else
                     raise ArgumentError,
                           "missing_shards must be an array of shard positions"
                   end
                 end

        values.map do |position|
          unless position.is_a?(Integer)
            raise ArgumentError, "missing shard positions must be integers"
          end
          position
        end.tap do |positions|
          if positions.uniq.size != positions.size
            raise ArgumentError, "missing shard positions must be unique"
          end
        end
      end

      def decoded
        @decoded ||= decode
      end

      def decode
        header = read_exactly(HEADER_SIZE)

        identifier, data_shards_count, parity_shards_count, original_length, shard_length =
          header.unpack(HEADER_FORMAT)

        unless identifier == HEADER_IDENTIFIER
          raise IOError, "invalid Reed-Solomon header"
        end

        validate_header_parameters(data_shards_count, parity_shards_count,
                                   original_length, shard_length)
        validate_missing_positions!(data_shards_count + parity_shards_count,
                                    parity_shards_count)

        payload_length = (data_shards_count + parity_shards_count - @missing.size) * shard_length
        payload = read_exactly(payload_length)

        survivors = surviving_shards(payload, data_shards_count + parity_shards_count,
                                    shard_length)
        data = recover(survivors, data_shards_count, parity_shards_count,
                       shard_length, original_length)
        @read = data
      end

      def validate_header_parameters(data_shards_count, parity_shards_count,
                                     original_length, shard_length)
        unless data_shards_count.is_a?(Integer) && data_shards_count >= 1 &&
               data_shards_count <= MAX_SHARDS &&
               parity_shards_count.is_a?(Integer) && parity_shards_count >= 0 &&
               data_shards_count + parity_shards_count <= MAX_SHARDS
          raise IOError, "invalid Reed-Solomon shard counts"
        end

        unless original_length <= MAX_LENGTH
          raise IOError, "invalid Reed-Solomon original length"
        end

        expected_shard_length = shard_length_for(original_length, data_shards_count)
        unless shard_length == expected_shard_length
          raise IOError, "invalid Reed-Solomon short shard length"
        end

        if @data_shards && @data_shards != data_shards_count
          raise IOError, "Reed-Solomon data_shards does not match header"
        end

        if @parity_shards && @parity_shards != parity_shards_count
          raise IOError, "Reed-Solomon parity_shards does not match header"
        end
      end

      def validate_missing_positions!(total_shards, parity_shards_count)
        if @missing.any? { |position| position.negative? || position >= total_shards }
          raise ArgumentError, "missing shard position is outside encoded section"
        end

        if @missing.size > parity_shards_count
          raise IOError,
                "cannot recover #{@missing.size} erasures with #{parity_shards_count} parity shards"
        end
      end

      def surviving_shards(payload, total_shards, shard_length)
        survivors = []
        offset = 0

        total_shards.times do |position|
          next if @missing.include?(position)

          shard = payload.byteslice(offset, shard_length)
          unless shard&.bytesize == shard_length
            raise IOError, "Reed-Solomon data is truncated"
          end

          survivors << [position, shard.bytes]
          offset += shard_length
        end

        unless offset == payload.bytesize
          raise IOError, "Reed-Solomon payload does not match shard layout"
        end

        survivors
      end

      def recover(survivors, data_shards_count, parity_shards_count,
                  shard_length, original_length)
        if survivors.size < data_shards_count
          raise IOError,
                "cannot recover #{@missing.size} erasures with #{parity_shards_count} parity shards"
        end

        selected = survivors.first(data_shards_count)
        encoding_matrix = selected.map do |position, _|
          if position < data_shards_count
            ::Array.new(data_shards_count, 0).tap do |row|
              row[position] = 1
            end
          else
            ::Array.new(data_shards_count) do |data_index|
              data_index.zero? ? 1 : GF256.power(position, data_index)
            end
          end
        end
        inverse_matrix = GF256.invert_matrix(encoding_matrix)
        recovered = ::Array.new(data_shards_count) { ::Array.new(shard_length, 0) }

        inverse_matrix.each_with_index do |row, data_index|
          row.each_with_index do |coefficient, survivor_index|
            next if coefficient.zero?

            bytes = selected[survivor_index].last
            shard_length.times do |byte_index|
              recovered[data_index][byte_index] ^=
                GF256.multiply(coefficient, bytes[byte_index])
            end
          end
        end

        verify_survivors(recovered, survivors, shard_length)
        recovered.flatten.first(original_length).pack("C*")
      end

      def verify_survivors(data_shards, survivors, shard_length)
        survivors.each do |position, actual|
          expected = if position < data_shards.size
                       data_shards[position]
                     else
                       parity_shard(data_shards, position, shard_length)
                     end

          next if expected == actual

          raise IOError, "Reed-Solomon parity verification failed"
        end
      end

      def shard_length_for(original_length, data_shards_count)
        return 0 if original_length.zero?
        (original_length + data_shards_count - 1) / data_shards_count
      end

      def partition(data, data_shards_count, shard_length)
        bytes = data.bytes
        ::Array.new(data_shards_count) do |index|
          start = index * shard_length
          shard = bytes[start, shard_length] || []
          padding = shard_length - shard.size
          shard.concat(::Array.new(padding, 0)) if padding.positive?
          shard
        end
      end

      def parity_shard(data_shards, shard_position, shard_length)
        parity = ::Array.new(shard_length, 0)

        data_shards.each_with_index do |shard, data_index|
          coefficient = data_index.zero? ? 1 : GF256.power(shard_position, data_index)
          shard.each_with_index do |value, byte_index|
            parity[byte_index] ^= GF256.multiply(coefficient, value)
          end
        end

        parity
      end
    end
  end
end
