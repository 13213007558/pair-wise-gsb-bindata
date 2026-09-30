require 'bindata/base'
require 'bindata/arithmetic_codec'

module BinData
  # An Arith is a container that stores a sequence of small integer
  # symbols (e.g. enum values) as an arithmetic coded bit stream.  The
  # symbols are compressed with cumulative frequency models supplied by
  # the caller; after reading, the field behaves like a normal array of
  # integer BinData fields.
  #
  #   require 'bindata'
  #
  #   class Packet < BinData::Record
  #     uint8 :kind
  #     # 3 data symbols plus the end marker, given as cumulative
  #     # frequencies: symbol 0 -> [0, 80), 1 -> [80, 95),
  #     # 2 -> [95, 100), end marker -> [100, 101).
  #     arith :tags, model: [0, 80, 95, 100, 101], initial_length: 4
  #   end
  #
  # The model may depend on fields already processed.  A callable
  # +:model+ is evaluated for every symbol position; the variables
  # +index+ (position of the symbol about to be coded), +element+ (the
  # previous integer symbol) and +array+ (the arith field itself) are
  # available, as are all fields of the enclosing record:
  #
  #   arith :tags, model: -> {
  #     kind == 0 ? [0, 90, 99, 100] : [0, 10, 99, 100]
  #   }
  #
  # Models must be causal: on encode and decode the callable is invoked
  # in the same order and may only observe symbols already processed.
  #
  # An adaptive model is maintained independently on each side with the
  # +:adaptive+ option:
  #
  #   arith :tags, adaptive: { num_symbols: 8 }
  #
  # The encoder and decoder each create their own model instance and
  # update it after every symbol in identical order; a mutable model is
  # never shared between the two sides.
  #
  # == Wire format
  #
  #   * 32 bit big endian symbol count +count+,
  #   * 32 bit big endian payload byte length +n+,
  #   * +n+ bytes of arithmetic coded payload (MSB first), coding the
  #     +count+ symbols followed by an end marker, padded with zero bits
  #     to the next byte boundary.
  #
  # The integer interval is 31 bits wide; see BinData::ArithmeticCodec
  # for the precision, frequency scaling, end marker and bit padding
  # rules.
  #
  # == Parameters
  #
  # <tt>:model</tt>::     The cumulative frequency model: an array of
  #                       non decreasing cumulative frequencies (the
  #                       last interval is the end marker), a
  #                       BinData::ArithmeticCodec::Model, or a
  #                       callable returning either of these for each
  #                       symbol.
  # <tt>:adaptive</tt>::  A hash of options for an internally managed
  #                       BinData::ArithmeticCodec::AdaptiveModel
  #                       (<tt>:num_symbols</tt> is required,
  #                       <tt>:initial_frequency</tt> and
  #                       <tt>:max_total</tt> optional).  Mutually
  #                       exclusive with <tt>:model</tt>.
  # <tt>:initial_length</tt>:: When present, exactly this many symbols
  #                       must be present; the count is verified on
  #                       read and write.
  # <tt>:type</tt>::      The integer BinData type of each symbol
  #                       (default <tt>:uint8</tt>).
  class Arith < BinData::Base
    include Enumerable

    # 32 bit symbol count + 32 bit payload length.
    HEADER_BYTES = 8

    arg_processor :arith

    # :model_provider is the sanitized internal form of :model.
    optional_parameters :model, :model_provider, :adaptive,
                        :initial_length, :type
    default_parameters type: :uint8

    def initialize_shared_instance
      @element_prototype = get_parameter(:type)
      super
    end

    def initialize_instance
      @elements = []
      @encoded_payload = nil
      @wire_payload_bytes = nil
    end

    def clear?
      elements.all?(&:clear?)
    end

    def assign(array)
      return if equal?(array)
      raise ArgumentError, "can't set a nil value for #{debug_name}" if array.nil?

      @elements = []
      @encoded_payload = nil
      @wire_payload_bytes = nil
      array.to_ary.each { |value| append_element(value) }
      self
    end

    def snapshot
      elements.collect(&:snapshot)
    end

    def length
      elements.length
    end
    alias size length

    def empty?
      elements.empty?
    end

    def each(&block)
      elements.each(&block)
    end

    def [](index)
      elements[index]&.snapshot
    end

    def at(index)
      elements[index]
    end

    def first(n = nil)
      n ? elements.first(n).collect(&:snapshot) : elements.first&.snapshot
    end

    def last(n = nil)
      n ? elements.last(n).collect(&:snapshot) : elements.last&.snapshot
    end

    def to_ary
      elements.collect(&:snapshot)
    end

    def find_index_of(obj)
      elements.index { |el| el.equal?(obj) }
    end

    def debug_name_of(child) # :nodoc:
      "#{debug_name}[#{find_index_of(child)}]"
    end

    def offset_of(child) # :nodoc:
      HEADER_BYTES
    end

    def do_num_bytes # :nodoc:
      # After a successful read, reuse the wire payload length instead
      # of re-encoding every symbol.
      HEADER_BYTES + (@wire_payload_bytes || encoded_payload.bytesize)
    end

    def do_write(io) # :nodoc:
      expected = eval_parameter(:initial_length)
      if expected && elements.length != expected
        raise ValidityError,
              "expected #{expected} symbols for #{debug_name}, " \
              "have #{elements.length}"
      end

      payload = encoded_payload
      io.writebytes([elements.length].pack('N'))
      io.writebytes([payload.bytesize].pack('N'))
      io.writebytes(payload)
    end

    def do_read(io) # :nodoc:
      framing = ArithFraming.new
      count = nil
      payload = nil
      io.transform(framing) do |_wrapper, xform|
        count, payload = xform.read_record
      end

      @elements = []
      @encoded_payload = nil
      @wire_payload_bytes = payload.bytesize

      begin
        decode_payload(payload, count) { |symbol| append_element(symbol) }
      rescue StandardError
        # leave no partially decoded values behind on failure
        @elements = []
        raise
      end

      expected = eval_parameter(:initial_length)
      if expected && elements.length != expected
        raise ValidityError,
              "expected #{expected} symbols for #{debug_name}, " \
              "got #{elements.length}"
      end
    end

    #---------------
    private

    def elements
      @elements
    end

    def append_element(value)
      element = @element_prototype.instantiate(nil, self)
      element.assign(value)
      @elements << element
      element
    end

    def raw_symbol(element, index)
      value = element.snapshot
      unless value.respond_to?(:to_int)
        raise ArithmeticCodec::InvalidModelError,
              "symbol at index #{index} of #{debug_name} must be an " \
              "integer, got #{value.inspect}"
      end
      value.to_int
    end

    # Builds the coded payload for the currently assigned elements.
    # All model and symbol validation happens here, before any byte of
    # this field is written to the underlying stream.
    def encoded_payload
      @encoded_payload ||= begin
        session = ModelSession.new(self)
        symbols = []

        encoder = ArithmeticCodec::Encoder.new
        elements.each_with_index do |element, index|
          symbol = raw_symbol(element, index)
          encoder.encode(symbol,
                         session.cumulative_for(index, symbols, self))
          session.symbol_processed(symbol)
          symbols << symbol
        end

        final_cum = session.final_cumulative
        encoder.finish(session.end_symbol, final_cum,
                       symbols.length)
      end
    end

    def decode_payload(payload, count)
      session = ModelSession.new(self)
      decoder = ArithmeticCodec::Decoder.new(payload, count)
      symbols = []

      count.times do |index|
        symbol = decoder.decode(session.cumulative_for(index, symbols, self))
        if symbol == session.end_symbol
          raise IOError,
                "arithmetic stream ended after #{symbols.length} symbols " \
                "but header declared #{count}"
        end
        session.symbol_processed(symbol)
        symbols << symbol
        # Instantiate immediately so a causal model lambda can observe
        # already decoded symbols via the enclosing record, exactly as
        # the encoder does.
        yield symbol if block_given?
      end

      # Force model resolution for the marker (also initialises the
      # end symbol for an empty sequence with a callable model).
      final_cum = session.final_cumulative
      decoder.finish(session.end_symbol, final_cum)

      symbols
    end

    # Supplies the cumulative frequency table for every symbol position
    # and owns the per side adaptive model state.  A new session is
    # created independently for reading and writing, so mutable models
    # are never shared between the two endpoints.
    class ModelSession
      def initialize(field)
        @field = field

        if field.get_parameter(:adaptive)
          opts = field.get_parameter(:adaptive)
          kwargs = {}
          kwargs[:initial_frequency] = opts[:initial_frequency] if
            opts.key?(:initial_frequency)
          kwargs[:max_total] = opts[:max_total] if
            opts.key?(:max_total)
          @adaptive =
            ArithmeticCodec::AdaptiveModel.new(opts[:num_symbols], **kwargs)
        else
          @adaptive = nil
          @provider = field.get_parameter(:model_provider)
        end

        @processed = []
        @end_symbol = @adaptive ? @adaptive.end_symbol : nil
        @final_cumulative = @adaptive ? @adaptive.cumulative : nil
      end

      attr_reader :end_symbol

      def cumulative_for(index, processed, field)
        if @adaptive
          @final_cumulative = @adaptive.cumulative
          return @final_cumulative
        end

        model = resolve_provider(index, processed, field)
        cum = normalize(model)
        end_sym = cum.length - 2

        if @end_symbol.nil?
          @end_symbol = end_sym
        elsif end_sym != @end_symbol
          raise ArithmeticCodec::InvalidModelError,
                "end marker index changed from #{@end_symbol} to " \
                "#{end_sym} at symbol position #{index} in " \
                "#{@field.debug_name}"
        end

        @final_cumulative = cum
        cum
      end

      def final_cumulative
        # For an adaptive model the marker is coded with the model as it
        # stands after the final data symbol update, so always re-read.
        return @adaptive.cumulative if @adaptive
        # Empty sequence: the model for position 0 is still needed to
        # code / verify the end marker.
        @final_cumulative || cumulative_for(0, @processed, @field)
      end

      def symbol_processed(symbol)
        @adaptive&.update_symbol(symbol)
        @processed << symbol
      end

      private

      def resolve_provider(index, processed, field)
        provider = @provider
        if provider.is_a?(Symbol) || provider.respond_to?(:arity)
          overrides = {
            index: index,
            element: processed.last,
            array: field
          }
          field.lazy_evaluator.lazy_eval(provider, overrides)
        else
          provider
        end
      end

      def normalize(model)
        case model
        when ArithmeticCodec::Model
          @end_symbol = model.end_symbol
          model.cumulative
        when nil
          raise ArithmeticCodec::InvalidModelError,
                "model provider returned nil for #{@field.debug_name}"
        else
          unless model.respond_to?(:map)
            raise ArithmeticCodec::InvalidModelError,
                  "model must be a cumulative frequency array or a " \
                  "BinData::ArithmeticCodec::Model, got #{model.class}"
          end
          model.map do |f|
            unless f.respond_to?(:to_int)
              raise ArithmeticCodec::InvalidModelError,
                    "cumulative frequency must be an integer, " \
                    "got #{f.inspect}"
            end
            f.to_int
          end
        end
      end
    end

    # Read transform that consumes the fixed size header and then the
    # declared number of payload bytes.  It performs repeated reads
    # until every requested byte has arrived, so decoding is
    # independent of how the underlying IO chunks its bytes.  The
    # transform does not change the stream length: it consumes exactly
    # the bytes that make up this field.
    class ArithFraming < IO::Transform
      def before_transform
        @count, @length = read_fully(8).unpack('NN')
      end

      # Returns [symbol_count, payload_string].
      def read_record
        [@count, read_fully(@length)]
      end

      private

      def read_fully(n)
        result = ::String.new.force_encoding(Encoding::BINARY)
        remaining = n
        while remaining.positive?
          chunk = chain_read(remaining)
          if chunk.nil? || chunk.empty?
            raise EOFError, "truncated arithmetic coded record"
          end
          result << chunk
          remaining -= chunk.bytesize
        end
        result
      end
    end

    private_constant :ModelSession, :ArithFraming
  end

  class ArithArgProcessor < BaseArgProcessor
    def sanitize_parameters!(obj_class, params)
      params.warn_replacement_parameter(:cumulative, :model)

      adaptive = params[:adaptive]
      has_model = params.key?(:model) || params.key?(:cumulative)

      if adaptive
        if has_model
          raise ArgumentError,
                ":model and :adaptive are mutually exclusive in #{obj_class}"
        end
        sanitize_adaptive(adaptive)
      else
        unless has_model
          raise ArgumentError,
                  "parameter ':model' must be specified in #{obj_class}"
        end
        params[:model] = params.delete(:cumulative) if
          params.key?(:cumulative)
        provider = params[:model]
        validate_static_model(provider) unless callable?(provider)
        params[:model_provider] = params.delete(:model)
      end

      params.must_be_integer(:initial_length)
      params.sanitize_object_prototype(:type)
    end

    private

    def callable?(obj)
      obj.is_a?(Symbol) || obj.respond_to?(:arity)
    end

    def sanitize_adaptive(adaptive)
      unless adaptive.is_a?(Hash)
        raise ArgumentError, ":adaptive must be a hash of options"
      end
      num = adaptive[:num_symbols]
      if num.nil? || !num.respond_to?(:to_int) || num.to_int <= 0
        raise ArgumentError,
              ":adaptive :num_symbols must be a positive integer"
      end
      %i[initial_frequency max_total].each do |key|
        if adaptive.key?(key) && !adaptive[key].respond_to?(:to_int)
          raise ArgumentError,
                ":adaptive :#{key} must be an integer"
        end
      end
    end

    # Validates a static (non callable) model eagerly, so errors are
    # reported while the field is constructed rather than on first use.
    def validate_static_model(model)
      return if model.is_a?(ArithmeticCodec::Model)

      unless model.respond_to?(:map)
        raise ArgumentError,
              ":model must be a cumulative frequency array, a " \
              "BinData::ArithmeticCodec::Model or a callable, " \
              "got #{model.class}"
      end

      table = model.map do |f|
        unless f.respond_to?(:to_int)
          raise ArithmeticCodec::InvalidModelError,
                "cumulative frequency must be an integer, got #{f.inspect}"
        end
        f.to_int
      end

      # Validate the implied per symbol frequencies (the last one is
      # the end marker and must be positive).
      freqs = (1...table.length).map { |i| table[i] - table[i - 1] }
      ArithmeticCodec::Model.new(freqs)
    end
  end
end
