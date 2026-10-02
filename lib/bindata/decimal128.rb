# frozen_string_literal: true

require 'bigdecimal'
require 'bindata/base_primitive'

module BinData
  class Decimal128Status < ::Hash
    def initialize(flags = nil)
      super()
      %i[clamped rounded inexact overflow underflow subnormal].each { |k| self[k] = false }
      Array(flags).each { |k| self[k.to_sym] = true if key?(k.to_sym) }
    end

    def to_a
      select { |_, v| v }.keys
    end

    def to_s
      to_a.map(&:to_s).join(' ')
    end
  end

  class Decimal128Value
    FINITE = :finite
    QNAN = :qnan
    SNAN = :snan
    INFINITY = :infinity
    ROUNDING_MODES = %i[half_even half_up ceiling floor down truncate].freeze

    attr_reader :kind, :sign, :coefficient, :exponent, :significant_digits, :payload, :status

    def initialize(kind: FINITE, sign: false, coefficient: 0, exponent: 0,
                   significant_digits: nil, payload: 0, status: nil)
      @kind = kind
      @sign = sign
      @payload = payload.to_i.abs
      @status = Decimal128Status.new(status)
      if finite?
        @coefficient = coefficient.to_i.abs
        @exponent = exponent.to_i
        @significant_digits = significant_digits || significant_count(@coefficient)
      end
      freeze
    end

    def finite?; kind == FINITE; end
    def nan?; kind == QNAN || kind == SNAN; end
    def infinity?; kind == INFINITY; end
    def qnan?; kind == QNAN; end
    def snan?; kind == SNAN; end
    def negative?; sign; end
    def quantum; exponent; end

    def self.finite(coefficient, exponent = 0, sign: false, significant_digits: nil, status: nil)
      new(kind: FINITE, coefficient: coefficient, exponent: exponent, sign: sign,
          significant_digits: significant_digits, status: status)
    end

    def self.nan(payload = 0, signaling: false, sign: false)
      new(kind: signaling ? SNAN : QNAN, payload: payload, sign: sign)
    end

    def self.infinity(sign: false)
      new(kind: INFINITY, sign: sign)
    end

    def with(flags = {})
      value = finite? ? @coefficient : @payload
      self.class.new(
        kind: @kind, sign: flags.fetch(:sign, @sign), coefficient: value, exponent: @exponent,
        significant_digits: @significant_digits, payload: @payload, status: status.to_a + Array(flags[:status])
      )
    end

    def ==(other)
      return false unless other.is_a?(Decimal128Value)
      if finite? && other.finite?
        sign == other.sign && coefficient == other.coefficient && exponent == other.exponent &&
          significant_digits == other.significant_digits
      else
        kind == other.kind && sign == other.sign && payload == other.payload
      end
    end
    alias eql? ==

    def hash
      finite? ? [kind,sign,coefficient,exponent,significant_digits].hash : [kind,sign,payload].hash
    end

    def to_s
      return "#{"-" if sign}Infinity" if infinity?
      return "#{"-" if sign}#{'s' if snan?}NaN#{payload.nonzero?}" if nan?
      digits = coefficient.zero? ? '0' : coefficient.to_s
      digits = digits.rjust(significant_digits, '0') if significant_digits > digits.length
      formatted = decimal_string(digits, exponent)
      "#{"-" if sign}#{formatted}"
    end

    def inspect
      "#<BinData::Decimal128 #{self}#{" #{status}" unless status.empty?}>"
    end

    def snapshot
      self
    end

    private

    def significant_count(value)
      value.zero? ? 1 : value.to_s.length
    end

    def decimal_string(digits, exponent)
      adjusted = exponent + digits.length - 1
      return "0E#{adjusted}" if coefficient.zero?
      q = -exponent
      return "#{digits}E#{exponent}" if exponent > 0
      return digits if q == 0
      if q < digits.length
        pos = digits.length - q
        "#{digits[0...pos]}.#{digits[pos..]}"
      else
        "0.#{"0" * (q - digits.length)}#{digits}"
      end
    end

    class << self
      PARSER = /\A([+-]?)\s*(?:(?:(sNaN|NaN)([0-9]*))|(Infinity)|(?:(?:(\d+(?:\.\d*)?|\.\d+)(?:[eE]([+-]?\d+))?)))\z/i

      def parse(input, rounding: :half_even, context: nil)
        str = normalize_input(input)
        m = PARSER.match(str)
        raise ArgumentError, "invalid decimal128 value: #{input}" unless m
        sign = m[1] == '-'
        return infinity(sign: sign) if m[4]
        if m[2]
          signaling = m[2].downcase.start_with?('s')
          payload = (m[3] || '').to_i
          return nan(payload, signaling: signaling, sign: sign)
        end
        mant = m[5].delete('.')
        decimal_places = m[5].include?('.') ? m[5].sub(/^\d*\.?/, '').length : 0
        exp = (m[6] || '0').to_i - decimal_places
        rounded(mant.to_i, exp, sign, mant.sub(/^0+/, '').length, rounding, context)
      end

      def rounded(coefficient, exponent, sign, digits, mode, _context = nil)
        digits = 1 if coefficient.zero?
        status = Decimal128Status.new
        coefficient = coefficient.abs
        if digits > 34
          coefficient, exponent, digits, removed = round_integer(coefficient, exponent, digits, mode, sign)
          status[:rounded] = true
          status[:inexact] = true unless removed.zero?
        end
        status[:clamped] = true if clamp_after_precision?(coefficient, digits, exponent)
        exponent = exponent < -6176 ? -6176 : exponent
        finite(coefficient, exponent, sign: sign, significant_digits: digits, status: status)
      end

      private

      def normalize_input(input)
        case input
        when String then input
        when Integer then input.to_s
        when BigDecimal then input.to_s('F')
        when Numeric then format('%.1E', input.to_f)
        when Decimal128Value then return input.to_s
        else input.to_s
        end
      end

      def round_integer(value, exponent, digits, mode, negative)
        scale = 10**(digits - 34)
        quotient, remainder = value.divmod(scale)
        return [quotient, exponent + digits - 34, 34, remainder] if remainder.zero?
        increment = round_up?(quotient, remainder, scale, mode, negative)
        [quotient + (increment ? 1 : 0), exponent + digits - 34, 34, remainder]
      end

      def round_up?(quotient, remainder, scale, mode, negative)
        half = scale / 2
        case mode
        when :down, :truncate then false
        when :ceiling then !negative && remainder.nonzero?
        when :floor then negative && remainder.nonzero?
        when :half_up then remainder >= half
        else remainder > half || (remainder == half && quotient.odd?)
        end
      end

      def clamp_after_precision?(_coefficient, digits, exponent)
        adjusted = exponent + digits - 1
        adjusted > 6144
      end
    end
  end

  class Decimal128 < BasePrimitive
    ROUNDING_MODES = Decimal128Value::ROUNDING_MODES
    optional_parameter :rounding

    def self.rounding_mode(value)
      value = value.to_sym
      raise ArgumentError, "unknown rounding mode #{value}" unless ROUNDING_MODES.include?(value)
      value
    end

    def assign(val)
      @decimal_value = normalize_value(val)
      super(@decimal_value)
    end

    def do_num_bytes
      16
    end

    def rounding
      mode = get_parameter(:rounding) || :half_even
      mode.is_a?(Symbol) ? mode : mode.to_sym
    end

    def encode(value = nil)
      value ||= self.value
      value = normalize_value(value) unless value.is_a?(Decimal128Value)
      Decimal128Codec.encode(value)
    end

    def decode(bytes)
      @decimal_value = Decimal128Codec.decode(bytes)
      @decimal_value
    end

    def sensible_default
      Decimal128Value.finite(0, 0, significant_digits: 1)
    end

    def value_to_binary_string(val)
      v = val.is_a?(Decimal128Value) ? val : Decimal128Value.parse(val, rounding: rounding)
      encode(v).bytes.map { |b| (b & 0xff).chr }.join
    end

    def read_and_return_value(io)
      decode(io.readbytes(16).b)
    end

    def status
      @decimal_value&.status || Decimal128Status.new
    end

    private

    def normalize_value(val)
      return val if val.is_a?(Decimal128Value)
      Decimal128Value.parse(val, rounding: rounding)
    end
  end

  module Decimal128Codec
    ENCODE = Hash[eval('{'+File.read(File.expand_path('decimal128_encode.txt', __dir__))+'}').map { |k,v| [k.to_i, v] }]
    DECODE = File.read(File.expand_path('decimal128_decode.txt', __dir__)).split(',').map(&:to_i)
    BIAS = 6176
    QMAX = 6111
    QMIN = -6176

    module_function

    def encode(value)
      bits =
        if value.infinity?
          0x7c000000000000000000000000000000
        elsif value.nan?
          signaling = (value.raw_combo_for_nan rescue nil)
          (value.snan? ? 0x7e000000000000000000000000000000 : 0x7c000000000000000000000000000000) |
            (value.payload & ((1 << 110) - 1))
        else
          encode_finite(value)
        end
      bits |= 1 << 127 if value.sign
      pack(bits)
    end

    def decode(bytes)
      bits = unpack(bytes)
      sign = ((bits >> 127) & 1) == 1
      combo = (bits >> 122) & 31
      if combo == 30
        return Decimal128Value.infinity(sign: sign) if ((bits >> 125) & 1) == 1
        signaling = true
      elsif combo == 31
        signaling = false
      else
        return decode_finite(bits, combo, sign)
      end
      payload = bits & ((1 << 110) - 1)
      return Decimal128Value.nan(payload, signaling: signaling, sign: sign)
      if false
        signaling = ((bits >> 125) & 1) == 0
        payload = bits & ((1 << 110) - 1)
        return Decimal128Value.nan(payload, signaling: signaling, sign: sign)
      end
      decode_finite(bits, combo, sign)
    end

    def encode_finite(value)
      coeff = value.coefficient
      q = value.exponent
      q = [[q, QMIN].max, QMAX].min
      biased = q + BIAS
      combo =
        if coeff.zero?
          (biased >= 2**12 ? ((biased >> 12) & 3) << 3 : (biased >> 12) | (leading << 3) & 31)
        else
          digits = coeff.to_s.rjust(33, '0')
          leading = digits[0].to_i
          high = leading >= 8
          high ? (0x18 | ((leading & 1) << 1)) : ((leading << 3) | ((((biased >> 11) & 1) << 1) | ((biased >> 10) & 1)))
        end
      declets = 11.times.map do |i|
        triple = coeff.to_s.rjust(34,"0")[1 + (3 * i), 3].to_i
        ENCODE.fetch(triple)
      end
      continuation = 11.times.sum { |i| (declets[i] & 1023) << (10 * (10 - i)) }
      high_exponent = declets.first >= 512 ? 2 : 0
      (combo << 122) | ((biased & 0xfff) << 110) | continuation
    end

    def decode_finite(bits, combo, sign)
      continuation = bits & ((1 << 110) - 1)
      low_exp = ((bits >> 120) & 1) << 12 | ((bits >> 121) & 1) << 13 | ((bits >> 110) & 0x3ff)
      biased = if combo < 24
        ((combo & 8) << 9) | (low_exp & 0xfff)
      else
        ((combo & 2) << 12) | low_exp
      end
      leading = combo < 24 ? combo >> 3 : 8 + ((combo >> 1) & 1)
      digits = leading.to_s + 11.times.map do |i|
        code = (continuation >> (10 * (10 - i))) & 1023
        DECODE.fetch(code).to_s.rjust(3, '0')
      end.join
      coefficient = digits.to_i
      significant = digits.sub(/^0+/, '').length
      significant = 1 if coefficient.zero?
      exponent = biased - BIAS
      subnormal = coefficient.nonzero? && exponent + significant - 1 < -6143
      Decimal128Value.finite(coefficient, exponent, sign: sign, significant_digits: significant,
                             status: subnormal ? :subnormal : nil)
    end

    def pack(bits)
      [bits >> 64, bits & 0xffffffffffffffff].pack('Q>Q>')
    end

    def unpack(bytes)
      high, low = bytes.unpack('Q>Q>')
      (high << 64) | low
    end
  end
  class Decimal128Be < Decimal128
    def self.bindata_name
      'Decimal128be'
    end
  end

  class Decimal128Le < Decimal128
    def self.bindata_name
      'Decimal128le'
    end

    private

    def value_to_binary_string(val)
      super(val).reverse
    end

    def read_and_return_value(io)
      decode(io.readbytes(16).b.reverse)
    end
  end
end
