require 'bindata/dsl'
require 'bindata/struct'

module BinData
  class Pointer < BinData::Base
    def self.pointer_dsl_parser?
      true
    end

    extend DSLMixin

    dsl_parser    :pointer
    arg_processor :pointer

    mandatory_parameter :type
    optional_parameters :pointer_type, :offset_base, :relative_offset, :offset,
                         :align, :target_align, :alignment,
                         :null_value, :null, :nil_value
    default_parameters pointer_type: :uint32,
                        offset_base: :absolute,
                        align: 1

    def initialize_instance
      @storage = get_parameter(:pointer_type).instantiate(nil, self)
      @target = nil
    end

    def clear
      @target = nil
      @storage.clear
    end

    def clear?
      @target.nil? && @storage.clear?
    end

    def assign(val)
      case val
      when nil
        clear
      when Pointer
        @storage.assign(val.offset)
        self.target = val.target
      when BinData::Base
        self.target = val
      when Integer
        @target = nil
        @storage.assign(val)
      else
        @target = create_target(val)
      end
    end

    def snapshot
      @storage.snapshot
    end

    def offset
      @storage.snapshot
    end

    def target
      @target
    end

    def target=(target)
      unless target.nil? || target_class === target
        raise ArgumentError,
              "pointer target must be a #{target_class}, got #{target.class}"
      end

      @target = target
    end
    alias referent= target=

    def target?
      !@target.nil?
    end

    def target_alignment
      eval_parameter(has_parameter?(:target_align) ? :target_align : :align).to_i
    end

    def do_read(io)
      @storage.do_read(io)
      @target = resolve_target(io)
    end

    def do_write(io)
      @storage.do_write(io)
    end

    def do_num_bytes
      @storage.do_num_bytes
    end

    def storage_num_bytes
      @storage.do_num_bytes
    end

    def assign_storage_offset(offset)
      @storage.assign(offset)
    end

    def respond_to_missing?(symbol, include_all = false)
      @target&.respond_to?(symbol, include_all) || super
    end

    def method_missing(symbol, ...)
      @target&.respond_to?(symbol) ? @target.__send__(symbol, ...) : super
    end

    private

    def target_class
      get_parameter(:type).object_class
    end

    def create_target(value = nil)
      get_parameter(:type).instantiate(value, nil)
    end

    def resolve_target(io)
      raw_offset = @storage.snapshot
      null_value = null_offset_value
      return nil if !null_value.nil? && raw_offset == null_value

      context = layout_context
      raise IOError, "pointer is not contained in a BinData::Layout" unless context

      address = relative_offset? ? pointer_base_offset + raw_offset : raw_offset
      if address.negative? || address >= context.stream_size
        raise EOFError, "pointer offset #{address} is outside the input"
      end

      alignment = target_alignment
      if alignment > 1 && (address % alignment).nonzero?
        raise ValidityError,
              "pointer target at offset #{address} is not aligned to #{alignment}"
      end

      key = [address, target_class]
      context.targets.fetch(key) do
        target = create_target
        target.layout_abs_offset = address
        target.layout_context = context
        context.targets[key] = target

        position = io.offset
        begin
          io.seek_to_abs_offset(address)
          start_read { target.do_read(io) }
        ensure
          io.seek_to_abs_offset(position)
        end

        target
      end
    end

    def pointer_base_offset
      ancestor = parent
      ancestor = ancestor.parent while ancestor && !(BinData::Struct === ancestor)
      ancestor ? ancestor.abs_offset : 0
    end

    def relative_offset?
      if has_parameter?(:relative_offset)
        eval_parameter(:relative_offset) == true
      else
        get_parameter(:offset_base) == :relative
      end
    end

    def null_offset_value
      eval_parameter(has_parameter?(:null) ? :null : :null_value)
    end
  end

  class PointerArgProcessor < BaseArgProcessor
    include MultiFieldArgSeparator

    def sanitize_parameters!(obj_class, params)
      params.merge_dsl_params

      [:target_type, :referent_type, :pointed_type].each do |key|
        params[:type] = params.delete(key) if params.key?(key)
      end
      if params.key?(:target_align)
        params[:align] = params.delete(:target_align)
      elsif params.key?(:alignment)
        params[:align] = params.delete(:alignment)
      end
      if params.key?(:null)
        params[:null_value] = params.delete(:null)
      elsif params.key?(:nil_value)
        params[:null_value] = params.delete(:nil_value)
      end
      if params.key?(:offset_base) && !params[:offset_base].respond_to?(:call)
        params[:offset_base] = params[:offset_base].to_sym
      end
      if params.key?(:offset)
        params[:offset_base] = params.delete(:offset).to_sym
      end
      params[:relative_offset] = params[:relative_offset] == true if params.key?(:relative_offset)

      params.sanitize_object_prototype(:type)
      params.sanitize_object_prototype(:pointer_type)
      params.must_be_integer(:null_value)
    end
  end

  class Layout < BinData::Struct
    extend DSLMixin

    unregister_self
    dsl_parser    :struct
    arg_processor :layout

    def do_read(io)
      @layout_context = PointerContext.new({}, io.num_bytes_remaining)
      super
    end

    def do_write(io)
      allocation = LayoutPlanner.new(self).allocate
      super

      cursor = allocation.root_size
      allocation.targets.each do |target, address|
        io.writebytes("\0" * (address - cursor)) if address > cursor
        target.do_write(io)
        cursor = address + target.do_num_bytes.ceil
      end
    end

    def do_num_bytes
      allocation = LayoutPlanner.new(self).allocate
      [allocation.root_size, allocation.end_offset].max
    end
  end

  class LayoutArgProcessor < StructArgProcessor
    include MultiFieldArgSeparator

    def sanitize_parameters!(obj_class, params)
      super(obj_class, params.merge_dsl_params)
    end
  end

  PointerContext = ::Struct.new(:targets, :stream_size)

  class LayoutAllocation
    attr_reader :root_size, :targets, :end_offset

    def initialize(root_size, targets)
      @root_size = root_size
      @targets = targets
      ending = targets.empty? ? root_size :
        targets.map { |target, address| address + target.do_num_bytes.ceil }.max
      @end_offset = [root_size, ending].max
    end
  end

  class LayoutPlanner
    def initialize(root)
      @root = root
      @inline_nodes = {}
      @external_alignments = Hash.new(0)
    end

    def allocate
      reset_inline_tree(@root)
      discover_external_targets

      root_size = inline_num_bytes(@root)
      addresses = assign_target_addresses(root_size)
      encode_pointers(addresses)

      LayoutAllocation.new(root_size, addresses)
    end

    private

    def reset_inline_tree(node)
      node.reset_layout_abs_offset!
      @inline_nodes[node] = true
      return if BinData::Pointer === node

      layout_regular_children(node).each { |child| reset_inline_tree(child) }
    end

    def reset_external_tree(node)
      node.reset_layout_abs_offset!
      return if BinData::Pointer === node

      layout_regular_children(node).each do |child|
        reset_inline_tree(child)
      end
    end

    def discover_external_targets
      pointers = collect_pointers(@root)

      until pointers.empty?
        pointer = pointers.shift
        target = pointer.target
        next if target.nil? || @inline_nodes.key?(target)

        alignment = [pointer.target_alignment, 1].max
        if @external_alignments.key?(target)
          @external_alignments[target] = [@external_alignments[target], alignment].max
        else
          @external_alignments[target] = alignment
          reset_external_tree(target)
          pointers.concat(collect_pointers(target))
        end
      end
    end

    def assign_target_addresses(cursor)
      addresses = {}
      ordered_targets.each do |target, alignment|
        cursor = ((cursor + alignment - 1) / alignment) * alignment
        addresses[target] = cursor
        target.layout_abs_offset = cursor
        cursor += target.do_num_bytes.ceil
      end
      addresses
    end

    def ordered_targets
      @external_alignments.each_with_index
                       .sort_by { |(_, alignment), index| [-alignment, index] }
                       .map { |(target, alignment), _| [target, alignment] }
    end

    def encode_pointers(addresses)
      pointers = collect_pointers(@root)
      addresses.each_key { |target| pointers.concat(collect_pointers(target)) }

      pointers.each do |pointer|
        target = pointer.target
        next if target.nil?

        target_offset =
          if target.equal?(@root)
            0
          elsif addresses.key?(target)
            addresses[target]
          else
            target.abs_offset
          end

        encoded_offset = target_offset - pointer_base_offset(pointer)
        encoded_offset = target_offset unless relative_offset?(pointer)
        pointer.assign_storage_offset(encoded_offset)
      end
    end

    def collect_pointers(node)
      result = []
      collect_pointers_into(node, result, {})
      result
    end

    def inline_num_bytes(node)
      case node
      when BinData::Pointer
        node.storage_num_bytes.ceil
      when BinData::Array
        node.sum(0) { |element| inline_num_bytes(element) }
      when BinData::Choice
        inline_num_bytes(node.send(:current_choice))
      when BinData::Struct
        node.send(:instantiate_all_objs)
        fields = node.instance_variable_get(:@field_objs)
        offset = 0
        fields.each do |child|
          next unless child.layout_included?

          if struct_field_aligned?(node, child)
            offset = align_offset(offset, struct_field_alignment(child))
          end
          offset += inline_num_bytes(child)
        end
        offset
      when BinData::DelayedIO, BinData::Buffer, BinData::Section
        inline_num_bytes(node.instance_variable_get(:@type))
      else
        node.do_num_bytes.ceil
      end
    end

    def struct_field_aligned?(node, child)
      child.has_parameter?(:byte_align) && node.respond_to?(:bytes_to_align, true)
    end

    def struct_field_alignment(child)
      child.eval_parameter(:byte_align)
    end

    def align_offset(offset, alignment)
      ((offset + alignment - 1) / alignment) * alignment
    end

    def collect_pointers_into(node, result, seen)
      stack = [node]
      until stack.empty?
        current = stack.pop
        next if seen.key?(current.object_id)

        seen[current.object_id] = true
        next unless current.layout_included?

        if BinData::Pointer === current
          result << current
        else
          stack.concat(layout_regular_children(current))
        end
      end
    end

    def pointer_base_offset(pointer)
      ancestor = pointer.parent
      ancestor = ancestor.parent while ancestor && !(BinData::Struct === ancestor)
      ancestor ? ancestor.abs_offset : 0
    end

    def relative_offset?(pointer)
      pointer.send(:relative_offset?)
    end

    def layout_regular_children(node)
      node.layout_regular_children
    end
  end

  class Base
    def layout_included?
      !has_parameter?(:onlyif) || eval_parameter(:onlyif)
    end
  end

  class Struct
    def layout_regular_children
      instantiate_all_objs
      @field_objs.select(&:layout_included?)
    end
  end

  class Array
    def layout_regular_children
      each.to_a
    end
  end

  class Choice
    def layout_regular_children
      self.layout_included? ? [send(:current_choice)] : []
    end
  end

  class DelayedIO
    def layout_regular_children
      include_obj? ? [@type] : []
    end
  end

  class Buffer
    def layout_regular_children
      [@type]
    end
  end

  class Section
    def layout_regular_children
      [@type]
    end
  end
end
