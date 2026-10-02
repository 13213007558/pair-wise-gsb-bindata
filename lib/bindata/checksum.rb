require 'bindata/struct'

module BinData
  # A Checksum is a derived field that stores a digest (checksum, hash, CRC,
  # etc) computed over the serialized bytes of other fields in the same
  # record.  A common pattern is a header that carries a digest of the body,
  # with a trailer that in turn verifies header and body together.
  #
  # The digest algorithm is supplied by the caller as the +:algorithm+
  # parameter.  It may be a callable that accepts a binary string and
  # returns the digest as a string, or an object that responds to +digest+
  # (e.g. <tt>Digest::SHA256</tt>).  The digest must have a fixed length.
  #
  # The fields covered by the digest are nominated with the +:over+
  # parameter, which accepts a field name, a list of field names or a range
  # of field names.  The digest input is the concatenation of the actual
  # serialized bytes of those fields, in order.  Nested records and variable
  # length arrays contribute their exact serialized bytes.
  #
  # Checksums may cover other checksum fields.  Any required computation
  # order is resolved automatically when writing.  Circular dependencies
  # between checksum fields are rejected.
  #
  # A checksum field may lie inside its own covered range.  This must be
  # made explicit by either excluding the field from its own digest
  # (+exclude_self: true+) or by contributing a fixed padding value
  # (+fill: "..."+) in place of its own bytes.
  #
  # When reading, the digest is verified after all fields of the enclosing
  # record have been read.  A mismatch raises BinData::ValidityError
  # identifying the checksum field and its covered range.
  #
  #   require 'bindata'
  #   require 'digest'
  #
  #   class MyFile < BinData::Record
  #     endian :little
  #
  #     uint16   :magic, initial_value: 0x4D47
  #     uint8    :body_len, value: -> { body.length }
  #     checksum :body_digest, algorithm: Digest::SHA256, over: :body
  #     string   :body, read_length: :body_len
  #     checksum :file_digest, algorithm: Digest::SHA256, over: :magic..:body
  #   end
  #
  #   obj = MyFile.new(body: "hello")
  #   obj.to_binary_s  #=> serialized bytes with both digests filled in
  #
  # == Parameters
  #
  # Parameters may be provided at initialisation to control the behaviour of
  # an object.  These params are:
  #
  # <tt>:algorithm</tt>::    The digest algorithm.  A callable accepting the
  #                          serialized bytes and returning the digest as a
  #                          string, or an object responding to +digest+.
  # <tt>:over</tt>::         The fields covered by the digest.  A field name,
  #                          an array of field names, or a range of field
  #                          names of the enclosing record.
  # <tt>:exclude_self</tt>:: If this field lies inside its own +:over+ range,
  #                          it contributes no bytes to the digest.
  # <tt>:fill</tt>::         If this field lies inside its own +:over+ range,
  #                          its bytes are replaced by this fixed string when
  #                          computing the digest.  Must be the same length
  #                          as the digest.
  class Checksum < BinData::Base
    arg_processor :checksum

    mandatory_parameters :algorithm, :over
    optional_parameters :exclude_self, :fill
    mutually_exclusive_parameters :exclude_self, :fill

    def initialize_shared_instance
      @digest_length = digest_bytes("".b).bytesize
      if @digest_length.zero? ||
          digest_bytes("\x00".b).bytesize != @digest_length
        raise ArgumentError,
              "checksum algorithm in #{self.class} must return a " +              "fixed length digest"
      end

      if has_parameter?(:fill)
        nbytes = get_parameter(:fill).bytesize
        if nbytes != @digest_length
          raise ArgumentError,
                "fill in #{self.class} must be #{@digest_length} bytes, " +                "got #{nbytes}"
        end
      end

      super
    end

    def initialize_instance
      @value = nil
      @covered_entries = nil
    end

    def clear? # :nodoc:
      @value.nil?
    end

    def assign(_) # :nodoc:
      # The value of a checksum is derived from other fields.
      # Assignments are ignored.
    end

    def snapshot
      @value.nil? ? compute_digest : @value
    end

    # Verifies the digest read from the stream against the digest computed
    # from the covered fields.  Called after all fields of the enclosing
    # record have been read.
    def verify_checksum! # :nodoc:
      expected = compute_digest
      if @value != expected
        raise ValidityError,
              "checksum mismatch for #{debug_name} " +              "(covering #{range_description})"
      end
    end

    def do_read(io) # :nodoc:
      @value = io.readbytes(@digest_length)
    end

    def do_write(io) # :nodoc:
      io.writebytes(compute_digest)
    end

    def do_num_bytes # :nodoc:
      @digest_length
    end

    # Validates the checksum declarations in +fields+ (the SanitizedFields
    # of a Struct).  Raises ArgumentError for declarations that can never be
    # satisfied: unknown field names, checksums that ambiguously cover
    # themselves, and checksum dependency cycles.
    def self.validate_declaration!(fields) # :nodoc:
      field_names = fields.field_names
      graph = {}

      fields.each_with_index do |field, i|
        next unless field.obj_class <= BinData::Checksum

        indices = resolve_range_indices(field.get_parameter(:over), field_names)
        if indices.include?(i) && !field.get_parameter(:exclude_self) &&
            !field.has_parameter?(:fill)
          name = field.name_as_sym || "at index #{i}"
          raise ArgumentError,
                "checksum field '#{name}' covers itself; " +                "specify exclude_self: true or fill: <bytes>"
        end

        graph[i] = indices - [i]
      end

      checksum_indices = graph.keys
      graph.each_key do |from|
        graph[from] &= checksum_indices
      end

      detect_dependency_cycle!(graph, field_names)
    end

    # Resolves an +:over+ parameter to indices into +field_names+.
    def self.resolve_range_indices(over, field_names) # :nodoc:
      case over
      when Range
        first = index_of_covered_field(field_names, over.begin)
        last  = index_of_covered_field(field_names, over.end)
        last -= 1 if over.exclude_end?
        if first > last
          raise ArgumentError,
                "invalid checksum range '#{over.begin}' to '#{over.end}'"
        end

        (first..last).to_a
      when ::Array
        over.collect { |name| index_of_covered_field(field_names, name) }
      else
        [index_of_covered_field(field_names, over)]
      end
    end

    def self.index_of_covered_field(field_names, name) # :nodoc:
      index = field_names.index(name)
      if index.nil?
        raise ArgumentError, "unknown field '#{name}' in checksum range"
      end
      index
    end

    def self.detect_dependency_cycle!(graph, field_names) # :nodoc:
      visiting = []
      visited = {}
      cycle = nil

      visit = lambda do |node|
        if visiting.include?(node)
          cycle = visiting[visiting.index(node)..-1] + [node]
        elsif !visited[node]
          visiting.push(node)
          graph[node].each { |dep| visit.call(dep) if cycle.nil? }
          visiting.pop
          visited[node] = true
        end
      end

      graph.each_key do |node|
        visit.call(node)
        break if cycle
      end

      if cycle
        names = cycle.collect { |i| field_names[i] || "field##{i}" }
        raise ArgumentError, "checksum dependency cycle: #{names.join(' -> ')}"
      end
    end

    #---------------
    private

    def compute_digest
      stack = (Thread.current[:bindata_checksums_being_computed] ||= [])
      if stack.any? { |obj| obj.equal?(self) }
        raise ArgumentError,
              "checksum dependency cycle detected at #{debug_name}"
      end

      stack.push(self)
      begin
        data = covered_entries.filter_map { |_, obj| bytes_for_digest(obj) }.join
        digest_bytes(data)
      ensure
        stack.pop
      end
    end

    def covered_entries
      @covered_entries ||= resolve_covered_entries
    end

    def resolve_covered_entries
      unless parent.respond_to?(:each_pair)
        raise ArgumentError,
              "checksum fields must be declared inside a BinData::Record"
      end

      entries = []
      parent.each_pair(true) { |name, obj| entries << [name, obj] }
      indices = Checksum.resolve_range_indices(get_parameter(:over),
                                               entries.collect(&:first))
      indices.collect { |i| entries[i] }
    end

    def bytes_for_digest(obj)
      if obj.equal?(self)
        get_parameter(:exclude_self) ? nil : binary_string(get_parameter(:fill))
      elsif obj.has_parameter?(:onlyif) && !obj.eval_parameter(:onlyif)
        nil
      else
        obj.to_binary_s
      end
    end

    def digest_bytes(data)
      algorithm = get_parameter(:algorithm)
      result =
        if algorithm.respond_to?(:call)
          algorithm.call(data)
        else
          algorithm.digest(data)
        end

      unless result.is_a?(::String)
        raise ArgumentError,
              "checksum algorithm must return a String, got #{result.class}"
      end

      binary_string(result)
    end

    def range_description
      case (over = get_parameter(:over))
      when Range
        op = over.exclude_end? ? "..." : ".."
        "fields #{over.begin.inspect}#{op}#{over.end.inspect}"
      when ::Array
        "fields #{over.collect(&:inspect).join(', ')}"
      else
        "field #{over.inspect}"
      end
    end
  end

  class ChecksumArgProcessor < BaseArgProcessor
    def sanitize_parameters!(obj_class, params)
      sanitize_algorithm(obj_class, params)
      sanitize_over(obj_class, params)
      sanitize_fill(obj_class, params)
    end

    #-------------
    private

    def sanitize_algorithm(obj_class, params)
      params.sanitize(:algorithm) do |algorithm|
        unless algorithm.respond_to?(:call) || algorithm.respond_to?(:digest)
          raise ArgumentError,
                "parameter 'algorithm' in #{obj_class} must be callable " +                "or respond to #digest"
        end
        algorithm
      end
    end

    def sanitize_over(obj_class, params)
      params.sanitize(:over) do |over|
        case over
        when Range
          first = normalize_field_name(obj_class, over.begin)
          last  = normalize_field_name(obj_class, over.end)
          over.exclude_end? ? (first...last) : (first..last)
        when ::Array
          if over.empty?
            raise ArgumentError,
                  "parameter 'over' in #{obj_class} must not be empty"
          end
          over.collect { |name| normalize_field_name(obj_class, name) }
        else
          normalize_field_name(obj_class, over)
        end
      end
    end

    def sanitize_fill(obj_class, params)
      params.sanitize(:fill) do |fill|
        unless fill.is_a?(::String)
          raise ArgumentError,
                "parameter 'fill' in #{obj_class} must be a String"
        end
        fill
      end
    end

    def normalize_field_name(obj_class, name)
      if name.nil? || !name.respond_to?(:to_sym)
        raise ArgumentError,
              "parameter 'over' in #{obj_class} must contain field names"
      end
      name.to_sym
    end
  end

  class Struct
    # Validates checksum declarations and arranges for checksums to be
    # verified after the struct has been read.
    module ChecksumSupport
      def initialize_shared_instance
        super
        fields = get_parameter(:fields)
        if fields.any? { |field| field.obj_class <= BinData::Checksum }
          BinData::Checksum.validate_declaration!(fields)
          extend ChecksumReadVerification
        end
      end
    end

    # Verifies checksum fields after all fields of the struct have been read.
    module ChecksumReadVerification
      def do_read(io)
        super
        @field_objs.each do |obj|
          if BinData::Checksum === obj && include_obj?(obj)
            obj.verify_checksum!
          end
        end
      end
    end

    prepend ChecksumSupport
  end
end
