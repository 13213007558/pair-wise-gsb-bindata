require 'bindata/arithmetic_codec'
require 'bindata/base'
require 'bindata/dsl'

module BinData
  # An Arithmetic is a container that stores a list of symbols compressed
  # with an integer arithmetic coder.
  #
  # On the wire the container is a self delimiting bit stream (big endian,
  # byte padded with zero bits) terminated by a reserved end of stream
  # symbol.  In memory the contained type behaves like any other BinData
  # object; reading returns normal field values.
  #
  #   require 'bindata'
  #
  #   # a model factory: a fresh, independent model for every read/write
  #   model = -> { BinData::ArithmeticCodec::Model.new([0, 1, 2, 3]) }
  #
  #   class Packet < BinData::Record
  #     endian :big
  #     uint16 :header
  #     arithmetic :payload, model: model do
  #       array initial_length: 8, type: :uint8
  #     end
  #   end
  #
  #   pkt = Packet.read(Packet.new(header: 0,
  #                               payload: [0, 1, 1, 3, 1, 1, 0, 2]).to_binary_s)
  #   pkt.payload #=> [0, 1, 1, 3, 1, 1, 0, 2]
  #
  # The model may be chosen from fields that have already been processed:
  #
  #   arithmetic :payload, model: -> { Models.for(header) } do
  #     array initial_length: 16, type: :uint8
  #   end
  #
  # The factory is called separately for reading and writing, so encoder
  # and decoder never share a mutable model instance.  If the model responds
  # to +#update+, it is called with each symbol immediately after that
  # symbol is coded; encoder and decoder perform the updates in identical
  # order, which is what makes adaptive models safe.
  #
  # A model is any object responding to +#cumulative_frequencies+ (returning
  # a flat +[sym, low, high, ...]+ array of contiguous cumulative bounds),
  # optionally +#update(symbol)+ and +#end_symbol+.
  # BinData::ArithmeticCodec::Model is a ready made adaptive model.
  #
  # == Parameters
  #
  # <tt>:model</tt>::   Mandatory. A callable returning a new model object.
  #                     Evaluated in the context of the surrounding record,
  #                     so it may depend on previously processed fields.
  # <tt>:length</tt>::  The number of compressed bytes occupied by this
  #                     container on the wire (may be a lambda).  When
  #                     omitted the container consumes the remainder of the
  #                     current stream.  A write that does not exactly fill
  #                     a fixed length is zero padded, or raises if it
  #                     overflows.
  # <tt>:type</tt>::    The single type inside the container.  It must
  #                     +assign+ and +snapshot+ an Array of symbols (an
  #                     +array+ of any integer field is the common case).
  class Arithmetic < BinData::Base
    extend DSLMixin

    dsl_parser    :arithmetic
    arg_processor :arithmetic

    mandatory_parameter :model
    optional_parameters :length

    def initialize_shared_instance
      @type_prototype = get_parameter(:type)
      super
    end

    def initialize_instance
      @type = @type_prototype.instantiate(nil, self)
    end

    def clear?
      @type.clear?
    end

    def assign(val)
      @type.assign(val)
    end

    def snapshot
      @type.snapshot
    end

    def respond_to_missing?(symbol, include_all = false) # :nodoc:
      @type.respond_to?(symbol, include_all) || super
    end

    def method_missing(...) # :nodoc:
      @type.__send__(...)
    end

    def do_read(io) # :nodoc:
      compressed = read_compressed_bytes(io)
      symbols = ArithmeticCodec.decode(new_model, compressed)
      @type.assign(symbols)
    end

    def do_write(io) # :nodoc:
      symbols = @type.snapshot
      unless symbols.is_a?(::Array)
        raise ArgumentError,
              "arithmetic container can only code an Array of symbols, " \
              "got #{symbols.class}"
      end

      # Encode completely before touching the stream so that an illegal
      # frequency table raises before this record's bytes are written.
      encoded = ArithmeticCodec.encode(new_model, symbols)
      encoded = pad_to_fixed_length(encoded)
      io.writebytes(encoded)
    end

    def do_num_bytes # :nodoc:
      symbols = @type.snapshot
      return 0 unless symbols.is_a?(::Array)

      # Always report the actual encoded size (never the declared :length)
      # so length prefix fields of the form
      #   uint8 :n, value: -> { payload.num_bytes }
      # do not evaluate back into themselves.  This also fails early on a
      # bad frequency table.
      ArithmeticCodec.encode(new_model, symbols).bytesize
    end

    #---------------
    private

    def new_model
      # :model is a factory evaluated in the surrounding record's context
      # (BinData's lazy parameter handling invokes the lambda).  It is
      # evaluated afresh for every read/write, so encoder and decoder and
      # every array element get their own independent model instance.
      model = eval_parameter(:model)
      unless model.respond_to?(:cumulative_frequencies)
        raise ArgumentError,
              ":model must evaluate to a model object that responds to " \
              "#cumulative_frequencies, got #{model.inspect}"
      end
      model
    end

    def read_compressed_bytes(io)
      if has_parameter?(:length)
        # byte by byte so the result is identical no matter how the
        # underlying IO chunks its #read calls
        bytes = ::String.new.force_encoding(Encoding::BINARY)
        eval_parameter(:length).times { bytes << io.readbytes(1) }
        bytes
      else
        bytes = ::String.new.force_encoding(Encoding::BINARY)
        loop do
          bytes << io.readbytes(1)
        rescue EOFError, IOError
          break
        end
        bytes
      end
    end

    def pad_to_fixed_length(encoded)
      return encoded unless has_parameter?(:length)

      length = eval_parameter(:length)
      if encoded.bytesize > length
        raise IOError,
              "arithmetic stream of #{encoded.bytesize} bytes does not fit " \
              "in declared length #{length}"
      end
      encoded << ("\x00".b * (length - encoded.bytesize))
    end
  end

  class ArithmeticArgProcessor < BaseArgProcessor
    include MultiFieldArgSeparator

    def sanitize_parameters!(obj_class, params)
      params.merge_dsl_params
      params.must_be_integer(:length)

      model = params[:model]
      unless model.respond_to?(:call) || model.is_a?(::Symbol)
        raise ArgumentError,
              ":model for #{obj_class} must be a callable factory (e.g. a " \
              "lambda) returning a fresh model, never a shared model instance"
      end

      params.sanitize_object_prototype(:type)
    end
  end
end
