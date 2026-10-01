require 'bindata/base_primitive'
require 'bindata/layout_solver'

module BinData
  # A Varint is an unsigned integer stored as a variable length integer
  # (unsigned LEB128).  Each byte contributes seven bits of the value;
  # the high bit of a byte indicates that another byte follows.  The
  # number of bytes used depends on the magnitude of the value:
  #
  #   BinData::Varint.new(initial_value: 127).to_binary_s  #=> "\x7f"
  #   BinData::Varint.new(initial_value: 128).to_binary_s  #=> "\x80\x01"
  #
  # Varints are useful for self describing records, where a length prefix
  # includes the width of the length field itself.  See
  # BinData::LayoutSolver and the :solved_length field parameter of
  # BinData::Struct.
  class Varint < BasePrimitive
    class << self
      # Number of bytes needed to encode +value+ as a varint.
      def width_of(value)
        LayoutSolver.varint_width(value)
      end
    end

    def assign(val)
      raw_val = val.respond_to?(:snapshot) ? val.snapshot : val
      unless raw_val.is_a?(Integer) && raw_val >= 0
        raise ArgumentError,
              "varint value must be a non negative integer, " \
              "not #{raw_val.inspect}"
      end

      super(val)
    end

    def do_num_bytes # :nodoc:
      self.class.width_of(_value)
    end

    #---------------
    private

    def sensible_default
      0
    end

    def value_to_binary_string(val)
      if val < 0
        raise RangeError,
              "negative value #{val} can not be varint encoded"
      end

      bytes = []
      loop do
        byte = val & 0x7f
        val >>= 7
        if val.zero?
          bytes << byte
          break
        else
          bytes << (byte | 0x80)
        end
      end
      bytes.pack('C*')
    end

    def read_and_return_value(io)
      value = 0
      shift = 0
      loop do
        byte = io.readbytes(1).ord
        value |= (byte & 0x7f) << shift
        break if (byte & 0x80).zero?

        shift += 7
      end
      value
    end
  end
end
