require 'bindata/base'
require 'bindata/dsl'

module BinData
  # A pointer field stores an offset to another object.  Offsets may be
  # absolute, or relative to the start of the containing structure.
  class Pointer < BinData::Base
    extend DSLMixin

    dsl_parser    :pointer
    arg_processor :pointer

    mandatory_parameter :type
    optional_parameters :endian, :offset_base, :relative,
                         :target_align, :align, :alignment, :byte_align,
                         :target_byte_align, :target_type,
                         :offset_type, :offset_size, :offset_width,
                         :null_value
    default_parameters offset_base: :absolute,
                        target_align: 1,
                        null_value: -1

    def initialize_instance
      @target = nil
      @target_loaded = false
      @raw_offset = nil
      @write_offset = nil
      @read_io = nil
      @offset_type = get_parameter(:offset_type).instantiate(nil, self)
    end

    def clear?
      !@target_loaded || @target.nil? || @target.clear?
    end

    def assign(value)
      if value.nil?
        self.target = nil
      elsif BinData::Base === value
        self.target = value
      elsif value.is_a?(Hash)
        self.target = value
      else
        @target = nil
        @target_loaded = false
        @raw_offset = Integer(value)
        @write_offset = nil
        @read_io = nil
      end
    end

    def snapshot
      stored_offset
    end

    def target=(value)
      if value.nil?
        @target = nil
      elsif BinData::Base === value
        unless value.is_a?(target_class)
          raise ArgumentError,
                "expected pointer target to be #{target_class}, got #{value.class}"
        end
        @target = value
      else
        @target = target_prototype.instantiate
        @target.assign(value)
      end

      @target_loaded = true
      @raw_offset = nil
      @write_offset = nil
    end

    def target
      return @target if @target_loaded && @target
      return nil if @target_loaded && @raw_offset == null_value

      @target_loaded = true
      @target = read_target
    end

    def target_for_layout
      target_or_nil
    end

    def target_or_nil
      target
    rescue ValidityError
      nil
    end

    def do_read(io)
      @read_io = io
      @target = nil
      @target_loaded = false
      @write_offset = nil
      @offset_type.clear
      @offset_type.do_read(io)
      @raw_offset = @offset_type.snapshot
    end

    def do_write(io)
      @offset_type.assign(stored_offset)
      @offset_type.do_write(io)
    end

    def do_num_bytes
      @offset_type.num_bytes
    end

    def origin_abs_offset
      container = parent
      container = container.parent while container && !container.is_a?(Struct)
      container ? container.abs_offset : 0
    end

    def target_alignment
      alignment = get_parameter(:target_align)
      alignment = eval_parameter(:target_align) if alignment.is_a?(Symbol) || alignment.respond_to?(:arity)
      result = alignment.to_int
      unless result.positive?
        raise ValidityError, %(target alignment must be positive)
      end
      result
    end

    def write_offset=(offset)
      @write_offset = offset
      @raw_offset = nil
      @target_loaded = false
    end

    private

    def target_prototype
      get_parameter(:type)
    end

    def target_class
      target_prototype.object_class
    end

    def read_target
      return nil if @raw_offset == null_value

      address = target_address
      key = [address, target_class]
      registry = top_level_get(:pointer_objects)
      return registry[key] if registry&.key?(key)

      ensure_address_in_bounds(address)

      object = target_prototype.instantiate
      object.send(:parent=, top_level)
      object.layout_abs_offset = address
      registry[key] = object if registry

      saved_offset = @read_io.offset
      begin
        @read_io.seek_to_abs_offset(address)
        object.do_read(@read_io)
        registry[key] = object if registry
      ensure
        @read_io.seek_to_abs_offset(saved_offset)
      end

      object
    end

    def target_address
      if relative_offset?
        origin_abs_offset + @raw_offset
      else
        @raw_offset
      end
    end

    def ensure_address_in_bounds(address)
      return unless @read_io

      stream_size = @read_io.offset + @read_io.num_bytes_remaining
      if address.negative? || address >= stream_size
        raise ValidityError,
              "pointer at #{abs_offset} refers outside of input: #{address}"
      end
    end

    def relative_offset?
      get_parameter(:offset_base) == :relative
    end

    def null_value
      eval_parameter(:null_value)
    end

    def stored_offset
      @write_offset || @raw_offset || null_value
    end

    def big_endian?
      get_parameter(:endian) == :big
    end
  end

  class PointerArgProcessor < BaseArgProcessor
    include MultiFieldArgSeparator

    def sanitize_parameters!(obj_class, params)
      if obj_class.respond_to?(:dsl_parser)
        dsl = obj_class.dsl_parser.dsl_params
        dsl_params = dsl.dup
        dsl_type = dsl_params.delete(:type)
        if dsl_type
          params[:type] = dsl_type unless params.has_parameter?(:type)
        end
        params.merge!(dsl_params) { |_key, explicit, _dsl| explicit }
      end

      if params.has_parameter?(:endian)
        params[:endian] = params[:endian].respond_to?(:endian) ?
                            params[:endian].endian : params[:endian].to_sym
      end

      params[:type] = params.delete(:target_type) if params.has_parameter?(:target_type)
      params[:target_align] = params.delete(:byte_align) if params.has_parameter?(:byte_align)
      params.sanitize_object_prototype(:type)

      if params[:relative] == true
        params[:offset_base] = :relative
      end

      unless params.has_parameter?(:offset_type)
        width = params.delete(:offset_size) || params.delete(:offset_width) || 32
        params[:offset_type] = ("int" + width.to_s).to_sym
      end
      params.delete(:offset_size)
      params.delete(:offset_width)
      params.sanitize_object_prototype(:offset_type)
      params.delete(:relative)

      if params.has_parameter?(:align)
        params[:target_align] = params.delete(:align)
      elsif params.has_parameter?(:alignment)
        params[:target_align] = params.delete(:alignment)
      end

      offset_base = params[:offset_base]
      params[:offset_base] = :relative if %w[relative rel].include?(offset_base.to_s)
      params[:offset_base] = :absolute if %w[absolute abs].include?(offset_base.to_s)
      unless [:absolute, :relative].include?(params[:offset_base])
        raise ArgumentError, ":offset_base must be :absolute or :relative"
      end

      target_align = params[:target_align]
      if !(target_align.respond_to?(:to_int) ||
           target_align.is_a?(Symbol) || target_align.respond_to?(:arity))
        raise ArgumentError, ":target_align must be a positive integer"
      end
    end
  end
end
