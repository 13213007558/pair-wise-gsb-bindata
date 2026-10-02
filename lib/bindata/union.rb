require 'bindata/struct'

module BinData
  # A Union is a collection of named views over one fixed-size block of
  # binary storage.  All views start at the same offset, so changing bytes
  # through one view makes those bytes available to every other view.
  #
  #   class Word < BinData::Union
  #     endian :little
  #
  #     uint32 :word
  #     struct :halves do
  #       uint16 :low
  #       uint16 :high
  #     end
  #   end
  #
  #   obj = Word.new
  #   obj.halves.low = 0x3412
  #   obj.halves.high = 0x7856
  #   obj.word #=> 0x78563412
  #
  # The union's capacity defaults to the largest view.  It may also be set
  # explicitly with <tt>:length</tt>.  The union always reads and writes its
  # full capacity.  A view shorter than the union only replaces its own bytes
  # when switched or written; remaining bytes are preserved and serialized as
  # padding.  A view that writes beyond the union's capacity raises IOError.
  class Union < BinData::Struct
    extend DSLMixin

    dsl_parser    :union
    arg_processor :union

    optional_parameter :length

    RESERVED = Struct::RESERVED.merge(length: true).freeze

    def initialize_shared_instance
      super
      @default_length = determine_default_length
    end

    def initialize_instance
      super
      @capacity = determine_capacity
      @bytes = binary_string("\0" * @capacity)
      @active_index = nil
      @loaded_index = nil
      @changed = false
      @syncing_view = false
    end

    def clear
      initialize_instance
    end

    def clear?
      !@changed
    end

    def assign(val)
      return if self.equal?(val)

      clear

      case val
      when BinData::Union
        data = val.to_binary_s
        raise ArgumentError, "union value has wrong length" unless data.bytesize == @capacity

        @bytes = data.dup
        @changed = true
      when nil
        return
      else
        assign_fields(val)
        @changed = true
      end
    end

    def snapshot
      commit_active_view
      active_index = @active_index
      active_view = active_index && @field_objs[active_index]

      snapshot = Snapshot.new
      field_names.each_with_index do |name, index|
        snapshot[name] =
          if index == active_index
            active_view.snapshot
          else
            read_view_snapshot_at(index)
          end
      end
      snapshot
    end

    def do_read(io)
      clear
      @bytes = io.readbytes(@capacity).dup
      @changed = true
    end

    def do_write(io)
      commit_active_view
      io.writebytes(@bytes)
    end

    def do_num_bytes
      @capacity
    end

    def debug_name_of(child)
      field_name = @field_names[find_index_of(child)]
      "#{debug_name}.#{field_name}"
    end

    def offset_of(_child)
      0
    end

    def each_pair(include_all = false)
      commit_active_view

      names = field_names(include_all)
      enumerator = ::Enumerator.new do |yielder|
        names.each { |name| yielder << [name, select_view(name)] }
      end

      block_given? ? enumerator.each { |pair| yield(pair) } : enumerator
    end

    #---------------
    private

    def binary_string(str)
      str.dup.force_encoding(Encoding::BINARY)
    end

    def determine_default_length
      fields = get_parameter(:fields)
      fields.collect { |field| field.instantiate(nil, self).num_bytes }.max || 0
    rescue StandardError
      0
    end

    def determine_capacity
      explicit_length =
        if has_parameter?(:length)
          eval_parameter(:length)
        end
      capacity = explicit_length || @default_length

      unless capacity.respond_to?(:to_int)
        raise ArgumentError, "union :length must evaluate to an integer"
      end

      capacity = capacity.to_int
      if capacity <= 0
        raise ArgumentError, "union :length must be greater than zero"
      end
      if explicit_length && capacity < @default_length
        raise ArgumentError, "union :length is smaller than a declared view"
      end

      capacity
    end

    def define_field_accessors_for(name, index)
      define_singleton_method(name) do
        select_view_at(index)
      end
      define_singleton_method("#{name}=") do |*vals|
        assign_view_at(index, *vals)
      end
      define_singleton_method("#{name}?") do
        true
      end
    end

    def find_obj_for_name(name)
      index = @field_names.index(base_field_name(name))
      select_view_at(index) if index
    end

    def select_view(name)
      index = @field_names.index(base_field_name(name))
      raise IndexError, "no such view '#{name}'" unless index

      select_view_at(index)
    end

    def select_view_at(index)
      commit_active_view unless @active_index == index
      @active_index = index

      view = instantiate_obj_at(index)
      load_view(view) unless @loaded_index == index
      view
    end

    def assign_view_at(index, value)
      commit_active_view unless @active_index == index
      @active_index = index
      @changed = true

      view = instantiate_obj_at(index)
      @syncing_view = true
      begin
        view.assign(value)
      ensure
        @syncing_view = false
      end
      commit_view(view)
      view
    end

    def load_view(view)
      index = find_index_of(view)
      @syncing_view = true
      view.clear
      view.do_read(BinData::IO::Read.new(BinData::IO.create_string_io(@bytes)))
      @loaded_index = index
    rescue EOFError, IOError
      raise IOError, "view '#{@field_names[index]}' exceeds union capacity"
    ensure
      @syncing_view = false
    end

    def read_view_snapshot_at(index)
      snapshot_view = get_parameter(:fields)[index].instantiate(nil, self)
      snapshot_view.do_read(BinData::IO::Read.new(BinData::IO.create_string_io(@bytes)))
      snapshot_view.snapshot
    rescue EOFError, IOError
      raise IOError, "view '#{@field_names[index]}' exceeds union capacity"
    end

    def commit_active_view
      return unless @active_index

      view = @field_objs[@active_index]
      if view
        @changed = true unless view.clear?
        commit_view(view)
      end
    end

    def child_updated(child)
      return if @syncing_view

      index = find_index_of(child)
      return unless index

      @active_index = index
      @changed = true unless child.clear?
      commit_view(child)
    end
    protected :child_updated

    def commit_view(view)
      data = view.to_binary_s
      if data.bytesize > @capacity
        index = find_index_of(view)
        @loaded_index = nil
        raise IOError, "view '#{@field_names[index]}' exceeds union capacity"
      end

      @bytes[0, data.bytesize] = data
      @loaded_index = find_index_of(view)
    end

    def instantiate_obj_at(index)
      @loaded_index = nil if @field_objs[index].nil?
      super
      @field_objs[index]
    end

    def assign_fields(val)
      src = as_stringified_hash(val)

      @field_names.compact.each do |name|
        view = select_view(name)
        if src.key?(name)
          @syncing_view = true
          begin
            view.assign(src[name])
          ensure
            @syncing_view = false
          end
          commit_view(view)
        end
      end
    ensure
      commit_active_view
    end
  end

  class UnionArgProcessor < StructArgProcessor
    include MultiFieldArgSeparator

    def sanitize_parameters!(obj_class, params)
      dsl_params = obj_class.dsl_params
      super(obj_class, params.merge!(dsl_params) { |_key, explicit, _dsl| explicit })
      params.must_be_integer(:length)
    end
  end
end
