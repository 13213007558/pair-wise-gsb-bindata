require 'bindata/struct'

module BinData
  # A Union is a collection of named views over one fixed-size binary
  # storage area.  Modifying a view rewrites the bytes it covers, and all
  # other views decode those shared bytes when next accessed.  Bytes outside
  # a shorter view are retained rather than being cleared.
  #
  #    class Word < BinData::Union
  #      uint32be :word
  #      struct   :halves do
  #        uint16be :high
  #        uint16be :low
  #      end
  #    end
  #
  # The storage capacity defaults to the largest view's encoded size.
  # Views that encode fewer bytes only replace their prefix; the remaining
  # storage bytes are unchanged.  A view that encodes more bytes than the
  # union capacity raises ValidityError.
  #
  # == Parameters
  #
  # <tt>:byte_length</tt>:: The number of bytes in the shared storage.
  #                         Defaults to the largest view's size.
  class Union < BinData::Struct
    extend DSLMixin

    dsl_parser    :union
    arg_processor :union

    optional_parameters :byte_length, :length
    mutually_exclusive_parameters :byte_length, :length

    def initialize_instance
      super
      define_field_accessors
      @capacity = evaluate_capacity
      @storage = "\0" * capacity
      @loaded_views = {}
      @clearing = false
      @loading_views = false
    end

    def clear
      @clearing = true
      super
      @storage = "\0" * capacity
      @loaded_views = {}
    ensure
      @clearing = false
    end

    def clear?
      @storage == "\0" * capacity && super
    end

    def assign(val)
      if val.respond_to?(:to_str)
        data = binary_string(val.to_str)
        if data.bytesize != capacity
          raise ArgumentError, "can't assign #{data.bytesize} bytes to #{capacity} byte union"
        end

        clear
        @storage = data
        reload_views
      else
        clear
        assign_fields(val)
        synchronize_views
      end
    end

    def snapshot
      synchronize_views
      super
    end

    def [](key)
      name = base_field_name(key)
      view_named(name)
    end

    def []=(key, value)
      name = base_field_name(key)
      synchronize_views
      super(name, value)
      synchronize_views(name)
    end

    def each_pair(include_all = false)
      synchronize_views
      super
    end

    def do_read(io)
      @storage = io.readbytes(capacity)
      reload_views
    end

    def do_write(io)
      synchronize_views
      io.writebytes(@storage)
    end

    def do_num_bytes
      capacity
    end

    def offset_of(child) # :nodoc:
      0
    end

    def capacity
      @capacity || evaluate_capacity
    end

    def child_written(child) # :nodoc:
      return if @writing_view || @clearing || @loading_views

      index = find_index_of(child)
      synchronize_views(@field_names[index]) if index
    end

    def capacity_parameter
      if has_parameter?(:byte_length)
        :byte_length
      elsif has_parameter?(:length)
        :length
      end
    end

    private

    def define_field_accessors
      get_parameter(:fields).each_with_index do |field, i|
        name = field.name_as_sym
        define_field_accessors_for(name, i) if name
      end
    end

    def define_field_accessors_for(name, index)
      define_singleton_method(name) do
        view_named(name)
      end
      define_singleton_method("#{name}=") do |*vals|
        synchronize_views
        view_named(name).assign(*vals)
        synchronize_views(name)
      end
      define_singleton_method("#{name}?") do
        instantiate_obj_at(index) if @field_objs[index].nil?
        include_obj?(@field_objs[index])
      end
    end

    def find_obj_for_name(name)
      view_named(name)
    end

    def instantiate_all_objs
      @field_names.each_index { |i| instantiate_obj_at(i) }
      reload_views
    end

    def view_named(name)
      name = name.to_sym
      index = @field_names.index(name)
      return nil unless index

      instantiate_obj_at(index)
      unless @loaded_views[index]
        with_view_loading do
          @field_objs[index].read(BinData::IO.create_string_io(@storage))
        end
        @loaded_views[index] = true
      end

      synchronize_views(name)
      @field_objs[index]
    end

    def assign_fields(val)
      src = as_stringified_hash(val)
      field_names.each do |name|
        public_send("#{name}=", src[name]) if src.key?(name)
      end
    end

    def evaluate_capacity
      parameter = capacity_parameter
      if parameter
        value = eval_parameter(parameter)
        raise ArgumentError, ":#{parameter} must be an integer" if value.nil?
        if !value.respond_to?(:to_int)
          raise ArgumentError, ":#{parameter} must be an integer"
        end

        capacity = value.to_int
        largest_view = largest_static_view_size
        if largest_view > capacity
          raise ArgumentError,
                "union capacity #{capacity} is smaller than view size " +                "#{largest_view} for #{debug_name}"
        end
      else
        capacity = largest_static_view_size
      end

      if capacity.negative?
        raise ArgumentError, "union capacity can not be negative"
      end

      capacity
    end

    def largest_static_view_size
      fields = get_parameter(:fields)
      @largest_static_view_size ||=
        fields.map { |field| field.instantiate(nil, self).do_num_bytes.ceil }.max || 0
    end

    def synchronize_views(preferred_name = nil)
      changed = changed_views
      return if changed.empty?

      name = preferred_name if changed.include?(preferred_name)
      name ||= changed.first if changed.length == 1

      ambiguous = name.nil? ||
                  (changed.length > 1 && changed.include?(preferred_name))
      raise ValidityError, "multiple union views have diverged for #{debug_name}" if ambiguous

      write_view_to_storage(name)
      reload_views(except: name)
    end

    def changed_views
      field_names(true).select do |name|
        view = find_existing_obj_for_name(name)
        view && encoded_view(view) != @storage.byteslice(0, view.num_bytes)
      end
    end

    def find_existing_obj_for_name(name)
      index = @field_names.index(name.to_sym)
      index && @field_objs[index]
    end

    def write_view_to_storage(name)
      view = find_existing_obj_for_name(name)
      data = encoded_view(view)
      if data.bytesize > capacity
        raise ValidityError,
              "view '#{name}' is #{data.bytesize} bytes, exceeding union capacity #{capacity}"
      end

      @storage = data + @storage.byteslice(data.bytesize, capacity - data.bytesize)
    end

    def reload_views(except: nil)
      with_view_loading do
        @field_objs.each_with_index do |view, index|
          next if view.nil?

          name = @field_names[index]
          next if name == except

          view.read(BinData::IO.create_string_io(@storage))
          @loaded_views[index] = true
        end
      end
    end

    def with_view_loading
      saved = @loading_views
      @loading_views = true
      yield
    ensure
      @loading_views = saved
    end

    def encoded_view(view)
      @writing_view = true
      view.to_binary_s
    ensure
      @writing_view = false
    end
  end

  class UnionArgProcessor < StructArgProcessor
    include MultiFieldArgSeparator

    def sanitize_parameters!(obj_class, params)
      params.must_be_integer(:byte_length, :length)
      dsl_fields = obj_class.dsl_parser.fields
      if !dsl_fields.empty?
        super(obj_class, params.merge_dsl_params)
      else
        super(obj_class, params)
      end
    end
  end
end
