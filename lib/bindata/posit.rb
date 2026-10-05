require 'bindata/base_primitive'

module BinData
  # An n-bit Posit number with exponent size es.
  #
  # Finite values are represented as Rational. The bit pattern with a one in
  # the sign position and zeroes elsewhere is represented by Posit::NAR.
  class Posit < BasePrimitive
    class NaRValue
      def dup
        self
      end

      def clone
        self
      end

      def inspect
        'NaR'
      end

      alias to_s inspect
    end

    NAR = NaRValue.new.freeze

    optional_parameters :n, :nbits, :es
    default_parameters es: 0
    mutually_exclusive_parameters :n, :nbits
    arg_processor :posit

    def assign(val)
      val = val.snapshot if val.respond_to?(:snapshot)
      super(normalized_value(val))
    end

    def do_read(io)
      bits = io.readbits(posit_n, :big)
      @value = Posit.decode(bits, posit_n, posit_es)
    end

    def do_write(io)
      io.writebits(Posit.encode(_value, posit_n, posit_es), posit_n, :big)
    end

    def do_num_bytes
      posit_n / 8.0
    end

    def bit_aligned?
      true
    end

    #---------------
    private

    def normalized_value(val)
      Posit.decode(Posit.encode(val, posit_n, posit_es), posit_n, posit_es)
    end

    def posit_n
      n = eval_parameter(:n)
      validate_posit_integer(n, :n, 2)
      n
    end

    def posit_es
      es = eval_parameter(:es)
      validate_posit_integer(es, :es, 0)
      es
    end

    def validate_posit_integer(value, name, minimum)
      unless value.is_a?(Integer) && value >= minimum
        raise ArgumentError, "parameter :#{name} must be an integer >= #{minimum}"
      end
    end

    def sensible_default
      Rational(0, 1)
    end

    def value_to_binary_string(val)
      n = posit_n
      nbytes = (n + 7) / 8
      bits = Posit.encode(val, n, posit_es) << (nbytes * 8 - n)
      bytes = Array.new(nbytes) do |index|
        (bits >> ((nbytes - index - 1) * 8)) & 0xff
      end
      bytes.pack('C*')
    end

    def read_and_return_value(io)
      Posit.decode(io.readbits(posit_n, :big), posit_n, posit_es)
    end

    class << self
      def decode(bits, n, es)
        validate_parameters(n, es)
        bits &= (1 << n) - 1

        return Rational(0, 1) if bits.zero?
        return NAR if bits == (1 << (n - 1))

        positive = bits < (1 << (n - 1))
        magnitude_bits = positive ? bits : (1 << n) - bits
        value = decode_positive(magnitude_bits, n - 1, es)
        positive ? value : -value
      end

      def encode(value, n, es)
        validate_parameters(n, es)
        return 1 << (n - 1) if value.is_a?(NaRValue) || value == :NaR

        magnitude = to_exact_rational(value).abs
        return 0 if magnitude.zero?

        payload = nearest_positive_payload(magnitude, n - 1, es)
        return 0 if payload.zero?

        if value.negative?
          (1 << n) - payload
        else
          payload
        end
      end

      private

      def validate_parameters(n, es)
        unless n.is_a?(Integer) && n >= 2
          raise ArgumentError, 'parameter :n must be an integer >= 2'
        end
        unless es.is_a?(Integer) && es >= 0
          raise ArgumentError, 'parameter :es must be an integer >= 0'
        end
      end

      def to_exact_rational(value)
        case value
        when Integer
          Rational(value, 1)
        when Rational
          value
        else
          if defined?(BigDecimal) && value.is_a?(BigDecimal)
            unless value.finite?
              raise ArgumentError, 'cannot encode a non-finite BigDecimal'
            end
            value.to_r
          elsif value.is_a?(Float)
            raise ArgumentError, 'Float is not accepted; use Rational or a finite BigDecimal'
          else
            raise ArgumentError, "cannot convert #{value.class} to an exact Posit value"
          end
        end
      end

      def decode_positive(payload, width, es)
        first_position = width - 1
        first_bit = (payload >> first_position) & 1
        position = first_position - 1

        while position >= 0 && ((payload >> position) & 1) == first_bit
          position -= 1
        end

        if position < 0
          run_length = width
          regime = first_bit == 1 ? run_length : -run_length
          available_bits = 0
        else
          run_length = first_position - position - 1
          regime = first_bit == 1 ? run_length : -(run_length + 1)
          available_bits = position
        end

        exponent_bits = [es, available_bits].min
        fraction_bits = available_bits - exponent_bits
        exponent = (payload >> fraction_bits) & ((1 << exponent_bits) - 1)
        fraction = fraction_bits.zero? ? 0 : payload & ((1 << fraction_bits) - 1)
        significand = Rational((1 << fraction_bits) | fraction, 1 << fraction_bits)

        2 ** (regime * (1 << es) + exponent) * significand
      end

      def nearest_positive_payload(value, width, es)
        maximum_payload = (1 << width) - 1
        minimum_value = decode_positive(1, width, es)
        maximum_value = decode_positive(maximum_payload, width, es)

        return maximum_payload if value >= maximum_value
        return 0 if value <= minimum_value / 2

        low = 1
        high = maximum_payload

        while low + 1 < high
          middle = (low + high) / 2
          if value < decode_positive(middle, width, es)
            high = middle
          else
            low = middle
          end
        end

        lower_value = decode_positive(low, width, es)
        higher_value = decode_positive(high, width, es)
        twice_distance = 2 * (value - lower_value)
        gap = higher_value - lower_value

        if twice_distance < gap
          low
        elsif twice_distance > gap
          high
        else
          low.even? ? low : high
        end
      end

    end

  end

  class PositArgProcessor < BaseArgProcessor
    def sanitize_parameters!(_obj_class, params)
      if params.has_parameter?(:n) && params.has_parameter?(:nbits)
        raise ArgumentError, "params ':n' and ':nbits' are mutually exclusive"
      end

      params.rename_parameter(:nbits, :n)
      unless params.has_parameter?(:n)
        raise ArgumentError, "parameter 'n' must be specified"
      end

      normalize_integer_parameter(params, :n, 2)
      normalize_integer_parameter(params, :es, 0)
    end

    private

    def normalize_integer_parameter(params, name, minimum)
      return unless params.has_parameter?(name)

      value = params[name]
      return if value.is_a?(Symbol) || value.respond_to?(:arity)

      integer = value.respond_to?(:to_int) ? value.to_int : value
      unless integer.is_a?(Integer) && integer >= minimum
        raise ArgumentError, "parameter ':#{name}' must be an integer >= #{minimum}"
      end

      params[name] = integer
    end
  end
end
