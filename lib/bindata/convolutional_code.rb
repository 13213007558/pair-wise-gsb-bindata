require 'bindata/base_primitive'

module BinData
  # A rate 1/n convolutional code as used for telemetry channels
  # (e.g. CCSDS 101/131 style codes).
  #
  # BinData::ConvolutionalCodec is a standalone encoder and soft decision
  # Viterbi decoder.  It supports zero-tail termination and tail-biting, an
  # arbitrary puncturing pattern, and observations that may be erased (nil)
  # or carry a per-bit reliability.
  #
  # BinData::ConvolutionalCode is a BinData field that stores the coded bit
  # stream and presents the decoded information bytes as its value.
  #
  # == Trellis convention
  #
  # The encoder state is the +K-1+ most recently shifted information bits,
  # encoded as an integer.  When information bit +u+ is shifted in then
  #
  #   next_state = ((state << 1) | u) & ((1 << (K - 1)) - 1)
  #
  # Generator polynomials are integers whose +K+ bits give the taps.  The
  # MSB (bit +K-1+) is the tap for the current information bit, so the
  # standard CCSDS K=7 code uses generators 0o171 and 0o133.
  #
  # == Observations
  #
  # Each coded symbol observation is one of:
  #
  # * +nil+ (or +false+) -- an erased or missing observation.  It carries
  #   no information at all and is never treated as a definite 0.
  # * +true+ / +1+ / +0+ -- a hard bit, fully reliable.
  # * a signed number -- a soft observation.  Positive values vote for 1,
  #   negative values vote for 0 and the magnitude is the reliability.
  # * +[bit, reliability]+ -- a (possibly unreliable) hard bit; reliability
  #   of 0 is an erasure.
  # * +{bit:, reliability:}+ -- same thing, as keywords.
  #
  # Strings are unpacked as big-endian hard bits.
  class ConvolutionalCodec
    # Outcome of a decode operation.
    #
    # +bytes+:: decoded information as a binary String (nil when the number
    #           of information bits is not a multiple of 8).
    # +bits+:: decoded information bits.
    # +path_metric+:: best path metric (larger is more likely).
    # +start_state+:: trellis state assumed at the start of the block.
    # +end_state+::   trellis state reached at the end of the block.
    Result = ::Struct.new(:bytes, :bits, :path_metric, :start_state,
                        :end_state, keyword_init: true)

    DEFAULT_GENERATORS = [0o171, 0o133].freeze
    NEG_INF = -(::Float::INFINITY)

    # Creates a codec.
    #
    # +constraint_length+:: encoder memory + 1 (K).  Defaults to 7.
    # +generators+:: array of generator polynomials.  Defaults to the
    #                 CCSDS polynomials 0o171 / 0o133.
    # +puncture+:: optional periodic keep/discard mask applied to the
    #               serial coded symbol stream.  Truthy entries keep a
    #               symbol, falsey entries puncture it.  The pattern is
    #               periodic and its phase is continuous, even across
    #               byte (field block) boundaries.
    # +termination+:: +:zero_tail+ (default) or +:tail_biting+.
    # +tailbiting_laps+:: number of trellis laps used by the circular
    #                      Viterbi decoder for long tail-biting blocks.
    # +exact_symbols+:: blocks with at most this many coded symbols are
    #                    tail-biting decoded by enumerating every starting
    #                    state (exact maximum likelihood).
    def initialize(constraint_length: 7,
                   generators: DEFAULT_GENERATORS,
                   puncture: nil,
                   termination: :zero_tail,
                   tailbiting_laps: 4,
                   exact_symbols: 512)
      @constraint_length = validate_constraint_length(constraint_length)
      @memory = @constraint_length - 1
      @states = 1 << @memory
      @state_mask = @states - 1
      @generators = validate_generators(generators)
      @rate = @generators.length
      @puncture = validate_puncture(puncture)
      @termination = validate_termination(termination)
      @laps = validate_laps(tailbiting_laps)
      @exact_symbols = exact_symbols

      @parity = build_parity_table
      build_trellis
    end

    attr_reader :constraint_length, :generators, :puncture, :termination

    # Number of encoder shifts for +information_nbits+ information bits.
    def encoder_input_nbits(information_nbits)
      if @termination == :zero_tail
        information_nbits + @memory
      else
        information_nbits
      end
    end

    # Number of transmitted (kept) symbols for +information_nbits+ bits.
    def coded_nbits(information_nbits)
      punctured_nbits(encoder_input_nbits(information_nbits) * @rate)
    end

    # Encodes +data+ (a String of bytes or an array of bits) into an array
    # of coded bits.
    def encode(data)
      info = coerce_information_bits(data)
      stream = encode_unpunctured(info)
      apply_puncture(stream)
    end

    # Decodes the received +observations+ (see the class notes for accepted
    # formats).  +information_nbits+ is the number of information bits in
    # the block, excluding zero-tail flush bits.  Returns a Result.
    def decode(observations, information_nbits)
      unless information_nbits.is_a?(::Integer) && information_nbits >= 0
        raise ArgumentError, "information_nbits must be a non-negative integer"
      end

      expected = coded_nbits(information_nbits)
      kept = normalize_observations(observations, expected)
      symbols = expand_observations(kept, information_nbits)

      if @termination == :zero_tail
        decode_zero_tail(symbols, information_nbits)
      elsif symbols.length <= @exact_symbols
        decode_tail_biting_exact(symbols, information_nbits)
      else
        decode_tail_biting_circular(symbols, information_nbits)
      end
    end

    #---------------
    private

    def validate_constraint_length(k)
      unless k.is_a?(::Integer) && (2..15).include?(k)
        raise ArgumentError, "constraint_length must be an integer in 2..15"
      end
      k
    end

    def validate_generators(generators)
      unless generators.is_a?(::Array) && !generators.empty? &&
             generators.all? { |g| g.is_a?(::Integer) && g > 0 }
        raise ArgumentError, "generators must be a non-empty array of integers"
      end

      limit = 1 << @constraint_length
      generators.each do |g|
        unless g < limit
          raise ArgumentError,
                "generator 0o#{g.to_s(8)} does not fit in " \
                "#{@constraint_length} bits"
        end
      end

      generators.dup.freeze
    end

    def validate_puncture(puncture)
      return [true].freeze if puncture.nil?

      mask = puncture.map { |p| !p.nil? && p != false && p != 0 }
      if mask.none?
        raise ArgumentError, "puncture pattern must keep at least one symbol"
      end
      mask.freeze
    end

    def validate_termination(termination)
      unless %i[zero_tail tail_biting].include?(termination)
        raise ArgumentError,
              "termination must be :zero_tail or :tail_biting"
      end
      termination
    end

    def validate_laps(laps)
      unless laps.is_a?(::Integer) && laps >= 1
        raise ArgumentError, "tailbiting_laps must be a positive integer"
      end
      laps
    end

    def build_parity_table
      table = ::Array.new(1 << @constraint_length, 0)
      (1...table.length).each do |n|
        table[n] = table[n >> 1] ^ (n & 1)
      end
      table
    end

    def build_trellis
      output = ::Array.new(@states) { ::Array.new(2) }
      nxt = ::Array.new(@states) { ::Array.new(2) }
      predecessors = ::Array.new(@states) { [] }

      @states.times do |state|
        2.times do |input|
          register_bits = (state << 1) | input
          output[state][input] = @generators.map do |g|
            @parity[g & register_bits]
          end
          nxt[state][input] = register_bits & @state_mask
          predecessors[nxt[state][input]] << [state, input]
        end
      end

      @branch_output = output
      @branch_next_state = nxt
      @predecessors = predecessors
    end

    def punctured_nbits(raw_nbits)
      period = @puncture.length
      cycles, remainder = raw_nbits.divmod(period)
      cycles * @puncture.count(true) + @puncture.first(remainder).count(true)
    end

    def apply_puncture(stream)
      period = @puncture.length
      stream.each_index.select { |idx| @puncture[idx % period] }
            .map { |idx| stream[idx] }
    end

    def coerce_information_bits(data)
      bits =
        case data
        when ::String then bytes_to_bits(data.b)
        when ::Array then data
        else
          raise ArgumentError, "data must be a String or an Array of bits"
        end

      unless bits.all? { |b| b == 0 || b == 1 }
        raise ArgumentError, "information bits must be 0 or 1"
      end
      bits
    end

    def bytes_to_bits(str)
      str.bytes.flat_map do |byte|
        7.downto(0).map { |i| (byte >> i) & 1 }
      end
    end

    def bits_to_bytes(bits)
      return nil unless (bits.length % 8).zero?
      bits.each_slice(8).map do |octet|
        octet.reduce(0) { |byte, bit| (byte << 1) | bit }
      end.pack('C*')
    end

    def encode_unpunctured(info)
      bits = info.dup
      state = 0

      if @termination == :tail_biting
        unless bits.length >= @memory
          raise ArgumentError,
                "tail-biting blocks need at least #{@memory} information bits"
        end
        state = bits.last(@memory).each_with_index.reduce(0) do |s, (b, i)|
          s | (b << (@memory - 1 - i))
        end
      else
        bits.concat([0] * @memory)
      end

      bits.flat_map do |bit|
        coded = @branch_output[state][bit]
        state = @branch_next_state[state][bit]
        coded
      end
    end

    def normalize_observations(observations, expected)
      list =
        case observations
        when ::String then bytes_to_bits(observations.b)
        when ::Array then observations
        else
          raise ArgumentError, "observations must be an Array or a String"
        end

      if list.length != expected
        raise ArgumentError,
              "expected #{expected} observations, got #{list.length}"
      end

      list.map { |obs| normalize_observation(obs) }
    end

    def normalize_observation(obs)
      case obs
      when nil, false then nil
      when true then 1.0
      when ::Integer
        case obs
        when 0 then -1.0
        when 1 then 1.0
        else obs.to_f
        end
      when ::Numeric then obs.to_f
      when ::Hash then weighted_observation(obs[:bit] || obs['bit'],
                                          obs[:reliability] || obs['reliability'])
      when ::Array then weighted_observation(obs[0], obs[1])
      else
        raise ArgumentError, "unsupported observation #{obs.inspect}"
      end
    end

    def weighted_observation(bit, reliability)
      weight = reliability.to_f.abs
      return nil if weight.zero?
      bit.to_i == 1 ? weight : -weight
    end

    # Place the kept observations back onto the full coded symbol timeline.
    # Punctured positions are erased (nil), never zero.
    def expand_observations(kept, information_nbits)
      raw_nbits = encoder_input_nbits(information_nbits) * @rate
      period = @puncture.length
      symbols = ::Array.new(raw_nbits, nil)
      idx = 0
      raw_nbits.times do |pos|
        next unless @puncture[pos % period]
        symbols[pos] = kept[idx]
        idx += 1
      end
      symbols
    end

    def branch_increment(state, input, symbols, time)
      base = time * @rate
      @branch_output[state][input].each_with_index.sum do |coded, j|
        weight = symbols[base + j]
        next 0.0 if weight.nil?
        coded == 1 ? weight : -weight
      end
    end

    # One add-compare-select sweep over the whole block.
    #
    # The survivor for each state only records its predecessor; the input
    # bit on that branch is the low bit of the destination state, since
    # state = ((prev_state << 1) | input) & state_mask.
    #
    # Returns [metrics, history].  When +record+ is true, history contains
    # the predecessor table for every step, otherwise it is nil.
    def viterbi_sweep(symbols, initial_metrics, record)
      metrics = initial_metrics
      steps = symbols.length / @rate
      history = [] if record

      steps.times do |time|
        new_metrics = ::Array.new(@states, NEG_INF)
        predecessors_at_time = ::Array.new(@states) if record

        @states.times do |state|
          best = NEG_INF
          best_prev = nil
          @predecessors[state].each do |prev_state, input|
            prev_metric = metrics[prev_state]
            next if prev_metric == NEG_INF
            candidate = prev_metric +
                        branch_increment(prev_state, input, symbols, time)
            if candidate > best
              best = candidate
              best_prev = prev_state
            end
          end
          new_metrics[state] = best
          predecessors_at_time[state] = best_prev if record
        end

        history << predecessors_at_time if record
        metrics = new_metrics
      end

      [metrics, history]
    end

    def traceback(history, final_state, length)
      state = final_state
      bits = ::Array.new(length)
      (length - 1).downto(0) do |time|
        # next_state = ((prev_state << 1) | input) & mask, so the input bit
        # is the low bit of the destination state.
        bits[time] = state & 1
        state = history[time][state]
      end
      [bits, state]
    end

    def build_result(bits, path_metric, start_state, end_state)
      Result.new(
        bytes: bits_to_bytes(bits),
        bits: bits,
        path_metric: path_metric,
        start_state: start_state,
        end_state: end_state
      )
    end

    def decode_zero_tail(symbols, information_nbits)
      initial = ::Array.new(@states, NEG_INF)
      initial[0] = 0.0
      metrics, history = viterbi_sweep(symbols, initial, true)
      steps = symbols.length / @rate
      bits, = traceback(history, 0, steps)
      build_result(bits.first(information_nbits), metrics[0], 0, 0)
    end

    # Exact maximum likelihood tail-biting decoding: run the Viterbi
    # algorithm once per possible starting state and keep the best path that
    # returns to its starting state.
    def decode_tail_biting_exact(symbols, information_nbits)
      steps = symbols.length / @rate
      best_metric = NEG_INF
      best_start = 0
      best_history = nil

      @states.times do |start_state|
        initial = ::Array.new(@states, NEG_INF)
        initial[start_state] = 0.0
        metrics, history = viterbi_sweep(symbols, initial, true)
        next if metrics[start_state] <= best_metric
        best_metric = metrics[start_state]
        best_start = start_state
        best_history = history
      end

      bits, traced_start = traceback(best_history, best_start, steps)
      build_result(bits.first(information_nbits), best_metric,
                   traced_start, best_start)
    end

    # Circular Viterbi: wrap the trellis around several times so the path
    # metrics converge, record the final lap, then trace back one block.
    def decode_tail_biting_circular(symbols, information_nbits)
      steps = symbols.length / @rate
      metrics = ::Array.new(@states, 0.0)
      offset = 0.0
      history = nil

      @laps.times do |lap|
        baseline = metrics.max
        offset += baseline
        metrics = metrics.map { |m| m - baseline }
        record = lap == @laps - 1
        metrics, history = viterbi_sweep(symbols, metrics, record)
      end

      best_metric = metrics[0]
      end_state = 0
      (1...@states).each do |state|
        if metrics[state] > best_metric
          best_metric = metrics[state]
          end_state = state
        end
      end

      bits, start_state = traceback(history, end_state, steps)
      build_result(bits.first(information_nbits), best_metric + offset,
                   start_state, end_state)
    end
  end

  # A BinData field holding a convolutional-coded telemetry block.
  #
  # The on-wire representation is the punctured coded bit stream, packed
  # big-endian (MSB first).  The value presented to Ruby is the decoded
  # information bytes.
  #
  #   class Frame < BinData::Record
  #     convolutional_code :payload, length: 16
  #   end
  #
  # After reading, decoder side information is available:
  #
  #   frame.payload              #=> decoded String
  #   frame.payload.path_metric  #=> Viterbi path metric
  #   frame.payload.start_state  #=> trellis state at the start
  #   frame.payload.end_state    #=> trellis state at the end
  #
  # == Parameters
  #
  # <tt>:length</tt>:: number of information bytes in the block (mandatory).
  # <tt>:constraint_length</tt>, <tt>:generators</tt>, <tt>:puncture</tt>,
  # <tt>:termination</tt>, <tt>:tailbiting_laps</tt>, <tt>:exact_symbols</tt>::
  #   forwarded to ConvolutionalCodec.
  # <tt>:observations</tt>:: an optional proc evaluated against the parent
  #   record.  It returns the received observations (hard bits, soft values
  #   or +nil+ erasures) used for decoding instead of reading hard bits from
  #   the stream.  The coded bits are still consumed from the IO stream.
  class ConvolutionalCode < BasePrimitive
    mandatory_parameters :length
    optional_parameters :constraint_length, :generators, :puncture,
                         :termination, :tailbiting_laps, :exact_symbols,
                         :observations

    def bit_aligned?
      true
    end

    # Path metric of the most recent decode.  Larger is more likely.
    attr_reader :path_metric

    # Trellis states assumed / reached by the most recent decode.
    attr_reader :start_state, :end_state

    def assign(val)
      super(binary_string(val))
    end

    def initialize_instance
      super
      @path_metric = nil
      @start_state = nil
      @end_state = nil
      validate_static_parameters!
    end

    def validate_static_parameters!
      length = get_parameter(:length)
      if static_value?(length) && !(length.is_a?(::Integer) && length.positive?)
        raise ArgumentError,
              "length must be a positive integer in #{debug_name}"
      end

      termination = get_parameter(:termination)
      if static_value?(termination) &&
         !%i[zero_tail tail_biting].include?(termination)
        raise ArgumentError,
              "termination must be :zero_tail or :tail_biting in #{debug_name}"
      end
    end

    def static_value?(value)
      !value.nil? && !value.is_a?(::Symbol) && !value.respond_to?(:arity)
    end

    def do_write(io)
      bits = codec.encode(_value)
      bits.each { |bit| io.writebits(bit, 1, :big) }
    end

    def do_num_bytes
      codec.coded_nbits(information_nbits) / 8.0
    end

    #---------------
    private

    def information_nbits
      length = eval_parameter(:length)
      length = length.to_i if length.respond_to?(:to_i) &&
                              !length.is_a?(::Integer)
      unless length.is_a?(::Integer) && length.positive?
        raise ArgumentError,
              "length must be a positive integer in #{debug_name}"
      end
      length * 8
    end

    def codec
      options = {}
      %i[constraint_length generators puncture termination
         tailbiting_laps exact_symbols].each do |key|
        value = get_parameter(key)
        options[key] = value unless value.nil?
      end
      ConvolutionalCodec.new(**options)
    end

    def read_and_return_value(io)
      coder = codec
      nbits = coder.coded_nbits(information_nbits)
      hard_bits = ::Array.new(nbits) { io.readbits(1, :big) }
      observations =
        if has_parameter?(:observations)
          eval_parameter(:observations)
        else
          hard_bits
        end

      result = coder.decode(observations, information_nbits)
      @path_metric = result.path_metric
      @start_state = result.start_state
      @end_state = result.end_state
      result.bytes
    end

    def sensible_default
      binary_string("\0" * eval_parameter(:length))
    end
  end
end
