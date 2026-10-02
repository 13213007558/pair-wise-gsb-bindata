require 'bindata/pointer'

module BinData
  # Lays out an object graph containing Pointer fields.
  class Layout
    def self.write(root, io = nil)
      owns_io = io.nil?
      raw_io = BinData::IO.create_string_io if owns_io
      io = BinData::IO::Write.new(io || raw_io)
      result = new.write(root, io)
      io.flush
      owns_io ? raw_io.string : result
    end

    def self.dump(root)
      write(root)
    end

    def write(root, io)
      plan = build_plan(root)
      assign_offsets(root, plan)

      root.write(io)

      offset = root.num_bytes
      plan[:targets].each do |target, info|
        padding = info[:offset] - offset
        io.writebytes("\x00" * padding) if padding.positive?
        target.write(io)
        offset = info[:offset] + target.num_bytes
      end

      io.flush
      io
    end

    private

    def build_plan(root)
      inline_ids = {}.compare_by_identity
      collect_inline_ids(root, inline_ids)

      pointers = []
      targets = {}.compare_by_identity
      queue = [root]
      processed = {}.compare_by_identity

      until queue.empty?
        object = queue.shift
        next if processed.key?(object)
        processed[object] = true

        each_pointer(object) do |pointer|
          pointers << pointer
          target = pointer.target_for_layout
          next unless target
          next if inline_ids.key?(target)

          info = (targets[target] ||= { align: 1 })
          info[:align] = least_common_multiple(info[:align], pointer.target_alignment)
          queue << target unless processed.key?(target)
        end
      end

      { pointers: pointers, targets: targets }
    end

    def assign_offsets(root, plan)
      offset = root.num_bytes

      plan[:targets].each do |target, info|
        offset = align_offset(offset, info[:align])
        target.layout_abs_offset = offset
        info[:offset] = offset
        offset += target.num_bytes
      end

      plan[:pointers].each do |pointer|
        target = pointer.target_for_layout
        next unless target

        absolute_offset = target.layout_abs_offset || target.abs_offset
        if pointer.get_parameter(:offset_base) == :relative
          absolute_offset -= pointer.origin_abs_offset
        end
        pointer.write_offset = absolute_offset
      end
    end

    def collect_inline_ids(object, ids)
      return if ids.key?(object)

      object.layout_abs_offset = nil
      ids[object] = true
      child_objects(object).each do |child|
        collect_inline_ids(child, ids) unless Pointer === child
      end
    end

    def each_pointer(object, &block)
      return enum_for(__method__, object) unless block_given?

      child_objects(object).each do |child|
        if Pointer === child
          yield child
        else
          each_pointer(child, &block)
        end
      end
    end

    def child_objects(object)
      children =
        if Struct === object
          object.send(:instantiate_all_objs)
          object.instance_variable_get(:@field_objs).compact
        elsif Array === object
          object.to_ary
        elsif Buffer === object
          [object.instance_variable_get(:@type)]
        elsif Primitive === object
          [object.instance_variable_get(:@struct)]
        elsif Choice === object
          object.instance_variable_get(:@choices).values
        elsif DelayedIO === object
          [object.instance_variable_get(:@type)]
        else
          []
        end

      children.grep(BinData::Base)
    end

    def align_offset(offset, alignment)
      (offset + alignment - 1) / alignment * alignment
    end

    def least_common_multiple(left, right)
      left / left.gcd(right) * right
    end
  end
end
