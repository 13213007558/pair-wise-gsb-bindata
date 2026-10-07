require 'bindata/base_primitive'

module BinData
  # A finite-alphabet symbol block encoded with a range Asymmetric Numeral
  # System (rANS).
  #
  # The wire format is self describing.  Every block contains its layout,
  # frequency sum, quantization rule, frequencies, final coder states and
  # payload length.  Decoding therefore needs no defaults supplied by the
  # surrounding application.
  #
  # All multi-byte integers are little endian.
  #
  # Byte layout:
  #   magic                     "RAN1"
  #   uint8  layout             1 = single state, 2 = interleaved states
  #   uint8  state_count        1 for layout 1; 2..255 for layout 2
  #   uint16 alphabet_size
  #   uint8  quantization_rule  0 = provided, 1 = largest remainder
  #   uint32 frequency_sum      256 (8-bit digits) or 65536 (16-bit digits)
  #   uint32 symbol_count
  #   uint32 payload_length
  #   uint32 final_states[state_count]
  #   uint16 frequencies[alphabet_size], little endian
  #   uint8  payload[payload_length]
  #
  # Quantization rule 0 stores the caller's integer frequencies unchanged.
  # They must be non-negative integers summing to the declared frequency sum.
  #
  # Quantization rule 1 accepts non-negative integer counts and quantizes to
  # the frequency sum.  Each positive count receives
  # floor(count * frequency_sum / total)
  # frequencies, with the remainder allocated to positive counts with the
  # largest remainders.  Ties resolve to the lower symbol index.
  #
  # A 256 sum uses 8-bit renormalization digits and state range
  # [2**23, 2**31).  A 65536 sum uses 16-bit little-endian digits and state
  # range [2**16, 2**32).  Encoding processes symbols in reverse order and
  # stores renormalization digits in reverse emission order.  Decoding reads
  # the payload forward.  For interleaved blocks, symbol +i+ uses state
  # +i % state_count+.
  class RansSymbolBlock < BinData::BasePrimitive
    MAGIC = "RAN1".b
    LAYOUT_SINGLE = 1
    LAYOUT_INTERLEAVED = 2
    QUANTIZATION_PROVIDED = 0
    QUANTIZATION_LARGEST_REMAINDER = 1
    HEADER_SIZE = 4 + 1 + 1 + 2 + 1 + 4 + 4 + 4
    FREQUENCY_SUMS = {256 => 8, 65536 => 16}.freeze

    optional_parameters :frequencies, :state_count, :quantization, :frequency_sum

    attr_reader :layout, :quantization_rule, :frequency_sum,
                :encoded_frequencies, :encoded_final_states, :final_states,
                :payload

    def initialize_instance
      super
      @layout = nil
      @quantization_rule = nil
      @frequency_sum = nil
      @encoded_frequencies = nil
      @encoded_final_states = nil
      @final_states = nil
      @payload = nil
    end

    def clear?
      super && @encoded_final_states.nil?
    end

    private

    def sensible_default
      []
    end

    def value_to_binary_string(symbols)
      symbols = validate_symbols(symbols)
      state_count = resolved_state_count
      frequencies, rule = normalized_frequencies
      validate_symbols_in_frequencies(symbols, frequencies)
      @encoded_frequencies = frequencies
      final_states, payload = encode(symbols, frequencies, state_count,
                                    @frequency_sum)
      @encoded_final_states = final_states
      write_block(symbols.length, state_count, frequencies, rule,
                  final_states, payload)
    end

    def read_and_return_value(io)
      decode_block(io)
    end

    def write_block(symbol_count, state_count, frequencies, rule,
                    final_states, payload)
      alphabet_size = frequencies.length
      header = [
        MAGIC,
        layout_for(state_count),
        state_count,
        alphabet_size,
        rule,
        writing_frequency_sum,
        symbol_count,
        payload.bytesize
      ].pack('a4CCSCVVV')

      header << final_states.pack('V*')
      header << pack_frequencies(frequencies)
      header << payload
      header
    end

    def decode_block(io)
      header = io.readbytes(HEADER_SIZE)
      magic, layout, state_count, alphabet_size, rule, frequency_sum,
        symbol_count, payload_length = header.unpack('a4CCSCVVV')

      raise ValidityError, "bad rANS magic #{magic.inspect}" unless magic == MAGIC
      validate_layout(layout, state_count)
      validate_quantization_rule(rule)
      validate_declared_frequency_sum(frequency_sum)

      frequency_bytes = alphabet_size * 2
      body = io.readbytes(state_count * 4 + frequency_bytes + payload_length)
      states_end = state_count * 4
      frequencies_end = states_end + frequency_bytes

      @encoded_final_states = body.byteslice(0, state_count * 4).unpack('V*')
      @encoded_frequencies = unpack_frequencies(
        body.byteslice(states_end, frequency_bytes), frequency_sum
      )
      @payload = body.byteslice(frequencies_end, payload_length).b
      @layout = layout
      @quantization_rule = rule
      @frequency_sum = frequency_sum

      unless @encoded_frequencies.sum == frequency_sum
        raise ValidityError, "rANS frequency table does not sum to #{frequency_sum}"
      end

      lower_bound = state_lower_bound(frequency_sum)
      upper_bound = state_upper_bound(frequency_sum)
      validate_states(@encoded_final_states, lower_bound, upper_bound)

      symbols, @final_states = decode(
        symbol_count, @encoded_frequencies, state_count,
        @encoded_final_states, @payload, frequency_sum
      )
      symbols
    end

    def encode(symbols, frequencies, state_count, frequency_sum)
      cumulative = cumulative_starts(frequencies)
      lower_bound = state_lower_bound(frequency_sum)
      states = ::Array.new(state_count, lower_bound)
      renorm_digits = ::Array.new

      symbols.each_with_index.reverse_each do |symbol, index|
        frequency = frequencies.fetch(symbol)
        state = states.fetch(index % state_count)

        while state >= lower_bound * frequency
          renorm_digits << pack_renorm_digit(state, frequency_sum)
          state >>= renormalization_bits(frequency_sum)
        end

        quotient, remainder = state.divmod(frequency)
        states[index % state_count] =
          quotient * frequency_sum + remainder + cumulative.fetch(symbol)
      end

      validate_states(states, lower_bound, state_upper_bound(frequency_sum))
      [states, renorm_digits.reverse.join]
    end

    def decode(symbol_count, frequencies, state_count, initial_states, payload,
               frequency_sum)
      cumulative = cumulative_starts(frequencies)
      lower_bound = state_lower_bound(frequency_sum)
      upper_bound = state_upper_bound(frequency_sum)
      digit_bits = renormalization_bits(frequency_sum)
      states = initial_states.dup
      payload_position = 0
      symbols = []

      symbol_count.times do |index|
        state_index = index % state_count
        state = states.fetch(state_index)
        slot = state % frequency_sum
        symbol = find_symbol(slot, frequencies, cumulative)
        raise ValidityError, "rANS slot #{slot} has no frequency" if symbol.nil?

        state = frequencies.fetch(symbol) * (state / frequency_sum) +
                slot - cumulative.fetch(symbol)

        while state < lower_bound
          digit, payload_position = read_renorm_digit(
            payload, payload_position, digit_bits
          )
          state = state * frequency_sum + digit
        end

        raise ValidityError, "rANS state overflow" unless state < upper_bound

        symbols << symbol
        states[state_index] = state
      end

      unless payload_position == payload.bytesize
        raise ValidityError, "rANS payload has #{payload.bytesize - payload_position} unconsumed bytes"
      end

      unless states.all? { |state| state == lower_bound }
        raise ValidityError, "rANS final states were not restored"
      end

      [symbols, states]
    end

    def validate_symbols(symbols)
      unless symbols.respond_to?(:to_ary)
        raise ArgumentError, "rANS symbols must be an array of integers"
      end

      symbols.to_ary.map do |symbol|
        unless symbol.is_a?(Integer) && symbol >= 0
          raise ArgumentError, "rANS symbol #{symbol.inspect} is not a non-negative integer"
        end
        symbol
      end
    end

    def validate_symbols_in_frequencies(symbols, frequencies)
      symbols.each do |symbol|
        if symbol >= frequencies.length || frequencies.fetch(symbol).zero?
          raise ArgumentError, "rANS symbol #{symbol} has zero frequency"
        end
      end
    end

    def resolved_state_count
      state_count = has_parameter?(:state_count) ? get_parameter(:state_count) : 1
      unless state_count.is_a?(Integer) && state_count >= 1 && state_count <= 255
        raise ArgumentError, "rANS state_count must be an integer from 1 to 255"
      end
      @layout = layout_for(state_count)
      state_count
    end

    def normalized_frequencies
      unless has_parameter?(:frequencies)
        raise ArgumentError, "rANS writing requires an integer frequency table"
      end

      frequencies = get_parameter(:frequencies)
      unless frequencies.respond_to?(:to_ary)
        raise ArgumentError, "rANS frequencies must be an array of integers"
      end

      frequencies = frequencies.to_ary.map do |frequency|
        unless frequency.is_a?(Integer) && frequency >= 0
          raise ArgumentError, "rANS frequency #{frequency.inspect} is not a non-negative integer"
        end
        frequency
      end

      if frequencies.empty? || frequencies.length > 65535
        raise ArgumentError, "rANS alphabet size must be from 1 to 65535"
      end

      @frequency_sum = writing_frequency_sum
      rule = quantization_code
      normalized =
        if rule == QUANTIZATION_PROVIDED
          frequencies
        else
          quantize_frequencies(frequencies)
        end

      unless normalized.sum == @frequency_sum
        raise ArgumentError, "rANS frequencies must sum to #{@frequency_sum}"
      end
      unless normalized.all? { |frequency| frequency <= @frequency_sum }
        raise ArgumentError, "rANS frequency values must not exceed #{@frequency_sum}"
      end

      @quantization_rule = rule
      [normalized, rule]
    end

    def writing_frequency_sum
      if has_parameter?(:frequency_sum)
        value = get_parameter(:frequency_sum)
        validate_frequency_sum(value)
        return value
      end
      256
    end

    def quantization_code
      quantization = has_parameter?(:quantization) ? get_parameter(:quantization) : :largest_remainder
      case quantization
      when :provided then QUANTIZATION_PROVIDED
      when :largest_remainder then QUANTIZATION_LARGEST_REMAINDER
      else
        raise ArgumentError, "rANS quantization must be :provided or :largest_remainder"
      end
    end

    def quantize_frequencies(counts)
      total = counts.sum
      raise ArgumentError, "rANS counts must have a positive sum" if total.zero?
      target_sum = @frequency_sum

      positive = counts.each_index.select { |index| counts[index].positive? }
      if positive.length > target_sum
        raise ArgumentError, "rANS frequency sum #{target_sum} cannot represent #{positive.length} positive symbols"
      end

      scaled = positive.map { |index| counts[index] * target_sum }
      base = scaled.map { |value| value / total }
      remaining = target_sum - base.sum

      if remaining.negative?
        raise ArgumentError, "cannot quantize rANS frequencies to #{target_sum}"
      end

      chosen = positive.each_with_index.sort_by do |index, position|
        [- (scaled[position] % total), index]
      end.first(remaining)

      frequencies = ::Array.new(counts.length, 0)
      positive.each_with_index { |index, position| frequencies[index] = base[position] }
      chosen.each { |index, _position| frequencies[index] += 1 }
      frequencies
    end

    def cumulative_starts(frequencies)
      cumulative = 0
      frequencies.map do |frequency|
        start = cumulative
        cumulative += frequency
        start
      end
    end

    def find_symbol(slot, frequencies, cumulative)
      frequencies.length.times.find do |index|
        slot >= cumulative[index] && slot < cumulative[index] + frequencies[index]
      end
    end

    def validate_states(states, lower_bound, upper_bound)
      states.each do |state|
        unless state >= lower_bound && state < upper_bound
          raise ValidityError, "rANS state overflow"
        end
      end
    end

    def validate_frequency_sum(frequency_sum)
      unless FREQUENCY_SUMS.key?(frequency_sum)
        raise ArgumentError, "rANS frequency sum must be 256 or 65536"
      end
    end

    def validate_declared_frequency_sum(frequency_sum)
      unless FREQUENCY_SUMS.key?(frequency_sum)
        raise ValidityError, "unsupported rANS frequency sum #{frequency_sum}"
      end
    end

    def renormalization_bits(frequency_sum)
      FREQUENCY_SUMS.fetch(frequency_sum)
    end

    def state_lower_bound(frequency_sum)
      frequency_sum == 256 ? 1 << 23 : frequency_sum
    end

    def state_upper_bound(frequency_sum)
      frequency_sum == 256 ? 1 << 31 : 1 << 32
    end

    def pack_renorm_digit(state, frequency_sum)
      bits = renormalization_bits(frequency_sum)
      [state & ((1 << bits) - 1)].pack(bits == 8 ? 'C' : 'v')
    end

    def read_renorm_digit(payload, position, bits)
      bytes = bits / 8
      if position + bytes > payload.bytesize
        raise ValidityError, "rANS payload is truncated"
      end
      digit = if bytes == 1
                payload.getbyte(position)
              else
                payload.byteslice(position, bytes).unpack1('v')
              end
      [digit, position + bytes]
    end

    def pack_frequencies(frequencies)
      frequencies.pack('v*')
    end

    def unpack_frequencies(data, _frequency_sum)
      data.unpack('v*')
    end

    def validate_layout(layout, state_count)
      case layout
      when LAYOUT_SINGLE
        unless state_count == 1
          raise ValidityError, "single-state rANS layout must have state_count 1"
        end
      when LAYOUT_INTERLEAVED
        unless state_count >= 2 && state_count <= 255
          raise ValidityError, "interleaved rANS layout must have 2 to 255 states"
        end
      else
        raise ValidityError, "unknown rANS layout #{layout}"
      end
    end

    def validate_quantization_rule(rule)
      unless [QUANTIZATION_PROVIDED, QUANTIZATION_LARGEST_REMAINDER].include?(rule)
        raise ValidityError, "unknown rANS quantization rule #{rule}"
      end
    end

    def layout_for(state_count)
      state_count == 1 ? LAYOUT_SINGLE : LAYOUT_INTERLEAVED
    end
  end
end
