require 'bindata/io'

module BinData
  module Checksum # :nodoc: all
    STATE_KEY = :bindata_checksum_state

    class << self
      def state
        Thread.current[STATE_KEY] ||= {
          preview_owners: [],
          field_fillers: {}
        }
      end

      def previewing?(owner)
        state[:preview_owners].include?(owner.object_id)
      end

      def preview(owner, field = nil, filler = nil)
        state[:preview_owners].push(owner.object_id)
        state[:field_fillers][field.object_id] = filler if field
        yield
      ensure
        state[:preview_owners].pop
        state[:field_fillers].delete(field.object_id) if field
      end

      def filler_for(field)
        state[:field_fillers][field.object_id]
      end

      def rules_for(owner, fields)
        owner.send(:instantiate_all_objs)

        fields.map do |field|
          next unless BinData::BasePrimitive === field
          next unless field.has_parameter?(:checksum)
          next unless owner.send(:include_obj?, field)

          Rule.new(owner, field)
        end.compact
      end

      def ordered_rules(rules)
        ordered = []
        visiting = {}
        visited = {}

        visit = lambda do |rule|
          return if visited[rule]

          if visiting[rule]
            cycle = rules.select { |r| visiting[r] }.map(&:field_name)
            cycle << rule.field_name
            raise ArgumentError,
                  "cyclic checksum dependencies: #{cycle.uniq.join(' -> ')}"
          end

          visiting[rule] = true
          dependencies(rule, rules).each { |dep| visit.call(dep) }
          visiting.delete(rule)
          visited[rule] = true
          ordered << rule
        end

        rules.each { |rule| visit.call(rule) }
        ordered
      end

      def dependencies(rule, rules)
        rule_intervals = rule.intervals

        rules.select do |other|
          next false if other.equal?(rule)

          other_interval = other.field_interval
          rule_intervals.any? { |interval| intersect?(interval, other_interval) }
        end
      end

      def intersect?(left, right)
        left_start, left_length = left
        right_start, right_length = right

        left_start < right_start + right_length &&
          right_start < left_start + left_length
      end

      def bytes_for(binary, intervals)
        binary = binary.to_s.dup.force_encoding(Encoding::BINARY)
        result = String.new.force_encoding(Encoding::BINARY)

        intervals.each do |start, length|
          if start.nil?
            result << length.dup.force_encoding(Encoding::BINARY)
            next
          end

          if start.negative? || length.negative? || start + length > binary.bytesize
            raise IOError, "checksum range is outside of serialized data"
          end
          result << binary.byteslice(start, length)
        end

        result
      end

      def without_interval(intervals, excluded)
        excluded_start, excluded_length = excluded
        excluded_end = excluded_start + excluded_length

        intervals.flat_map do |start, length|
          finish = start + length
          next [] if start >= excluded_start && finish <= excluded_end
          next [[start, length]] if finish <= excluded_start || start >= excluded_end

          pieces = []
          pieces << [start, excluded_start - start] if start < excluded_start
          pieces << [excluded_end, finish - excluded_end] if finish > excluded_end
          pieces
        end
      end
    end

    class Rule
      attr_reader :owner, :field, :digest, :self_mode, :range_spec

      def initialize(owner, field)
        @owner = owner
        @field = field
        @spec = normalize_spec(field.get_parameter(:checksum))
        @digest = @spec.fetch(:digest)
        @self_mode = @spec[:self]
        @range_spec = @spec.fetch(:range)
        @range = Range.new(owner, @range_spec)

        validate!
      end

      def field_name
        owner.send(:field_name_for, field)
      end

      def range_label
        @range.label
      end

      def field_interval
        @field_interval ||= interval_for(field)
      end

      def intervals
        @range.intervals
      end

      def compute(binary)
        binary_intervals = digest_intervals

        bytes = source_bytes(binary, binary_intervals)
        digest.call(bytes)
      end

      def verify(source)
        actual = field.snapshot
        expected = digest.call(source_bytes(source, digest_intervals))
        return if actual == expected

        raise ValidityError,
              "checksum mismatch for #{field.debug_name} covering #{range_label}"
      end

      def filler_binary
        return nil unless self_mode && self_mode != :exclude
        return binary_string(self_mode) if self_mode.is_a?(::String)

        serialize_value(self_mode)
      end

      def assign_value(value)
        previous = field.snapshot
        field.assign(value)
        unless field.snapshot == value
          field.assign(previous)
          raise ArgumentError,
                "checksum value #{value.inspect} is not valid for #{field_name}"
        end

        io = BinData::IO.create_string_io
        wrapped = BinData::IO::Write.new(io)
        field.do_write(wrapped)
        wrapped.flush
        if io.string.bytesize != field_interval.last
          field.assign(previous)
          raise ArgumentError,
                "checksum value for #{field_name} is #{io.string.bytesize} bytes but field is #{field_interval.last} bytes"
        end
      rescue StandardError
        field.assign(previous)
        raise
      end

      private

      def normalize_spec(spec)
        unless spec.is_a?(Hash)
          raise ArgumentError,
                "checksum for #{field.debug_name} must be a hash containing :range and :algorithm"
        end

        if spec.key?(:algorithm) && spec.key?(:digest)
          raise ArgumentError,
                "checksum for #{field.debug_name} may specify either :algorithm or :digest"
        end

        result = {}
        result[:range] = spec.fetch(:range)
        result[:digest] = spec.key?(:algorithm) ? spec.fetch(:algorithm) : spec.fetch(:digest)
        result[:self] = spec[:self] if spec.key?(:self)

        unless result[:digest].respond_to?(:call)
          raise ArgumentError, ":algorithm for #{field.debug_name} must be callable"
        end

        result
      end

      def validate!
        covered_intervals = intervals
        ensure_disjoint_intervals(covered_intervals)

        covered_intervals.each do |start, length|
          unless start.is_a?(Integer) && length.is_a?(Integer) && length.positive?
            raise ArgumentError,
                  "checksum range #{range_label} must be byte aligned for #{field.debug_name}"
          end
        end

        within_range = covered_intervals.any? do |interval|
          Checksum.intersect?(interval, field_interval)
        end

        if within_range && self_mode.nil?
          raise ArgumentError,
                "checksum #{field_name} is inside its own range; set self: :exclude or provide fixed filler bytes"
        elsif within_range && self_mode != :exclude
          ensure_width!(filler_binary)
        end

        if !within_range && self_mode && self_mode != :exclude
          raise ArgumentError,
                "self option is not allowed because checksum #{field_name} is outside its range"
        end
      end

      def ensure_width!(candidate)
        width = field_interval.last
        if candidate.bytesize != width
          raise ArgumentError,
                "checksum value for #{field_name} is #{candidate.bytesize} bytes but field is #{width} bytes"
        end
      end

      def ensure_disjoint_intervals(intervals)
        intervals.each_with_index do |left, left_index|
          intervals.each_with_index do |right, right_index|
            next if left_index >= right_index

            if Checksum.intersect?(left, right)
              raise ArgumentError, "overlapping checksum ranges #{range_label}"
            end
          end
        end
      end

      def binary_string(value)
        value.to_s.dup.force_encoding(Encoding::BINARY)
      end

      def digest_intervals
        covered = intervals
        return covered unless self_mode

        covered = replace_interval(covered, field_interval, filler_binary) unless self_mode == :exclude
        covered = Checksum.without_interval(covered, field_interval) if self_mode == :exclude
        covered
      end

      def replace_interval(intervals, target, replacement)
        target_start, target_length = target
        target_end = target_start + target_length

        intervals.flat_map do |start, length|
          finish = start + length
          next [[start, length]] unless Checksum.intersect?([start, length], target)

          pieces = []
          pieces << [start, target_start - start] if start < target_start
          pieces << [nil, replacement]
          pieces << [target_end, finish - target_end] if finish > target_end
          pieces
        end
      end

      def source_bytes(source, ranges)
        if source.respond_to?(:bytes_for)
          source.bytes_for(ranges)
        else
          Checksum.bytes_for(source, ranges)
        end
      end

      def serialize_value(value)
        previous = field.snapshot
        field.assign(value)
        io = BinData::IO.create_string_io
        wrapped = BinData::IO::Write.new(io)
        field.do_write(wrapped)
        wrapped.flush
        io.string.dup.force_encoding(Encoding::BINARY)
      ensure
        field.assign(previous)
      end

      def interval_for(object)
        start = object.rel_offset
        length = object.do_num_bytes
        [start, length]
      end
    end

    class Range
      attr_reader :specs

      def initialize(owner, spec)
        @owner = owner
        @specs = normalize(spec)
      end

      def intervals
        @specs.map { |first_name, last_name| interval(first_name, last_name) }
      end

      def label
        @specs.map do |first_name, last_name|
          first_name == last_name ? first_name.to_s : "#{first_name}..#{last_name}"
        end.join(", ")
      end

      private

      def normalize(spec)
        case spec
        when ::Symbol, ::String
          [[spec, spec]]
        when ::Array
          normalize_array(spec)
        else
          raise ArgumentError, "invalid checksum range #{spec.inspect}"
        end.map { |first, last| [first.to_sym, last.to_sym] }
      end

      def normalize_array(spec)
        if field_name_pair?(spec)
          [[spec.first, spec.last]]
        elsif spec.any? { |item| item.is_a?(::Array) }
          spec.map do |item|
            if item.is_a?(::Symbol) || item.is_a?(::String)
              [item, item]
            elsif field_name_pair?(item)
              [item.first, item.last]
            else
              raise ArgumentError, "invalid checksum range #{spec.inspect}"
            end
          end
        else
          raise ArgumentError, "invalid checksum range #{spec.inspect}"
        end
      end

      def field_name_pair?(item)
        item.is_a?(::Array) && item.length == 2 &&
          item.all? { |name| name.is_a?(::Symbol) || name.is_a?(::String) }
      end

      def interval(first_name, last_name)
        first = field_for(first_name)
        last = field_for(last_name)
        unless @owner.send(:include_obj?, first) && @owner.send(:include_obj?, last)
          raise ArgumentError,
                "checksum range endpoints must be active fields (#{first_name}..#{last_name})"
        end

        first_offset = first.rel_offset
        last_offset = last.rel_offset
        last_length = last.do_num_bytes

        if first_offset > last_offset
          raise ArgumentError,
                "checksum range endpoints are out of order (#{first_name}..#{last_name})"
        end

        [first_offset, (last_offset + last_length) - first_offset]
      end

      def field_for(name)
        @owner[name] ||
          raise(ArgumentError, "unknown checksum range field #{name.inspect} in #{@owner.debug_name}")
      end
    end

    class RecordingIO < BinData::IO::Transform
      attr_reader :chunks

      def initialize
        super()
        @chunks = {}
      end

      def before_transform
        @start_offset = offset
      end

      def read(n)
        position = offset - @start_offset
        data = chain_read(n)
        record(position, data)
        data
      end

      def skip(n)
        position = offset - @start_offset
        data = chain_read(n)
        record(position, data)
        data.size
      end

      def seek_abs(n)
        chain_seek_abs(n)
      end

      def bytes_for(intervals)
        result = String.new.force_encoding(Encoding::BINARY)

        intervals.each do |start, length|
          if start.nil?
            result << length.dup.force_encoding(Encoding::BINARY)
            next
          end

          offset = start
          remaining = length

          while remaining.positive?
            chunk_start, chunk = chunks.find do |candidate_start, candidate|
              candidate_start <= offset &&
                candidate_start + candidate.bytesize > offset
            end

            unless chunk_start
              raise IOError, "checksum range at byte #{start} was not read"
            end

            local_offset = offset - chunk_start
            available = chunk.bytesize - local_offset
            take = [remaining, available].min
            result << chunk.byteslice(local_offset, take)
            offset += take
            remaining -= take
          end
        end

        result
      end

      private

      def record(position, data)
        data = data.to_s.dup.force_encoding(Encoding::BINARY)
        return if data.empty?

        @chunks[position] = data
      end
    end
  end

  module ChecksumFieldPlugin
    def do_write(io) # :nodoc:
      filler = Checksum.filler_for(self)
      return io.writebytes(filler) if filler

      super(io)
    end
  end
end
