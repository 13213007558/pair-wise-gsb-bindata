require 'bigdecimal'
require 'rational'
require 'bindata/base_primitive'

module BinData
  # A Posit number with configurable width (+n+) and exponent size (+es+).
  class Posit < BasePrimitive
    NAR = :nar

    optional_parameters :n, :nbits
    mandatory_parameter :es
    mutually_exclusive_parameters :n, :nbits
    arg_processor :posit

    def assign(val)
      super(PositCodec.coerce(val))
    end

    def do_write(io)
      io.writebits(encoded_bits, posit_width, :big)
    end

    def do_num_bytes
      posit_width / 8.0
    end

    def bit_aligned?
      true
    end

    private

    def posit_width
      eval_parameter(:nbits).to_int
    end

    def exponent_size
      eval_parameter(:es).to_int
    end

    def encoded_bits
      PositCodec.encode(_value, posit_width, exponent_size)
    end

    def sensible_default
      0
    end

    def read_and_return_value(io)
      bits = io.readbits(posit_width, :big)
      PositCodec.decode(bits, posit_width, exponent_size)
    end
  end

  class PositArgProcessor < BaseArgProcessor
    def sanitize_parameters!(_obj_class, params)
      params.must_be_integer(:n, :nbits, :es)

      params[:nbits] = params.delete(:n) if params.has_parameter?(:n)
      unless params.has_parameter?(:nbits)
        raise ArgumentError, "parameter 'n' or 'nbits' must be specified"
      end

      unless params.has_parameter?(:es)
        raise ArgumentError, "parameter 'es' must be specified"
      end

      params[:nbits] = params[:nbits].to_int
      params[:es] = params[:es].to_int

      if params[:nbits] < 1
        raise ArgumentError, "parameter 'nbits' must be >= 1"
      end

      if params[:es] < 0
        raise ArgumentError, "parameter 'es' must be >= 0"
      end
    end
  end

  module PositCodec # :nodoc: all
    class << self
      def coerce(value)
        value = value.snapshot if value.respond_to?(:snapshot)
        return Posit::NAR if value == Posit::NAR

        case value
        when Integer
          Rational(value)
        when Rational
          value
        when BigDecimal
          unless value.finite?
            raise ArgumentError, "Posit values must be finite"
          end

          value.to_r
        else
          raise ArgumentError,
                "Posit values must be an Integer, Rational, finite BigDecimal, or NAR"
        end
      end

      def encode(value, nbits, exponent_size)
        nbits, exponent_size = validate_parameters(nbits, exponent_size)
        value = coerce(value)
        return 1 << (nbits - 1) if value == Posit::NAR
        return 0 if value.zero? || nbits == 1

        negative = value.negative?
        magnitude = negative ? -value : value
        bits = encode_positive(magnitude, nbits, exponent_size)

        negative ? ((1 << nbits) - bits) : bits
      end

      def decode(bits, nbits, exponent_size)
        nbits, exponent_size = validate_parameters(nbits, exponent_size)
        bits &= (1 << nbits) - 1

        return 0 if bits.zero?
        return Posit::NAR if nbits == 1 || bits == (1 << (nbits - 1))

        if bits >= (1 << (nbits - 1))
          positive_bits = (1 << nbits) - bits
          -decode_positive(positive_bits, nbits, exponent_size)
        else
          decode_positive(bits, nbits, exponent_size)
        end
      end

      private

      def validate_parameters(nbits, exponent_size)
        unless nbits.respond_to?(:to_int)
          raise ArgumentError, "Posit nbits must be an integer"
        end

        nbits = nbits.to_int
        unless exponent_size.respond_to?(:to_int)
          raise ArgumentError, "Posit es must be an integer"
        end

        exponent_size = exponent_size.to_int
        if nbits < 1
          raise ArgumentError, "Posit nbits must be >= 1"
        end

        if exponent_size < 0
          raise ArgumentError, "Posit es must be >= 0"
        end

        [nbits.to_int, exponent_size.to_int]
      end

      def encode_positive(value, nbits, exponent_size)
        useed_exponent = 1 << exponent_size
        q = floor_log2(value)
        qmax = (nbits - 2) * useed_exponent
        qmin = -(nbits - 2) * useed_exponent
        max_bits = (1 << (nbits - 1)) - 1

        return max_bits if q >= qmax

        minpos = Rational(1, 1 << (-qmin))
        if q < qmin
          midpoint = minpos / 2
          return value <= midpoint ? 0 : 1
        end

        k = q.div(useed_exponent)
        regime_bits, regime_length = regime(k, nbits - 1)
        tail_length = nbits - 1 - regime_length
        exponent_bits_count = [exponent_size, tail_length].min
        fraction_bits_count = tail_length - exponent_bits_count

        remainder = q - k * useed_exponent
        exponent_bits =
          if exponent_bits_count.zero?
            0
          else
            remainder >> (exponent_size - exponent_bits_count)
          end

        significand_scale = q >= 0 ? Rational(1 << q) : Rational(1, 1 << -q)
        significand = value / significand_scale
        fraction_bits =
          ((significand - 1) * (1 << fraction_bits_count)).floor

        truncated_bits =
          (regime_bits << tail_length) |
          (exponent_bits << fraction_bits_count) |
          fraction_bits

        return truncated_bits if truncated_bits == max_bits

        lower_value = decode_positive(truncated_bits, nbits, exponent_size)
        upper_value = decode_positive(truncated_bits + 1, nbits, exponent_size)
        midpoint = (lower_value + upper_value) / 2
        choose_even_value = truncated_bits.even?

        if value < midpoint
          truncated_bits
        elsif value > midpoint
          truncated_bits + 1
        elsif choose_even_value
          truncated_bits
        else
          truncated_bits + 1
        end
      end

      def decode_positive(bits, nbits, exponent_size)
        trailing_length = nbits - 1
        position = trailing_length - 1
        first_bit = (bits >> position) & 1

        run_length = 0
        while position >= 0 && ((bits >> position) & 1) == first_bit
          run_length += 1
          position -= 1
        end

        if first_bit == 1
          k = run_length - 1
          consumed = run_length == trailing_length ? run_length : run_length + 1
        else
          k = -run_length
          consumed = run_length + 1
        end

        remaining = trailing_length - consumed
        exponent_bits_count = [exponent_size, remaining].min
        fraction_bits_count = remaining - exponent_bits_count
        exponent_bits =
          ((bits >> fraction_bits_count) &
            ((1 << exponent_bits_count) - 1)) <<
            (exponent_size - exponent_bits_count)
        fraction_bits = bits & ((1 << fraction_bits_count) - 1)
        q = k * (1 << exponent_size) + exponent_bits
        scale = q >= 0 ? Rational(1 << q) : Rational(1, 1 << -q)

        Rational(
          (1 << fraction_bits_count) + fraction_bits,
          1 << fraction_bits_count
        ) * scale
      end

      def regime(k, trailing_length)
        if k >= 0
          run_length = k + 1
          if run_length >= trailing_length
            [(1 << trailing_length) - 1, trailing_length]
          else
            bits = (((1 << run_length) - 1) << 1)
            [bits, run_length + 1]
          end
        else
          run_length = -k
          if run_length >= trailing_length
            [0, trailing_length]
          else
            [1, run_length + 1]
          end
        end
      end

      def floor_log2(value)
        exponent = value.numerator.bit_length - value.denominator.bit_length
        power_of_two =
          if exponent >= 0
            Rational(1 << exponent)
          else
            Rational(1, 1 << -exponent)
          end

        exponent += 1 while value >= power_of_two * 2
        exponent -= 1 while value < power_of_two
        exponent
      end
    end
  end
end
