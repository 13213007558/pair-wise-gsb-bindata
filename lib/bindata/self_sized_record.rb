require 'bindata/layout'
require 'bindata/record'
require 'bindata/varint'

module BinData
  # A Record whose first field is a varint length that counts all bytes
  # of the record, including its own encoded width and any trailing
  # alignment padding.
  #
  #   require 'bindata'
  #
  #   class Inner < BinData::SelfSizedRecord
  #     varint :len
  #     uint8  :tag
  #     string :payload, read_length: -> { content_length - 1 }
  #   end
  #
  #   class Outer < BinData::SelfSizedRecord
  #     length_align 4
  #
  #     varint :len
  #     uint8  :version
  #     inner  :inner
  #   end
  #
  #   obj = Outer.new(version: 1, inner: { tag: 7, payload: "hello" })
  #   obj.to_binary_s   #=> length prefixed, zero padded to a multiple of 4
  #
  # The length is solved with BinData::Layout so business code never has
  # to guess how many bytes the length field itself occupies.  Writing is
  # atomic: the record is fully built in an internal buffer before a single
  # byte is handed to the caller's IO, so a failed build never leaves half
  # a record behind.
  #
  # == Class methods
  #
  # [+length_align+ <em>n</em>]  The total record length (including the
  #                              length field itself) is rounded up to a
  #                              multiple of +n+ bytes by appending zero
  #                              padding.  Defaults to 1 (no padding).
  class SelfSizedRecord < BinData::Record
    # Largest number of re-stabilisation rounds when writing.
    STABILIZE_ITERATIONS = 100

    class << self
      # Gets or sets the record length alignment.
      def length_align(n = nil)
        if n.nil?
          @length_align ||
            (superclass.respond_to?(:length_align) ? superclass.length_align : 1)
        else
          unless n.is_a?(Integer) && n > 0
            raise ArgumentError, "length_align must be a positive integer"
          end

          @length_align = n
        end
      end
    end

    def initialize_shared_instance
      super

      if get_parameter(:fields).any_field_has_parameter?(:byte_align)
        raise ArgumentError,
              "use length_align instead of byte_align in #{self.class}"
      end
    end

    # The current value of the length field.
    def length_value
      length_field.value
    end

    # Bytes of the record that follow the length field, including padding.
    def content_length
      length_value - Layout.varint_width(length_value)
    end

    # Number of zero padding bytes appended for alignment.
    def padding_length
      content_length - content_num_bytes
    end

    def do_num_bytes # :nodoc:
      stabilize_layout!
    end

    def do_read(io) # :nodoc:
      instantiate_all_objs

      length_field.do_read(io)
      if content_length < 0
        raise ValidityError,
              "length #{length_value} does not include its own field for #{debug_name}"
      end

      @field_objs[1..-1].each do |f|
        f.do_read(io) if include_obj_for_io?(f)
      end

      if padding_length < 0
        raise ValidityError,
              "content exceeds declared length #{length_value} for #{debug_name}"
      end
      io.readbytes(padding_length)
    end

    def do_write(io) # :nodoc:
      stabilize_layout!

      # Build the complete record in an internal buffer first.  The
      # caller's IO is only touched once the build has succeeded, so a
      # failure can never leave half a record behind.
      raw = BinData::IO.create_string_io
      buffer = BinData::IO::Write.new(raw)
      @field_objs.each { |f| f.do_write(buffer) if include_obj_for_io?(f) }
      buffer.writebytes(binary_string("\x00") * padding_length)

      io.writebytes(raw.string)
    end

    #---------------
    private

    def length_field
      instantiate_all_objs
      obj = @field_objs[0]
      unless Varint === obj
        raise TypeError,
              "first field of #{debug_name} must be a varint length field"
      end
      obj
    end

    # Recomputes the length field until the record layout is stable.
    # Returns the solved record length.
    def stabilize_layout!
      length = length_value

      STABILIZE_ITERATIONS.times do
        solved = solve_length(content_num_bytes)
        return solved if solved == length

        length_field.assign(solved)
        length = solved
      end

      raise Layout::NoStableSolutionError,
            "layout of #{debug_name} did not stabilise after " \
            "#{STABILIZE_ITERATIONS} iterations"
    end

    def solve_length(content_num_bytes)
      solver = Layout::Solver.new
      solver.declare(:length,
                     Layout.align_up(
                       Layout.add(Layout.encoded_width(:length),
                                  content_num_bytes),
                       self.class.length_align))
      solver.solve[:length]
    end

    def content_num_bytes
      instantiate_all_objs
      sum = 0
      @field_objs[1..-1].each do |f|
        next unless include_obj?(f)

        nbytes = f.do_num_bytes
        sum = (nbytes.is_a?(Integer) ? sum.ceil : sum) + nbytes
      end
      sum
    end
  end
end
