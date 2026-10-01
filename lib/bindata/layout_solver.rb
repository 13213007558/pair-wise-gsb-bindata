
module BinData
  # A constrained solver for record layouts where declared values (lengths,
  # field offsets, alignment padding) depend on the size of the record
  # itself.  A common example is a length prefix stored as a variable length
  # integer, where the declared length includes the bytes of the length
  # field itself:
  #
  #   total = body_size + varint_width(total)
  #
  # Such relations can not be computed in a single pass, as crossing a
  # varint width boundary (e.g. 127 to 128) changes the width of the length
  # field, which in turn changes the total.  The solver repeatedly
  # re-evaluates the layout until it stabilises.
  #
  # Expressions are deliberately restricted to non negative, monotonically
  # increasing operations (addition, multiplication, alignment rounding and
  # varint width).  Starting all variables at zero then guarantees that
  # evaluation converges towards the smallest stable layout, if one exists.
  #
  #   solver = BinData::LayoutSolver.new
  #   expr   = BinData::LayoutSolver::Expression
  #
  #   solver.add_constraint(:width, expr.variable(:total).varint_width)
  #   solver.add_constraint(:total, expr.integer(127) + expr.variable(:width))
  #   solver.solve  #=> { width: 2, total: 129 }
  #
  # Three distinct failures are reported:
  #
  # [UnstableLayoutError]        the layout did not stabilise within
  #                              +max_iterations+ passes.
  # [UnsupportedExpressionError] an expression is outside the supported
  #                              range (negative constants, subtraction,
  #                              division, unknown variables, ...).
  # [LengthOverflowError]        a solved value exceeds +max_value+.
  class LayoutSolver
    # Default bound on the number of stabilisation passes.
    DEFAULT_MAX_ITERATIONS = 32

    # Default bound on any solved value.
    DEFAULT_MAX_VALUE = (1 << 31) - 1

    # Base class for layout solving errors.
    class Error < StandardError; end

    # Raised when no stable layout can be found.
    class UnstableLayoutError < Error; end

    # Raised when an expression is outside the supported range of
    # non negative monotonic operations.
    class UnsupportedExpressionError < Error; end

    # Raised when a solved value overflows the allowed maximum.
    class LengthOverflowError < Error; end

    # Number of bytes needed to encode the non negative integer +value+
    # as an unsigned LEB128 variable length integer.
    def self.varint_width(value)
      if value < 0
        raise UnsupportedExpressionError,
              "varint width is undefined for negative value #{value}"
      end

      width = 1
      width += 1 while (value >>= 7) > 0
      width
    end

    def initialize(max_iterations: DEFAULT_MAX_ITERATIONS,
                   max_value: DEFAULT_MAX_VALUE)
      @max_iterations = max_iterations
      @max_value      = max_value
      @constraints    = {}
    end

    # Constrains the variable +name+ to equal the value of +expression+.
    # +expression+ may be an Expression or a non negative Integer.
    def add_constraint(name, expression)
      @constraints[name.to_sym] = Expression.to_expr(expression)
      self
    end

    # Returns a hash of variable name to solved value for a stable layout.
    def solve
      env = {}
      @constraints.each_key { |name| env[name] = 0 }

      @max_iterations.times do
        stable = true

        @constraints.each_pair do |name, expression|
          value = expression.evaluate(env)

          if value > @max_value
            raise LengthOverflowError,
                  "solved value for " + name.to_s.inspect + " (#{value}) " \
                  "exceeds maximum of #{@max_value}"
          end

          if value < env[name]
            raise UnstableLayoutError,
                  "layout for " + name.to_s.inspect + " is not " \
                  "monotonically stable"
          end

          if value != env[name]
            env[name] = value
            stable = false
          end
        end

        return env if stable
      end

      raise UnstableLayoutError,
            "layout did not stabilise after #{@max_iterations} iterations"
    end

    # A restricted layout expression.  Only non negative, monotonically
    # increasing operations are supported: addition, multiplication,
    # #align_up and #varint_width.  Any other operation raises
    # UnsupportedExpressionError.
    class Expression
      class << self
        # A constant term.  Only non negative integers are supported.
        def integer(value)
          unless value.is_a?(Integer)
            raise UnsupportedExpressionError,
                  "unsupported layout term #{value.inspect}"
          end

          if value < 0
            raise UnsupportedExpressionError,
                  "negative constant #{value} is outside the supported " \
                  "range of layout expressions"
          end

          new(:const, [value])
        end

        # A reference to a constrained variable.
        def variable(name)
          new(:var, [name.to_sym])
        end

        # Coerces +obj+ to an Expression.
        def to_expr(obj)
          case obj
          when Expression
            obj
          when Integer
            integer(obj)
          else
            raise UnsupportedExpressionError,
                  "unsupported layout term #{obj.inspect}"
          end
        end
      end

      def initialize(op, args) # :nodoc:
        @op   = op
        @args = args.freeze
        freeze
      end

      def +(other)
        binary(:add, other)
      end

      def *(other)
        binary(:mul, other)
      end

      def -(_other)
        unsupported("subtraction")
      end

      def /(_other)
        unsupported("division")
      end

      def %(_other)
        unsupported("modulo")
      end

      def **(_other)
        unsupported("exponentiation")
      end

      # Allows Integer op Expression (e.g. 3 + expr).
      def coerce(other) # :nodoc:
        [Expression.integer(other), self]
      end

      # Rounds the value of this expression up to a multiple of
      # +alignment+.  +alignment+ must be a positive integer.
      def align_up(alignment)
        unless alignment.is_a?(Integer) && alignment > 0
          raise UnsupportedExpressionError,
                "alignment must be a positive integer, " \
                "not #{alignment.inspect}"
        end

        Expression.new(:align, [self, alignment])
      end

      # The number of bytes needed to encode the value of this
      # expression as an unsigned LEB128 variable length integer.
      def varint_width
        Expression.new(:varint_width, [self])
      end

      # Evaluates this expression in the context of +env+, a hash of
      # variable name to current value.
      def evaluate(env)
        case @op
        when :const
          @args[0]
        when :var
          name = @args[0]
          unless env.key?(name)
            raise UnsupportedExpressionError,
                  "unknown variable " + name.to_s.inspect + " in layout " \
                  "expression"
          end
          env[name]
        when :add
          @args[0].evaluate(env) + @args[1].evaluate(env)
        when :mul
          @args[0].evaluate(env) * @args[1].evaluate(env)
        when :align
          value     = @args[0].evaluate(env)
          alignment = @args[1]
          value + (alignment - (value % alignment)) % alignment
        when :varint_width
          LayoutSolver.varint_width(@args[0].evaluate(env))
        end
      end

      #---------------
      private

      def binary(op, other)
        Expression.new(op, [self, Expression.to_expr(other)])
      end

      def unsupported(operation)
        raise UnsupportedExpressionError,
              "#{operation} is outside the supported range of layout " \
              "expressions (only non negative monotonic operations " \
              "are supported)"
      end
    end
  end
end
