require 'bindata/base_primitive'
require 'bindata/layout'

module BinData
  # An unsigned integer stored as a variable length quantity.  Each byte
  # holds 7 bits of the value, most significant group last.  The high bit
  # of a byte signals that another byte follows.
  #
  #   require 'bindata'
  #
  #   obj = BinData::Varint.new(initial_value: 127)
  #   obj.to_binary_s   #=> "\x7f"
  #
  #   obj.assign(128)
  #   obj.to_binary_s   #=> "\x81\x00"
  #
  # The number of bytes used depends on the value, so #num_bytes changes
  # as the value crosses a width boundary (127 -> 128, 16383 -> 16384, ...).
  class Varint < BinData::BasePrimitive
    # Largest representable value (64 bit unsigned).
    MAX_VALUE = (1 << 64) - 1

    # Largest number of bytes in the encoded form.
    MAX_BYTES = 10

    def assign(val)
      super(val.clamp(0, MAX_VALUE))
    end

    def do_num_bytes # :nodoc:
      Layout.varint_width(_value)
    end

    #---------------
    private

    def sensible_default
      0
    end

    def value_to_binary_string(val)
      val = val.clamp(0, MAX_VALUE)
      bytes = []
      loop do
        byte = val & 0x7f
        val >>= 7
        if val.zero?
          bytes << byte
          return bytes.pack("C*")
        end
        bytes << (byte | 0x80)
      end
    end

    def read_and_return_value(io)
      value = 0
      shift = 0
      MAX_BYTES.times do
        byte = io.readbytes(1).ord
        value |= (byte & 0x7f) << shift
        return checked_value(value) if (byte & 0x80).zero?

        shift += 7
      end
      raise Layout::LengthOverflowError,
            "varint does not terminate within #{MAX_BYTES} bytes for #{debug_name}"
    end

    def checked_value(value)
      if value > MAX_VALUE
        raise Layout::LengthOverflowError,
              "varint value #{value} exceeds 64 bits for #{debug_name}"
      end
      value
    end
  end
end
