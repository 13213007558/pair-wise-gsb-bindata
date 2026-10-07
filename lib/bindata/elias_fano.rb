require 'bindata/base_primitive'

module BinData
  # EliasFanoSequence stores a non-decreasing sequence of non-negative
  # integers using Elias-Fano encoding.  Duplicate values are allowed.
  # Empty sequences, sequences of equal values and sequences with a very
  # large, sparse upper bound are all representable.
  #
  #   require 'bindata'
  #
  #   obj = BinData::EliasFanoSequence.new(initial_value: [1, 3, 3, 7, 100])
  #   obj.select(2)        #=> 3        (0-based element access)
  #   obj.rank(7)          #=> 3        (count of elements strictly < 7)
  #   obj.rank_le(7)       #=> 4        (count of elements <= 7)
  #   obj.lower_bound(4)   #=> 3        (first index whose element >= 4)
  #
  # == Query semantics
  #
  # +rank(x)+ returns the number of elements *strictly less than* +x+
  # (it does not use <=).  Use +rank_le(x)+ for the <= variant.
  # +lower_bound(x)+ returns the smallest index +i+ such that
  # obj[i] >= x, or the sequence length if no such element exists.
  # For a non-decreasing sequence, lower_bound(x) == rank(x).
  #
  # Queries do not expand the sequence.  They operate directly on the
  # packed bit representation with the help of an auxiliary select index
  # (see EliasFanoSequence::Index).
  #
  # == Binary format
  #
  # All integers are stored big-endian:
  #
  #   uint64be  n       number of elements
  #   uint64be  u       universe size (all values are < u); 0 when n == 0
  #   uint8     l       number of low bits per element
  #   uint8[]   lows    n * l bits, packed LSB-first
  #   uint8[]   highs   unary high bits: bit (value>>l)+i set for element i
  #
  # The encoded size is about n * (l + 2) bits, where
  # l = floor(log2(u / n)), so sparse sequences with huge upper bounds
  # stay compact.
  #
  # == Parameters
  #
  # This class accepts the parameters of BinData::BasePrimitive, e.g.
  # :initial_value.  The value must be an array of integers in
  # non-decreasing order, each in the range 0 .. 2**63 - 1.
  class EliasFanoSequence < BinData::BasePrimitive
    # Largest storable element (so that u = max + 1 fits in 64 bits).
    MAX_VALUE = (1 << 63) - 1

    # The auxiliary select index records the bit position of every
    # SELECT_SAMPLING-th 1-bit of the high bitvector.  This costs
    # ceil(n / SELECT_SAMPLING) 64-bit words, i.e. about
    # 64 / SELECT_SAMPLING bits (0.125 bit) per element.
    SELECT_SAMPLING = 512

    # Byte popcount lookup table.
    POPCOUNT = (0..255).map { |b| b.to_s(2).count('1') }.freeze

    # Auxiliary index over the packed Elias-Fano bitvectors.  Allows
    # select / rank / lower_bound queries without expanding the sequence.
    #
    # Space overhead: besides the n * (l + 2) data bits, the index stores
    # one 64-bit position per SELECT_SAMPLING (512) elements
    # (~0.125 bit per element).
    class Index
      attr_reader :n, :u, :l

      def initialize(n, u, l, lows, highs)
        @n = n
        @u = u
        @l = l
        @lows = lows
        @highs = highs
        @select_samples = build_select_samples
      end

      # Returns the +i+-th element (0-based), or nil if out of range.
      def select(i)
        return nil if i < 0 || i >= @n

        pos = select1(i)
        ((pos - i) << @l) | low_at(i)
      end

      # Returns the number of elements strictly less than +x+.
      def rank(x)
        return 0 if @n == 0 || x <= 0
        return @n if x >= @u

        h = x >> @l
        lo = x & ((1 << @l) - 1)
        bucket_lo = bucket_start(h)
        bucket_hi = bucket_start(h + 1)

        # Low bits are non-decreasing within a bucket: binary search for
        # the first element of the bucket whose low bits are >= lo.
        while bucket_lo < bucket_hi
          mid = (bucket_lo + bucket_hi) >> 1
          if low_at(mid) < lo
            bucket_lo = mid + 1
          else
            bucket_hi = mid
          end
        end
        bucket_lo
      end

      # Number of elements stored in the select sample table.
      def select_sample_count
        @select_samples.length
      end

      #---------------
      private

      # Number of elements whose high part is strictly less than +h+.
      def bucket_start(h)
        lo = 0
        hi = @n
        while lo < hi
          mid = (lo + hi) >> 1
          if select1(mid) - mid < h
            lo = mid + 1
          else
            hi = mid
          end
        end
        lo
      end

      # Bit position of the +i+-th 1-bit in the high bitvector.
      def select1(i)
        sample = i / SELECT_SAMPLING
        pos = @select_samples[sample]
        ones = sample * SELECT_SAMPLING

        byte_index = pos >> 3
        shift = pos & 7
        byte = @highs.getbyte(byte_index) >> shift
        loop do
          count = POPCOUNT[byte]
          if ones + count > i
            (i - ones).times { byte &= byte - 1 }
            trailing = (byte & -byte).bit_length - 1
            return (byte_index << 3) + shift + trailing
          end
          ones += count
          byte_index += 1
          shift = 0
          byte = @highs.getbyte(byte_index) || 0
        end
      end

      # The low +l+ bits of the +i+-th element.
      def low_at(i)
        return 0 if @l == 0

        bit_offset = i * @l
        byte_offset = bit_offset >> 3
        shift = bit_offset & 7
        nbytes = (shift + @l + 7) >> 3
        chunk = @lows.byteslice(byte_offset, nbytes) or return 0

        val = 0
        chunk.bytes.each_with_index { |b, k| val |= b << (k << 3) }
        (val >> shift) & ((1 << @l) - 1)
      end

      def build_select_samples
        samples = []
        count = 0
        @highs.bytes.each_with_index do |byte, byte_index|
          while byte != 0
            trailing = (byte & -byte).bit_length - 1
            if (count % SELECT_SAMPLING).zero?
              samples << ((byte_index << 3) + trailing)
            end
            count += 1
            byte &= byte - 1
          end
        end
        samples
      end
    end

    # Returns the +i+-th element (0-based), or nil if out of range.
    def select(i)
      ef_index.select(i)
    end

    # Returns the number of elements strictly less than +x+.
    # Note: this is a strict (<) rank, not <=.  See #rank_le.
    def rank(x)
      ef_index.rank(x)
    end

    # Returns the number of elements less than or equal to +x+.
    def rank_le(x)
      ef_index.rank(x + 1)
    end

    # Returns the smallest index +i+ such that the +i+-th element is
    # >= +x+.  Returns the sequence length if all elements are < +x+.
    def lower_bound(x)
      ef_index.rank(x)
    end

    def assign(val)
      validate_sequence(val)
      super
      @index = nil
    end

    def initialize_instance
      super
      if has_parameter?(:initial_value)
        validate_sequence(eval_parameter(:initial_value))
      end
      validate_sequence(eval_parameter(:value)) if has_parameter?(:value)
    end

    #---------------
    private

    def ef_index
      @index ||= Index.new(*self.class.encode_parts(_value))
    end

    def validate_sequence(val)
      unless val.is_a?(::Array)
        raise ArgumentError, 'value must be an array of non-negative integers in non-decreasing order'
      end

      prev = nil
      val.each do |v|
        unless v.is_a?(::Integer) && v >= 0 && v <= MAX_VALUE
          raise ArgumentError, 'elements must be integers in the range 0..2**63 - 1'
        end
        if prev && v < prev
          raise ArgumentError, 'values must be in non-decreasing order'
        end
        prev = v
      end
    end

    def value_to_binary_string(val)
      validate_sequence(val)
      self.class.encode(val)
    end

    def read_and_return_value(io)
      header = io.readbytes(17)
      n, u, l = header.unpack('Q>Q>C')

      if n.zero?
        @index = Index.new(0, 0, 0, ''.b, ''.b)
        return []
      end

      low_len = (n * l + 7) >> 3
      buckets = (u + (1 << l) - 1) >> l
      high_len = (n + buckets + 7) >> 3
      lows = io.readbytes(low_len)
      highs = io.readbytes(high_len)

      @index = Index.new(n, u, l, lows, highs)
      ::Array.new(n) { |i| @index.select(i) }
    end

    def sensible_default
      []
    end

    # Returns [n, u, l, lows, highs] for the given values.
    def self.encode_parts(values)
      n = values.length
      return [0, 0, 0, ''.b, ''.b] if n.zero?

      u = values[-1] + 1
      l = (u / n).bit_length - 1
      l = 0 if l.negative?

      lows = ''.b
      if l.positive?
        mask = (1 << l) - 1
        bitbuf = 0
        bitcount = 0
        values.each do |v|
          bitbuf |= (v & mask) << bitcount
          bitcount += l
          while bitcount >= 8
            lows << (bitbuf & 0xff).chr
            bitbuf >>= 8
            bitcount -= 8
          end
        end
        lows << (bitbuf & 0xff).chr if bitcount.positive?
      end

      buckets = (u + (1 << l) - 1) >> l
      highs = 0.chr.b * ((n + buckets + 7) >> 3)
      values.each_with_index do |v, i|
        pos = (v >> l) + i
        highs.setbyte(pos >> 3, highs.getbyte(pos >> 3) | (1 << (pos & 7)))
      end

      [n, u, l, lows, highs]
    end

    # Returns the binary representation of the given values.
    def self.encode(values)
      n, u, l, lows, highs = encode_parts(values)
      [n, u, l].pack('Q>Q>C') << lows << highs
    end
  end
end
