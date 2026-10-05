require 'bindata/base'
require 'bindata/dsl'
require 'bindata/transform/hdlc'

module BinData
  # A Section is a layer on top of a stream that transforms the underlying
  # data.  This allows BinData to process a stream that has multiple
  # encodings.  e.g.  Some data data is compressed or encrypted.
  #
  #   require 'bindata'
  #
  #   class XorTransform < BinData::IO::Transform
  #      def initialize(xor)
  #        super()
  #        @xor = xor
  #      end
  #
  #      def read(n)
  #        chain_read(n).bytes.map { |byte| (byte ^ @xor).chr }.join
  #      end
  #
  #      def write(data)
  #        chain_write(data.bytes.map { |byte| (byte ^ @xor).chr }.join)
  #      end
  #   end
  #
  #   obj = BinData::Section.new(transform: -> { XorTransform.new(0xff) },
  #                              type: [:string, read_length: 5])
  #
  #   obj.read("\x97\x9A\x93\x93\x90") #=> "hello"
  #
  #
  # == Parameters
  #
  # Parameters may be provided at initialisation to control the behaviour of
  # an object.  These params are:
  #
  # <tt>:transform</tt>:: A callable that returns a new BinData::IO::Transform.
  # <tt>:framing</tt>:: Set to +:hdlc+ to use the built-in HDLC framer.
  # <tt>:bit_order</tt>:: For HDLC, either +:little+ (LSB first) or +:big+
  #                       (MSB first).
  # <tt>:frame_check</tt>:: +:crc16+ (default), or +:none+.
  # <tt>:max_frame_bytes</tt>:: Maximum number of decoded frame bytes.
  # <tt>:on_frame_error</tt>:: Optional callable receiving a FrameError.  When
  #                            present, reading resumes after the error.
  # <tt>:type</tt>::      The single type inside the buffer.  Use a struct if
  #                       multiple fields are required.
  class Section < BinData::Base
    extend DSLMixin

    dsl_parser    :section
    arg_processor :section

    mandatory_parameters :type
    optional_parameters :transform, :framing, :bit_order, :frame_check,
                         :max_frame_bytes, :on_frame_error
    mutually_exclusive_parameters :transform, :framing

    def initialize_instance
      @type = get_parameter(:type).instantiate(nil, self)
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
      io.transform(build_transform) do |transformed_io, _raw_io|
        @type.do_read(transformed_io)
      end
    end

    def do_write(io) # :nodoc:
      io.transform(build_transform) do |transformed_io, _raw_io|
        @type.do_write(transformed_io)
      end
    end

    def do_num_bytes # :nodoc:
      to_binary_s.size
    end

    private

    def build_transform
      return eval_parameter(:transform) unless get_parameter(:framing)

      framing = get_parameter(:framing)
      unless framing == :hdlc
        raise ArgumentError, "unsupported framing #{framing.inspect}"
      end

      options = { bit_order: get_parameter(:bit_order) }
      if has_parameter?(:frame_check)
        options[:frame_check] = get_parameter(:frame_check)
      end
      if has_parameter?(:max_frame_bytes)
        options[:max_frame_bytes] = get_parameter(:max_frame_bytes)
      end
      if has_parameter?(:on_frame_error)
        options[:on_frame_error] = get_parameter(:on_frame_error)
      end
      BinData::Transform::HDLC.new(**options)
    end
  end

  class SectionArgProcessor < BaseArgProcessor
    include MultiFieldArgSeparator

    def sanitize_parameters!(obj_class, params)
      params.merge_dsl_params
      params.must_have_at_least_one_of(:transform, :framing)
      if params[:framing]
        unless params[:framing] == :hdlc
          raise ArgumentError, "unsupported framing #{params[:framing].inspect}"
        end
        unless params.has_parameter?(:bit_order)
          raise ArgumentError, "HDLC framing requires bit_order"
        end
      end
      if params.has_parameter?(:on_frame_error) &&
         !params[:on_frame_error].respond_to?(:call)
        raise ArgumentError, "on_frame_error must respond to \#call"
      end
      params.must_be_integer(:max_frame_bytes) if params[:max_frame_bytes]
      params.sanitize_object_prototype(:type)
    end
  end
end
