require 'bindata/base_primitive'

module BinData
  # EliasFano stores a non-decreasing sequence of non-negative integers
  # (duplicate values are allowed) using Elias-Fano encoding.  As well as
  # reading and writing the sequence, the encoded form directly supports
  # +select+, +lower_bound+ and +rank+ queries without expanding the whole
  # sequence.
  #
  #   require 'bindata'
  #
  #   obj = BinData::EliasFano.new(initial_value: [1, 3, 3, 7, 100])
  #   obj.write(io)
  #
  #   obj = BinData::EliasFano.read(io)
  #   obj.select(2)        #=> 3       (value at 0-based index 2)
  #   obj.lower_bound(4)   #=> 3       (first index whose value >= 4)
  #   obj.rank(7)          #=> 3       (count of values strictly < 7)
  #   obj.rank_leq(7)      #=> 4       (count of values <= 7)
  #
  # Empty sequences, sequences where all values are equal, and sequences
  # with a very large sparse universe (e.g. values near 2**64) are all
  # representable.
  #
  # == Rank semantics
  #
  # +rank(x)+ returns the number of elements *strictly less than* +x+
  # (equivalent to +lower_bound(x)+).  Use +rank_leq(x)+ for the number of
  # elements less than or equal to +x+.
  #
  # == Binary format
  #
  # For a sequence of +n+ values with universe +U+ (one more than the
  # maximum value, 0 when empty) and +l = max(0, floor(log2(U / n)))+:
  #
  #   [varint n][varint U][n * l low bits][n + num_buckets unary high bits]
  #
  # The low bits hold the +l+ least significant bits of every value.  The
  # high bits are a unary bitvector where a 1 at position +i + (v_i >> l)+
  # represents the high bits of the +i+-th value.  Integers are arbitrary
  # precision, so the universe may be arbitrarily large (e.g. 2**64) while
  # the encoding stays compact: about +n * l + 2n+ bits.
  #
  # == Query index and space overhead
  #
  # Queries never decode the full sequence.  On first use, an auxiliary
  # index is built over the unary high bits: the bits are unpacked into
  # 64-bit words, and the positions of every SELECT_SAMPLE_RATE-th (512th)
  # 1-bit and 0-bit are sampled to accelerate +select+/+rank+.  The index
  # adds at most +(n + num_buckets) / 512 * 2+ machine words (worst case
  # about 3n/256 words, i.e. a few percent of the data size), plus the
  # high-bit words themselves (at most ~3n/8 bytes).
  class EliasFano < BinData::BasePrimitive
    # Number of unary high bits between consecutive select-index samples.
    SELECT_SAMPLE_RATE = 512

    def initialize_instance
      @value = nil
      @data = nil
      @index = nil
    end

    def clear? # :nodoc:
      @value.nil? && @data.nil?
    end

    def assign(val)
      raise ArgumentError, "can't set a nil value for #{debug_name}" if val.nil?

      raw_val = val.respond_to?(:snapshot) ? val.snapshot : val
      vals = raw_val.to_a.map { |v| Integer(v) }
      self.class.validate_sequence!(vals)
      @data = self.class.encode_sequence(vals)
      @index = nil
      @value = vals
    end

    # Number of elements in the sequence.
    def length
      ef_index.n
    end
    alias size length

    def empty?
      length.zero?
    end

    # The universe size: one more than the maximum storable value.
    def universe
      ef_index.u
    end

    # Returns the value at 0-based +index+.  Negative indices count back
    # from the end.  Raises IndexError when out of bounds.
    def select(index)
      idx = ef_index
      index += idx.n if index < 0
      if index < 0 || index >= idx.n
        raise IndexError, "index #{index} outside of sequence bounds: -#{idx.n}...#{idx.n}"
      end

      idx.select_value(index)
    end
    alias [] select

    # Returns the smallest index +i+ such that +select(i) >= x+, or
    # +length+ when every value is less than +x+.
    def lower_bound(x)
      ef_index.lower_bound(Integer(x))
    end

    # Returns the number of elements *strictly less than* +x+.
    # Equivalent to +lower_bound(x)+.  See +rank_leq+ for the
    # less-than-or-equal variant.
    def rank(x)
      lower_bound(x)
    end

    # Returns the number of elements less than or equal to +x+.
    def rank_leq(x)
      lower_bound(Integer(x) + 1)
    end

    def do_read(io) # :nodoc:
      @data = self.class.read_sequence_binary(io)
      @value = nil
      @index = nil
    end

    def do_write(io) # :nodoc:
      io.writebytes(ef_data)
    end

    def do_num_bytes # :nodoc:
      ef_data.bytesize
    end

    #---------------
    private

    def _value
      if @value.nil? && @data
        @value = self.class.decode_sequence(@data)
      end
      @value.nil? ? sensible_default : @value
    end

    def value_to_binary_string(val)
      self.class.encode_sequence(val.to_a.map { |v| Integer(v) })
    end

    def read_and_return_value(io)
      do_read(io)
      _value
    end

    def sensible_default
      []
    end

    def ef_data
      @data ||= self.class.encode_sequence(_value)
    end

    def ef_index
      @index ||= Index.new(ef_data)
    end

    #---------------
    # Encoding helpers

    def self.validate_sequence!(vals)
      prev = nil
      vals.each do |v|
        if v < 0
          raise ArgumentError, "EliasFano values must be non-negative, got #{v}"
        end
        if prev && v < prev
          raise ArgumentError, "EliasFano sequence must be non-decreasing"
        end
        prev = v
      end
    end

    # l = max(0, floor(log2(u / n)))
    def self.low_bit_count(n, u)
      return 0 if n.zero? || u <= n

      l = u.bit_length - n.bit_length
      l -= 1 if (n << l) > u
      l
    end

    def self.num_buckets(u, l)
      u.zero? ? 0 : ((u - 1) >> l) + 1
    end

    # Number of bits in the unary high bitvector: n ones plus one zero per
    # bucket boundary below the maximum high value.
    def self.high_bit_count(n, u, l)
      n.zero? ? 0 : n + ((u - 1) >> l)
    end

    def self.encode_sequence(vals)
      n = vals.length
      u = n.zero? ? 0 : vals[-1] + 1
      l = low_bit_count(n, u)

      out = +""
      write_varint(out, n)
      write_varint(out, u)
      return out if n.zero?

      if l > 0
        writer = BitWriter.new
        mask = (1 << l) - 1
        vals.each { |v| writer.write(v & mask, l) }
        out << writer.to_binary_s
      end

      writer = BitWriter.new
      prev_high = 0
      vals.each do |v|
        high = v >> l
        writer.write(0, high - prev_high)
        writer.write(1, 1)
        prev_high = high
      end
      out << writer.to_binary_s
      out
    end

    def self.read_sequence_binary(io)
      n, n_bytes = read_varint(io)
      u, u_bytes = read_varint(io)
      header = n_bytes + u_bytes
      return header if n.zero?

      l = low_bit_count(n, u)
      low_len = (n * l + 7) / 8
      high_len = (high_bit_count(n, u, l) + 7) / 8
      header + io.readbytes(low_len) + io.readbytes(high_len)
    end

    def self.decode_sequence(data)
      n, u, l, off = parse_header(data)
      return [] if n.zero?

      low_len = (n * l + 7) / 8
      high_len = (high_bit_count(n, u, l) + 7) / 8
      low = data.byteslice(off, low_len)
      high = data.byteslice(off + low_len, high_len)

      vals = []
      i = 0
      high_val = 0
      high.each_byte do |byte|
        8.times do |bit|
          break if i >= n

          if byte[bit] == 1
            vals << ((high_val << l) | bits_get(low, i * l, l))
            i += 1
          else
            high_val += 1
          end
        end
      end
      vals
    end

    def self.parse_header(data)
      n, off = varint_at(data, 0)
      u, off = varint_at(data, off)
      [n, u, low_bit_count(n, u), off]
    end

    # Extracts +len+ bits starting at bit position +pos+ (LSB-first bit
    # order) from a binary string.
    def self.bits_get(str, pos, len)
      return 0 if len.zero?

      byte_off = pos >> 3
      bit_off = pos & 7
      nbytes = (bit_off + len + 7) >> 3
      chunk = str.byteslice(byte_off, nbytes) || +""
      chunk = chunk.ljust(nbytes, "\x00".b) if chunk.bytesize < nbytes
      val = chunk.reverse.unpack1("H*").to_i(16)
      (val >> bit_off) & ((1 << len) - 1)
    end

    def self.write_varint(out, v)
      loop do
        byte = v & 0x7f
        v >>= 7
        if v.zero?
          out << byte.chr
          break
        else
          out << (byte | 0x80).chr
        end
      end
      out
    end

    def self.read_varint(io)
      result = 0
      shift = 0
      bytes = +""
      loop do
        byte = io.readbytes(1).getbyte(0)
        bytes << byte.chr
        result |= (byte & 0x7f) << shift
        break if byte < 0x80

        shift += 7
      end
      [result, bytes]
    end

    def self.varint_at(data, offset)
      result = 0
      shift = 0
      pos = offset
      loop do
        byte = data.getbyte(pos)
        pos += 1
        result |= (byte & 0x7f) << shift
        break if byte < 0x80

        shift += 7
      end
      [result, pos]
    end

    # Accumulates bits LSB-first into a binary string.
    class BitWriter # :nodoc:
      def initialize
        @bytes = []
        @acc = 0
        @nbits = 0
      end

      def write(value, nbits)
        return if nbits <= 0

        @acc |= value << @nbits
        @nbits += nbits
        while @nbits >= 8
          @bytes << (@acc & 0xff)
          @acc >>= 8
          @nbits -= 8
        end
      end

      def to_binary_s
        bytes = @nbits > 0 ? @bytes + [@acc & 0xff] : @bytes
        bytes.pack("C*")
      end
    end

    # Auxiliary index over the encoded form.  Provides select/rank on the
    # unary high bits and direct access to the packed low bits, so queries
    # never expand the whole sequence.  See the class documentation of
    # EliasFano for the space overhead.
    class Index # :nodoc:
      SR = SELECT_SAMPLE_RATE
      POPCOUNT = (0..255).map { |i| i.to_s(2).count("1") }.freeze

      attr_reader :n, :u, :l, :num_buckets

      def initialize(data)
        @n, @u, @l, off = EliasFano.parse_header(data)
        @num_buckets = EliasFano.num_buckets(@u, @l)
        @high_bits = EliasFano.high_bit_count(@n, @u, @l)
        low_len = (@n * @l + 7) / 8
        high_len = (@high_bits + 7) / 8
        @low = data.byteslice(off, low_len) || +""
        high = data.byteslice(off + low_len, high_len) || +""
        @high_words = high.ljust(((high_len + 7) / 8) * 8, "\x00".b).unpack("Q<*")
        build_select_samples
      end

      def select_value(i)
        pos = select1(i)
        high = pos - i
        (high << @l) | low_at(i)
      end

      def lower_bound(x)
        return 0 if x <= 0 || @n.zero?

        high = x >> @l
        return @n if high >= @num_buckets

        lo = bucket_start(high)
        hi = bucket_start(high + 1)
        target_low = x & ((1 << @l) - 1)
        while lo < hi
          mid = (lo + hi) >> 1
          if low_at(mid) >= target_low
            hi = mid
          else
            lo = mid + 1
          end
        end
        lo
      end

      private

      def low_at(i)
        return 0 if @l.zero?

        EliasFano.bits_get(@low, i * @l, @l)
      end

      # Number of values whose high bits are strictly less than +bucket+.
      def bucket_start(bucket)
        return @n if bucket >= @num_buckets
        return 0 if bucket.zero?

        # Values with high < bucket are exactly the 1 bits positioned
        # before the (bucket - 1)-th zero.
        rank1(select0(bucket - 1))
      end

      # Position of the +i+-th (0-based) 1 bit in the high bitvector.
      def select1(i)
        select_from(@ones_select, i, 1)
      end

      # Position of the +i+-th (0-based) 0 bit in the high bitvector.
      def select0(i)
        select_from(@zeros_select, i, 0)
      end

      def select_from(samples, i, bit)
        sample = i / SR
        pos = samples[sample]
        count = sample * SR
        w = pos >> 6
        word = bits_word(w, bit) & (~0 << (pos & 63))
        loop do
          pc = popcount(word)
          if count + pc > i
            64.times do |b|
              next if word[b].zero?

              return (w << 6) + b if count == i

              count += 1
            end
          end
          count += pc
          w += 1
          word = bits_word(w, bit)
        end
      end

      # Word +w+ of the high bitvector, inverted when counting 0 bits.
      def bits_word(w, bit)
        word = @high_words[w] || 0
        bit.zero? ? ~word & ((1 << 64) - 1) : word
      end

      # Number of 1 bits in positions [0, pos) of the high bitvector.
      def rank1(pos)
        return 0 if pos <= 0 || @ones_select.empty?

        j = @ones_select.bsearch_index { |p| p >= pos }
        j = j ? j - 1 : @ones_select.length - 1
        j = 0 if j.negative?
        count = j * SR
        w = @ones_select[j] >> 6
        word = @high_words[w] & (~0 << (@ones_select[j] & 63))
        loop do
          base = w << 6
          return count + popcount(word & ((1 << (pos - base)) - 1)) if base + 64 >= pos

          count += popcount(word)
          w += 1
          return count if w >= @high_words.length

          word = @high_words[w]
        end
      end

      def build_select_samples
        @ones_select = []
        @zeros_select = []
        ones = 0
        zeros = 0
        total = @high_bits
        @high_words.each_with_index do |word, w|
          base = w << 6
          64.times do |b|
            pos = base + b
            break if pos >= total

            if word[b] == 1
              @ones_select << pos if (ones % SR).zero?
              ones += 1
            else
              @zeros_select << pos if (zeros % SR).zero?
              zeros += 1
            end
          end
        end
      end

      def popcount(word)
        count = 0
        while word > 0
          count += POPCOUNT[word & 0xff]
          word >>= 8
        end
        count
      end
    end
  end
end
