require 'bindata/base_primitive'

module BinData
  # IEEE 754-2008 decimal128 floating point with DPD (densely packed
  # decimal) significand encoding.
  #
  # A finite decimal128 value is a sign, a decimal coefficient of up to
  # 34 digits and a decimal exponent.  The quantum (exponent) of a value
  # is preserved when reading, so 1.20 and 1.2 remain distinct
  # representations.  Infinities and quiet/signaling NaNs with payloads
  # are also representable.
  #
  # Values are never converted through Float to perform the encoding.
  # Encoding rounds only when the coefficient has more than 34
  # significant digits or the exponent lies outside the encodable range;
  # the rounding mode is selected by the caller and the resulting status
  # flags (inexact, overflow, ...) are reported to the caller.
  module Decimal128
    # Number of significant decimal digits.
    PRECISION = 34

    # Maximum adjusted exponent (position of the most significant digit).
    EMAX = 6144

    # Minimum adjusted exponent for normal (non-subnormal) numbers.
    EMIN = -6143

    # Bias of the encoded exponent.
    EXPONENT_BIAS = 6176

    # Maximum encodable (quantum) exponent: value = coefficient * 10**exponent.
    Q_MAX = EMAX - (PRECISION - 1)

    # Minimum encodable (quantum) exponent (Etiny).
    Q_MIN = EMIN - (PRECISION - 1)

    # Largest finite coefficient (34 nines).
    MAX_COEFFICIENT = 10**PRECISION - 1

    # Largest coefficient that is still subnormal when the exponent is Q_MIN.
    MAX_SUBNORMAL_COEFFICIENT = 10**(PRECISION - 1) - 1

    # Largest NaN payload (33 digits in the coefficient continuation field).
    MAX_PAYLOAD = 10**(PRECISION - 1) - 1

    # Number of decimal digits held in the coefficient continuation field.
    CONTINUATION_DIGITS = PRECISION - 1

    MASK64 = (1 << 64) - 1

    # Rounding modes accepted when encoding a value.
    ROUND_MODES = %i[half_even half_up half_down down up ceiling floor].freeze

    # Status flags produced when encoding a decimal128 value.
    class Status
      include Enumerable

      KNOWN_FLAGS = %i[inexact rounded overflow underflow subnormal clamped].freeze

      def initialize(flags = [])
        flags = flags.map(&:to_sym).uniq
        unknown = flags - KNOWN_FLAGS
        unless unknown.empty?
          raise ArgumentError, "unknown status flags: #{unknown.join(', ')}"
        end
        @flags = flags.freeze
        freeze
      end

      def each(&block)
        @flags.each(&block)
      end

      def empty?
        @flags.empty?
      end

      def include?(flag)
        @flags.include?(flag)
      end

      def to_a
        @flags.dup
      end

      KNOWN_FLAGS.each do |flag|
        define_method("#{flag}?") { @flags.include?(flag) }
      end

      def ==(other)
        other.is_a?(Status) && to_a.sort == other.to_a.sort
      end

      def to_s
        @flags.empty? ? 'ok' : @flags.join(',')
      end

      def inspect
        "#<BinData::Decimal128::Status #{self}>"
      end
    end

    # An immutable decimal128 value: sign, decimal coefficient and
    # exponent for finite numbers, or an infinity / NaN (with payload).
    #
    # The quantum is part of the representation: the values 1.20 and 1.2
    # compare equal numerically but keep distinct representations.
    class Value
      include Comparable

      attr_reader :kind, :sign, :coefficient, :exponent, :payload

      FINITE_PATTERN = /\A([+-]?)(?:(\d+)(?:\.(\d*))?|\.(\d+))(?:[eE]([+-]?\d+))?\z/
      SPECIAL_PATTERN = /\A([+-]?)(inf(?:inity)?|nan(\d*)|snan(\d*))\z/i

      class << self
        def finite(sign: 1, coefficient:, exponent: 0)
          new(:finite, sign: sign, coefficient: coefficient, exponent: exponent)
        end

        def infinity(sign: 1)
          new(:infinity, sign: sign)
        end

        def nan(payload: 0, signaling: false, sign: 1)
          new(:nan, sign: sign, payload: payload, signaling: signaling)
        end

        def zero
          finite(sign: 1, coefficient: 0, exponent: 0)
        end

        # Parses a string such as "1.20", "-1.5E+3", "Infinity", "NaN"
        # or "sNaN123".  Trailing zeros are significant: "1.20" parses to
        # coefficient 120 and exponent -2.
        def parse(str)
          s = str.to_s.strip
          if (m = SPECIAL_PATTERN.match(s))
            sign = m[1] == '-' ? -1 : 1
            word = m[2].downcase
            if word.start_with?('inf')
              infinity(sign: sign)
            elsif word.start_with?('snan')
              nan(payload: m[4].to_i, signaling: true, sign: sign)
            else
              nan(payload: m[3].to_i, signaling: false, sign: sign)
            end
          elsif (m = FINITE_PATTERN.match(s))
            sign = m[1] == '-' ? -1 : 1
            int_part = m[2] || ''
            frac_part = m[3] || m[4] || ''
            coefficient = (int_part + frac_part).to_i
            exponent = (m[5] ? m[5].to_i : 0) - frac_part.length
            finite(sign: sign, coefficient: coefficient, exponent: exponent)
          else
            raise ArgumentError, "invalid decimal128 value #{str.inspect}"
          end
        end

        # Converts +obj+ to a Value.  Accepts Value, Integer, String,
        # Rational and BigDecimal.  Float is rejected because converting
        # through binary floating point would lose decimal precision.
        def coerce(obj)
          case obj
          when Value
            obj
          when Integer
            finite(sign: obj.negative? ? -1 : 1, coefficient: obj.abs, exponent: 0)
          when ::String
            parse(obj)
          when Rational
            from_rational(obj)
          when Float
            raise ArgumentError,
                  'cannot convert Float to a decimal128 value without losing ' \
                  'decimal precision; use a String, Integer, Rational, ' \
                  'BigDecimal or BinData::Decimal128::Value'
          else
            if defined?(BigDecimal) && obj.is_a?(BigDecimal)
              from_bigdecimal(obj)
            elsif obj.respond_to?(:snapshot)
              coerce(obj.snapshot)
            else
              raise ArgumentError, "cannot coerce #{obj.class} to BinData::Decimal128::Value"
            end
          end
        end

        private

        def from_rational(rat)
          num = rat.numerator
          den = rat.denominator
          twos = 0
          while den.even?
            den /= 2
            twos += 1
          end
          fives = 0
          while (den % 5).zero?
            den /= 5
            fives += 1
          end
          unless den == 1
            raise ArgumentError, "cannot exactly convert #{rat} to a decimal value"
          end
          n = [twos, fives].max
          coefficient = num.abs * 2**(n - twos) * 5**(n - fives)
          finite(sign: num.negative? ? -1 : 1, coefficient: coefficient, exponent: -n)
        end

        def from_bigdecimal(bd)
          if bd.nan?
            nan
          elsif bd.infinite?
            infinity(sign: bd.infinite?)
          else
            sign, digits, _base, exp10 = bd.split
            finite(sign: sign, coefficient: digits.to_i, exponent: exp10 - digits.length)
          end
        end
      end

      def initialize(kind, sign: 1, coefficient: 0, exponent: 0, payload: 0, signaling: false)
        @kind = kind
        @sign = sign.negative? ? -1 : 1
        @coefficient = non_negative_integer(:coefficient, coefficient)
        @exponent = integer(:exponent, exponent)
        @payload = non_negative_integer(:payload, payload)
        @signaling = signaling ? true : false
        freeze
      end

      def finite?
        @kind == :finite
      end

      def infinity?
        @kind == :infinity
      end

      def nan?
        @kind == :nan
      end

      def signaling?
        @signaling
      end

      def zero?
        finite? && @coefficient.zero?
      end

      def negative?
        @sign.negative?
      end

      # The quantum of this value: 10**exponent.
      def quantum
        @exponent.negative? ? Rational(1, 10**(-@exponent)) : 10**@exponent
      end

      # The exponent of the most significant digit of a finite value.
      def adjusted_exponent
        @exponent + @coefficient.to_s.length - 1
      end

      # True when both values have the same kind, sign, coefficient,
      # exponent, payload and signaling bit.  Note that 1.20 and 1.2 are
      # numerically equal but do not share the same representation.
      def same_representation?(other)
        other.is_a?(Value) &&
          kind == other.kind &&
          sign == other.sign &&
          coefficient == other.coefficient &&
          exponent == other.exponent &&
          payload == other.payload &&
          signaling? == other.signaling?
      end

      def <=>(other)
        other = Value.coerce(other)
        return nil if nan? || other.nan?

        if infinity? || other.infinity?
          return compare_infinity(other)
        end

        s1 = zero? ? 0 : sign
        s2 = other.zero? ? 0 : other.sign
        return s1 <=> s2 unless s1 == s2
        return 0 if s1.zero?

        cmp = compare_magnitude(other)
        s1.negative? ? -cmp : cmp
      rescue ArgumentError
        nil
      end

      def ==(other)
        cmp = self <=> other
        !cmp.nil? && cmp.zero?
      end

      def eql?(other)
        same_representation?(other)
      end

      def hash
        [@kind, @sign, @coefficient, @exponent, @payload, @signaling].hash
      end

      def to_s
        case @kind
        when :infinity
          @sign.negative? ? '-Infinity' : 'Infinity'
        when :nan
          str = signaling? ? 'sNaN' : 'NaN'
          str += @payload.to_s if @payload.positive?
          @sign.negative? ? "-#{str}" : str
        else
          digits = @coefficient.to_s
          str =
            if @exponent.zero?
              digits
            elsif @exponent.negative?
              point = digits.length + @exponent
              if point.positive?
                "#{digits[0...point]}.#{digits[point..]}"
              elsif point >= -5
                "0.#{'0' * (-point)}#{digits}"
              else
                scientific_string(digits)
              end
            else
              scientific_string(digits)
            end
          @sign.negative? ? "-#{str}" : str
        end
      end

      def inspect
        "#<BinData::Decimal128::Value #{self}>"
      end

      private

      def scientific_string(digits)
        adjusted = adjusted_exponent
        mantissa = digits.length == 1 ? digits : "#{digits[0]}.#{digits[1..]}"
        "#{mantissa}E#{adjusted.negative? ? '' : '+'}#{adjusted}"
      end

      def compare_infinity(other)
        if infinity? && other.infinity?
          sign <=> other.sign
        elsif infinity?
          sign.positive? ? 1 : -1
        else
          other.sign.positive? ? -1 : 1
        end
      end

      def compare_magnitude(other)
        min_exp = [@exponent, other.exponent].min
        a = @coefficient * 10**(@exponent - min_exp)
        b = other.coefficient * 10**(other.exponent - min_exp)
        a <=> b
      end

      def integer(name, val)
        unless val.is_a?(Integer)
          raise ArgumentError, "#{name} must be an Integer, got #{val.inspect}"
        end
        val
      end

      def non_negative_integer(name, val)
        integer(name, val)
        if val.negative?
          raise ArgumentError, "#{name} must not be negative, got #{val}"
        end
        val
      end
    end
    class << self
      # Encodes +value+ as a 128 bit integer.  Returns
      # [bits, BinData::Decimal128::Status].  +round_mode+ is one of
      # ROUND_MODES and is only consulted when the value does not fit
      # exactly.
      def encode(value, round_mode: :half_even)
        value = Value.coerce(value)
        mode = validate_round_mode!(round_mode)

        case value.kind
        when :nan
          encode_nan(value)
        when :infinity
          sign_bit = value.negative? ? 1 : 0
          [(sign_bit << 127) | (0b11110 << 122), Status.new]
        else
          encode_finite(value, mode)
        end
      end

      # Decodes a 128 bit integer into a BinData::Decimal128::Value.
      # The encoded quantum is preserved: no normalisation is performed.
      def decode(bits)
        sign = bits[127].zero? ? 1 : -1
        combination = (bits >> 122) & 0x1F

        case combination
        when 0b11110
          Value.infinity(sign: sign)
        when 0b11111
          signaling = !bits[121].zero?
          payload = decode_continuation(bits)
          Value.nan(payload: payload, signaling: signaling, sign: sign)
        else
          if combination >= 0b11000
            etop = (combination >> 1) & 0x3
            leading = 8 | (combination & 1)
          else
            etop = combination >> 3
            leading = combination & 0x7
          end
          biased = (etop << 12) | ((bits >> 110) & 0xFFF)
          exponent = biased - EXPONENT_BIAS
          coefficient = leading * 10**(PRECISION - 1) + decode_continuation(bits)
          Value.finite(sign: sign, coefficient: coefficient, exponent: exponent)
        end
      end

      # DPD encodes three decimal digits into a 10 bit declet.
      def dpd_encode(d2, d1, d0)
        a = d2 >> 3
        e = d1 >> 3
        i = d0 >> 3
        bcd = d2 & 0x7
        fgh = d1 & 0x7
        jkm = d0 & 0x7
        d = d2 & 1
        h = d1 & 1
        m = d0 & 1
        j = (d0 >> 2) & 1
        k = (d0 >> 1) & 1
        f = (d1 >> 2) & 1
        g = (d1 >> 1) & 1

        case (a << 2) | (e << 1) | i
        when 0b000 then (bcd << 7) | (fgh << 4) | jkm
        when 0b001 then (bcd << 7) | (fgh << 4) | 0b1000 | m
        when 0b010 then (bcd << 7) | (j << 6) | (k << 5) | (h << 4) | 0b1010 | m
        when 0b011 then (bcd << 7) | (h << 4) | 0b1110 | m
        when 0b100 then (j << 9) | (k << 8) | (d << 7) | (fgh << 4) | 0b1100 | m
        when 0b101 then (f << 9) | (g << 8) | (d << 7) | (1 << 5) | (h << 4) | 0b1110 | m
        when 0b110 then (j << 9) | (k << 8) | (d << 7) | (1 << 6) | (h << 4) | 0b1110 | m
        else             (d << 7) | (1 << 6) | (1 << 5) | (h << 4) | 0b1110 | m
        end
      end

      # Decodes a 10 bit DPD declet into three decimal digits.
      def dpd_decode(declet)
        p = (declet >> 9) & 1
        q = (declet >> 8) & 1
        r = (declet >> 7) & 1
        s = (declet >> 6) & 1
        t = (declet >> 5) & 1
        u = (declet >> 4) & 1
        v = (declet >> 3) & 1
        w = (declet >> 2) & 1
        x = (declet >> 1) & 1
        y = declet & 1

        pqr = (p << 2) | (q << 1) | r
        stu = (s << 2) | (t << 1) | u

        if v.zero?
          [pqr, stu, (w << 2) | (x << 1) | y]
        else
          case (w << 1) | x
          when 0b00 then [pqr, stu, 8 | y]
          when 0b01 then [pqr, 8 | u, (s << 2) | (t << 1) | y]
          when 0b10 then [8 | r, stu, (p << 2) | (q << 1) | y]
          else
            case (s << 1) | t
            when 0b00 then [pqr, 8 | u, 8 | y]
            when 0b01 then [8 | r, (p << 2) | (q << 1) | u, 8 | y]
            when 0b10 then [8 | r, 8 | u, (p << 2) | (q << 1) | y]
            else             [8 | r, 8 | u, 8 | y]
            end
          end
        end
      end

      private

      def validate_round_mode!(round_mode)
        mode = round_mode.to_sym
        unless ROUND_MODES.include?(mode)
          raise ArgumentError,
                "invalid round_mode #{round_mode.inspect}; " \
                "expected one of #{ROUND_MODES.join(', ')}"
        end
        mode
      end

      def encode_nan(value)
        if value.payload > MAX_PAYLOAD
          raise ArgumentError,
                "NaN payload #{value.payload} exceeds the decimal128 " \
                "maximum of #{MAX_PAYLOAD}"
        end
        sign_bit = value.negative? ? 1 : 0
        bits = (sign_bit << 127) | (0b11111 << 122)
        bits |= 1 << 121 if value.signaling?
        bits |= encode_continuation(value.payload)
        [bits, Status.new]
      end

      def encode_finite(value, mode)
        sign = value.sign
        coefficient = value.coefficient
        exponent = value.exponent
        flags = []

        if coefficient.zero?
          if exponent > Q_MAX
            exponent = Q_MAX
            flags << :clamped
          elsif exponent < Q_MIN
            exponent = Q_MIN
            flags << :clamped
          end
          return [pack_finite(sign, coefficient, exponent), Status.new(flags)]
        end

        digits = coefficient.to_s.length
        if digits > PRECISION
          drop = digits - PRECISION
          coefficient, inexact = round_shift(coefficient, drop, sign, mode)
          exponent += drop
          flags << :rounded
          flags << :inexact if inexact
          if coefficient > MAX_COEFFICIENT
            # rounding carried into a 35th digit
            coefficient /= 10
            exponent += 1
          end
        end

        if exponent > Q_MAX
          shift = exponent - Q_MAX
          if coefficient.to_s.length + shift <= PRECISION
            coefficient *= 10**shift
            exponent = Q_MAX
            flags << :clamped
          else
            return overflow_result(sign, mode)
          end
        end

        if exponent < Q_MIN
          shift = Q_MIN - exponent
          coefficient, inexact = round_shift(coefficient, shift, sign, mode)
          exponent = Q_MIN
          flags << :rounded
          flags << :inexact if inexact
          if coefficient <= MAX_SUBNORMAL_COEFFICIENT
            flags << :subnormal
            flags << :underflow if inexact
            flags << :clamped if coefficient.zero?
          end
        elsif coefficient.positive? && coefficient <= MAX_SUBNORMAL_COEFFICIENT && exponent == Q_MIN
          flags << :subnormal
        end

        [pack_finite(sign, coefficient, exponent), Status.new(flags)]
      end

      def overflow_result(sign, mode)
        to_infinity =
          case mode
          when :down then false
          when :ceiling then sign.positive?
          when :floor then sign.negative?
          else true
          end
        bits =
          if to_infinity
            ((sign.negative? ? 1 : 0) << 127) | (0b11110 << 122)
          else
            pack_finite(sign, MAX_COEFFICIENT, Q_MAX)
          end
        [bits, Status.new(%i[overflow inexact rounded])]
      end

      # Divides +coefficient+ by 10**digits_to_drop, rounding the result
      # according to +mode+.  Returns [quotient, inexact].
      def round_shift(coefficient, digits_to_drop, sign, mode)
        return [coefficient, false] if digits_to_drop <= 0

        if digits_to_drop > coefficient.to_s.length
          # the divisor is more than ten times the coefficient, so the
          # remainder is well below half the divisor
          inexact = !coefficient.zero?
          increment = inexact &&
            (mode == :up ||
             (mode == :ceiling && sign.positive?) ||
             (mode == :floor && sign.negative?))
          return [increment ? 1 : 0, inexact]
        end

        divisor = 10**digits_to_drop
        quotient, remainder = coefficient.divmod(divisor)
        return [quotient, false] if remainder.zero?

        increment =
          case mode
          when :down then false
          when :up then true
          when :ceiling then sign.positive?
          when :floor then sign.negative?
          when :half_up then 2 * remainder >= divisor
          when :half_down then 2 * remainder > divisor
          else # half_even
            twice = 2 * remainder
            twice > divisor || (twice == divisor && quotient.odd?)
          end
        [increment ? quotient + 1 : quotient, true]
      end

      def pack_finite(sign, coefficient, exponent)
        biased = exponent + EXPONENT_BIAS
        leading = coefficient / 10**(PRECISION - 1)
        continuation = coefficient % 10**(PRECISION - 1)
        etop = biased >> 12
        combination =
          if leading < 8
            (etop << 3) | leading
          else
            0b11000 | (etop << 1) | (leading & 1)
          end
        sign_bit = sign.negative? ? 1 : 0
        (sign_bit << 127) |
          (combination << 122) |
          ((biased & 0xFFF) << 110) |
          encode_continuation(continuation)
      end

      # DPD encodes the 33 least significant digits of +coefficient+ into
      # the 110 bit coefficient continuation field.
      def encode_continuation(coefficient)
        digits = coefficient.to_s.rjust(CONTINUATION_DIGITS, '0')
        bits = 0
        11.times do |i|
          declet = dpd_encode(digits[i * 3].to_i, digits[i * 3 + 1].to_i, digits[i * 3 + 2].to_i)
          bits |= declet << (10 * (10 - i))
        end
        bits
      end

      # Decodes the 110 bit coefficient continuation field of +bits+ into
      # an integer of up to 33 decimal digits.
      def decode_continuation(bits)
        digits = +''
        11.times do |i|
          declet = (bits >> (10 * (10 - i))) & 0x3FF
          d2, d1, d0 = dpd_decode(declet)
          digits << d2.to_s << d1.to_s << d0.to_s
        end
        digits.to_i
      end
    end
  end

  # Shared behaviour for the decimal128 data types.
  module Decimal128Primitive
    def assign(val)
      raise ArgumentError, "can't set a nil value for #{debug_name}" if val.nil?

      super(Decimal128::Value.coerce(val))
    end

    # The BinData::Decimal128::Status flags produced by the most recent
    # encoding of this object's value (via #to_binary_s or #write).
    def encode_status
      @last_encode_status || Decimal128::Status.new
    end

    def do_num_bytes
      16
    end

    #---------------
    private

    def sensible_default
      Decimal128::Value.zero
    end

    def current_round_mode
      return :half_even unless has_parameter?(:round_mode)

      raw = get_parameter(:round_mode)
      raw.is_a?(Symbol) ? raw : eval_parameter(:round_mode)
    end
  end

  # IEEE 754 decimal128 floating point number (DPD encoding) in little
  # endian format.  Endianness only affects the byte order of the 16
  # encoded bytes, not the DPD digit mapping.
  #
  # Values may be BinData::Decimal128::Value objects, Strings ("1.20"),
  # Integers, Rationals or BigDecimals.  Floats are rejected.  The
  # :round_mode parameter selects the rounding mode used when a value
  # does not fit exactly; #encode_status reports the resulting flags.
  class Decimal128Le < BinData::BasePrimitive
    optional_parameters :round_mode
    include Decimal128Primitive

    #---------------
    private

    def value_to_binary_string(val)
      bits, status = Decimal128.encode(val, round_mode: current_round_mode)
      @last_encode_status = status
      [bits & Decimal128::MASK64, bits >> 64].pack('Q<Q<')
    end

    def read_and_return_value(io)
      lo, hi = io.readbytes(16).unpack('Q<Q<')
      @last_encode_status = Decimal128::Status.new
      Decimal128.decode((hi << 64) | lo)
    end
  end

  # IEEE 754 decimal128 floating point number (DPD encoding) in big
  # endian format.
  class Decimal128Be < BinData::BasePrimitive
    optional_parameters :round_mode
    include Decimal128Primitive

    #---------------
    private

    def value_to_binary_string(val)
      bits, status = Decimal128.encode(val, round_mode: current_round_mode)
      @last_encode_status = status
      [bits >> 64, bits & Decimal128::MASK64].pack('Q>Q>')
    end

    def read_and_return_value(io)
      hi, lo = io.readbytes(16).unpack('Q>Q>')
      @last_encode_status = Decimal128::Status.new
      Decimal128.decode((hi << 64) | lo)
    end
  end
end
