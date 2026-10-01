module BinData
  # A constrained layout solver for self describing binary records.
  #
  # Some binary formats store the length of a record as a variable length
  # integer whose own encoded width is included in that length.  Computing
  # such a length requires solving equations of the form:
  #
  #   length = varint_width(length) + content_length
  #
  # The solver only supports non negative, monotonically non decreasing
  # integer expressions over lengths, field offsets and alignments.  This
  # restriction guarantees that fixed point iteration from zero finds the
  # smallest solution whenever one exists.  When a variable length integer
  # crosses a width boundary (e.g. 127 -> 128), the layout is re-stabilised
  # until all quantities are consistent.
  module Layout
    # Largest length the solver will produce.
    MAX_LENGTH = (1 << 62) - 1

    # Largest number of iterations before the solver gives up.
    MAX_ITERATIONS = 1_000

    # Base class for layout related errors.
    class LayoutError < StandardError; end

    # Raised when the layout cannot be stabilised.
    class NoStableSolutionError < LayoutError; end

    # Raised when an expression is outside the supported subset.
    class UnsupportedExpressionError < LayoutError; end

    # Raised when a length exceeds the maximum representable length.
    class LengthOverflowError < LayoutError; end

    # Number of bytes required to encode +value+ as a variable length
    # integer (7 bits per byte, high bit signals continuation).
    def self.varint_width(value)
      if !value.is_a?(Integer) || value < 0
        raise UnsupportedExpressionError,
              "varint width is only defined for non negative integers, got #{value.inspect}"
      end

      width = 1
      value >>= 7
      while value > 0
        width += 1
        value >>= 7
      end
      width
    end

    # Builds a constant expression.
    def self.constant(value)
      Constant.new(value)
    end

    # Builds a reference to another declared quantity.
    def self.reference(name)
      Reference.new(name)
    end

    # Builds a sum of terms.
    def self.add(*terms)
      Add.new(terms)
    end

    # Builds a product of a constant factor and an expression.
    def self.multiply(factor, operand)
      Multiply.new(factor, operand)
    end

    # Builds an expression that rounds +operand+ up to a multiple of
    # +alignment+.
    def self.align_up(operand, alignment)
      AlignUp.new(operand, alignment)
    end

    # Builds an expression for the encoded varint width of +operand+.
    def self.encoded_width(operand)
      EncodedWidth.new(operand)
    end

    # A node in a layout expression.  Expressions are built with
    # Expression.build or the Layout.* factory methods.  Supported forms:
    #
    #   Integer                        # non negative constant
    #   Symbol                         # reference to a declared quantity
    #   [:add, term, ...]              # sum of terms
    #   [:mul, factor, operand]        # constant factor times operand
    #   [:align_up, operand, align]    # round up to multiple of align
    #   [:varint_width, operand]       # encoded varint width of operand
    #
    # Anything else raises UnsupportedExpressionError.
    class Expression
      class << self
        def build(obj)
          case obj
          when Expression
            obj
          when Integer
            Constant.new(obj)
          when Symbol
            Reference.new(obj)
          when ::Array
            build_from_array(obj)
          else
            raise UnsupportedExpressionError,
                  "unsupported expression #{obj.inspect}"
          end
        end

        #-------------
        private

        def build_from_array(arr)
          op, *args = arr
          case op
          when :add
            Add.new(args)
          when :mul
            Multiply.new(*args)
          when :align_up
            AlignUp.new(*args)
          when :varint_width
            EncodedWidth.new(*args)
          else
            raise UnsupportedExpressionError,
                  "unsupported expression #{arr.inspect}"
          end
        rescue ArgumentError
          raise UnsupportedExpressionError,
                "unsupported expression #{arr.inspect}"
        end
      end

      def evaluate(_env)
        raise NotImplementedError
      end

      # Names of all quantities referenced by this expression.
      def references
        []
      end
    end

    # A non negative integer constant.
    class Constant < Expression
      def initialize(value)
        unless value.is_a?(Integer) && value >= 0
          raise UnsupportedExpressionError,
                "constant must be a non negative integer, got #{value.inspect}"
        end

        @value = value
      end

      def evaluate(_env)
        @value
      end
    end

    # A reference to another quantity declared in the solver.
    class Reference < Expression
      def initialize(name)
        @name = name.to_sym
      end

      def evaluate(env)
        env.fetch(@name)
      end

      def references
        [@name]
      end
    end

    # A sum of terms.
    class Add < Expression
      def initialize(terms)
        raise ArgumentError, "add requires at least one term" if terms.empty?

        @terms = terms.collect { |t| Expression.build(t) }
      end

      def evaluate(env)
        @terms.inject(0) { |sum, t| sum + t.evaluate(env) }
      end

      def references
        @terms.flat_map(&:references)
      end
    end

    # A product of a non negative constant factor and an expression.
    class Multiply < Expression
      def initialize(factor, operand)
        unless factor.is_a?(Integer) && factor >= 0
          raise UnsupportedExpressionError,
                "multiplier must be a non negative integer constant, got #{factor.inspect}"
        end

        @factor  = factor
        @operand = Expression.build(operand)
      end

      def evaluate(env)
        @factor * @operand.evaluate(env)
      end

      def references
        @operand.references
      end
    end

    # Rounds an expression up to a multiple of a positive constant alignment.
    class AlignUp < Expression
      def initialize(operand, alignment)
        unless alignment.is_a?(Integer) && alignment > 0
          raise UnsupportedExpressionError,
                "alignment must be a positive integer constant, got #{alignment.inspect}"
        end

        @operand   = Expression.build(operand)
        @alignment = alignment
      end

      def evaluate(env)
        value = @operand.evaluate(env)
        value + (@alignment - (value % @alignment)) % @alignment
      end

      def references
        @operand.references
      end
    end

    # The number of bytes needed to encode an expression as a varint.
    class EncodedWidth < Expression
      def initialize(operand)
        @operand = Expression.build(operand)
      end

      def evaluate(env)
        Layout.varint_width(@operand.evaluate(env))
      end

      def references
        @operand.references
      end
    end

    # Solves a system of non negative monotonic layout equations by fixed
    # point iteration from zero.
    #
    #   solver = BinData::Layout::Solver.new
    #   solver.declare(:length, [:add, [:varint_width, :length], 126])
    #   solver.solve   #=> { length: 127 }
    #
    class Solver
      def initialize(max_length: MAX_LENGTH, max_iterations: MAX_ITERATIONS)
        @max_length     = max_length
        @max_iterations = max_iterations
        @equations      = {}
      end

      # Declares that +name+ is defined by +expression+.
      def declare(name, expression)
        @equations[name.to_sym] = Expression.build(expression)
        self
      end

      # Returns a hash of quantity name to solved value.
      def solve
        ensure_all_references_are_declared

        env = {}
        @equations.each_key { |name| env[name] = 0 }

        iterations = 0
        loop do
          stable = true
          @equations.each do |name, expression|
            value = expression.evaluate(env)
            if value > @max_length
              raise LengthOverflowError,
                    "#{name} (= #{value}) exceeds maximum length #{@max_length}"
            elsif value < env[name]
              raise NoStableSolutionError,
                    "expression for #{name} is not monotonic"
            elsif value > env[name]
              env[name] = value
              stable = false
            end
          end
          return env if stable

          iterations += 1
          if iterations >= @max_iterations
            raise NoStableSolutionError,
                  "layout did not stabilise after #{@max_iterations} iterations"
          end
        end
      end

      #-------------
      private

      def ensure_all_references_are_declared
        declared = @equations.keys
        @equations.each_value do |expression|
          expression.references.each do |ref|
            unless declared.include?(ref)
              raise ArgumentError, "reference to undeclared layout quantity #{ref.inspect}"
            end
          end
        end
      end
    end
  end
end
