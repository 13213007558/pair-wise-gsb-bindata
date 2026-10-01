require 'bindata/layout_solver'
require 'bindata/struct'
require 'bindata/varint'

module BinData
  class Base
    optional_parameter :solved_length  # Used by Struct
  end

  class Struct
    # A field declared with <tt>solved_length: true</tt> has its value
    # solved by BinData::LayoutSolver so that it equals the total number
    # of bytes of the enclosing struct, including the bytes of the length
    # field itself.  This allows self describing records to be declared
    # without the business code guessing how many bytes the variable
    # length encoding of the length will occupy:
    #
    #   class Chunk < BinData::Record
    #     varint :len, solved_length: true
    #     string :payload
    #   end
    #
    #   chunk = Chunk.new(payload: "abc")
    #   chunk.to_binary_s  #=> "\x04abc"
    #   chunk.len          #=> 4
    #
    # The layout is re-stabilised whenever the record is written or its
    # size is queried, so crossing a varint width boundary (e.g. a total
    # of 127 to 128 bytes) is handled automatically.  Nested records and
    # fields aligned with :byte_align participate in the same layout.
    #
    # Solving happens before any byte is emitted, and the record is
    # rendered into an internal buffer first: if building the record
    # fails, no partial record is left on the caller's IO.
    module SolvedLengthPlugin
      def do_write(io) # :nodoc:
        solve_layout!

        # Render into a buffer so that a failure while building the
        # record does not leave a partial record on the caller's IO.
        buffer  = BinData::IO.create_string_io
        wrapped = BinData::IO::Write.new(buffer)
        super(wrapped)
        wrapped.flush

        io.writebytes(buffer.string)
      end

      def do_num_bytes # :nodoc:
        solve_layout!
        super
      end

      def sum_num_bytes_below_index(index) # :nodoc:
        solve_layout!
        super
      end

      #---------------
      private

      # Expresses the layout of this struct as constraints and solves
      # them, assigning the solved values to the :solved_length fields.
      def solve_layout!
        instantiate_all_objs

        expr    = LayoutSolver::Expression
        solver  = LayoutSolver.new
        solved  = {}
        offset  = expr.integer(0)

        @field_objs.each_with_index do |obj, i|
          next unless include_obj?(obj)

          if obj.has_parameter?(:byte_align)
            offset = offset.align_up(obj.eval_parameter(:byte_align))
          end

          if obj.has_parameter?(:solved_length)
            var = :"solved_length_#{i}"
            solved[var] = obj

            size =
              if Varint === obj
                # the width of the length field depends on its own value
                expr.variable(var).varint_width
              else
                expr.integer(obj.do_num_bytes)
              end
            offset = offset + size
          else
            offset = offset + expr.integer(obj.do_num_bytes)
          end
        end

        solved.each_key { |var| solver.add_constraint(var, offset) }

        solution = solver.solve
        solved.each_pair do |var, obj|
          obj.assign(solution[var])
        end
      end
    end
  end
end
