#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))
require File.expand_path(
  File.join(File.dirname(__FILE__), "support", "reference_arithmetic"))

# An IO whose #read never returns more than +chunk_size+ bytes at a
# time.  Decoding must give identical results for every chunking.
class ChunkedIO
  def initialize(data, chunk_size)
    @io = StringIO.new(data)
    @chunk_size = chunk_size
  end

  def pos
    @io.pos
  end

  def seek(*args)
    @io.seek(*args)
  end

  def read(n)
    @io.read([n, @chunk_size].min)
  end

  def write(data)
    @io.write(data)
  end
end

# An IO that does not expose #pos (like a pipe or socket): BinData
# treats it as unseekable and must still decode correctly.
class UnseekableIO
  def initialize(data, chunk_size)
    @data = data
    @pos = 0
    @chunk_size = chunk_size
  end

  def read(n)
    slice = @data.byteslice(@pos, [n, @chunk_size].min)
    return nil if slice.nil? || slice.empty?
    @pos += slice.bytesize
    slice
  end

  def write(data)
    @data << data
    data.bytesize
  end
end

# Random chunk sizes, re-seeded with the same seed so a failure is
# reproducible.
class RandomChunkedIO < ChunkedIO
  def initialize(data, seed)
    super(data, 1)
    @rng = Random.new(seed)
  end

  def read(n)
    @io.read([n, 1 + @rng.rand(7)].min)
  end
end

describe BinData::Arith do
  CUM = [0, 80, 95, 100, 101] # symbols 0,1,2 + end marker 3

  def make_record(values, model: CUM, **opts)
    cls = Class.new(BinData::Record) do
      uint8 :kind, initial_value: 9
      arith :tags, { model: model }.merge(opts)
    end
    obj = cls.new
    obj.tags.assign(values)
    obj
  end

  describe "basic behaviour" do
    it "round trips symbols and surrounding fields" do
      obj = make_record([0, 0, 1, 2, 0])
      wire = obj.to_binary_s
      read_back = obj.class.read(wire)
      _(read_back.kind).must_equal 9
      _(read_back.tags.snapshot).must_equal [0, 0, 1, 2, 0]
    end

    it "compresses a skewed sequence" do
      srand(1)
      values = Array.new(1000) { rand < 0.8 ? 0 : rand(1..2) }
      obj = make_record(values)
      wire = obj.to_binary_s
      # 8 byte header + payload much smaller than 1000 raw symbols
      _(wire.bytesize).must_be :<, 400
      _(obj.class.read(wire).tags.snapshot).must_equal values
    end

    it "round trips an empty symbol sequence" do
      obj = make_record([])
      wire = obj.to_binary_s
      _(obj.class.read(wire).tags.snapshot).must_equal []
      _(obj.num_bytes).must_equal wire.bytesize
    end

    it "round trips a long run of identical symbols" do
      values = [0] * 100_000
      obj = make_record(values, model: [0, 99, 100])
      wire = obj.to_binary_s
      _(wire.bytesize).must_be :<, 300
      _(obj.class.read(wire).tags.snapshot).must_equal values
    end

    it "round trips low frequency symbols" do
      model = [0, 1, 2, 1000]
      values = [0, 1, 1, 0, 1, 0, 0, 1, 1, 0]
      obj = make_record(values, model: model)
      wire = obj.to_binary_s
      _(obj.class.read(wire).tags.snapshot).must_equal values
    end

    it "reports num_bytes equal to the wire size" do
      obj = make_record([0, 1, 2, 0, 1])
      _(obj.num_bytes).must_equal obj.to_binary_s.bytesize
    end

    it "presents normal BinData field values after reading" do
      obj = make_record([0, 1, 2])
      read_back = obj.class.read(obj.to_binary_s)
      tags = read_back.tags
      _(tags.length).must_equal 3
      _(tags.size).must_equal 3
      _(tags.to_ary).must_equal [0, 1, 2]
      _(tags[0]).must_equal 0
      _(tags[2]).must_equal 2
      _(tags.first).must_equal 0
      _(tags.last).must_equal 2
      _(tags.map { |t| t.snapshot }).must_equal [0, 1, 2]
      _(tags.empty?).must_equal false
      _(make_record([]).tap { |o| o.read(o.to_binary_s) }.tags.empty?).must_equal true
    end

    it "uses the configured integer element type" do
      cls = Class.new(BinData::Record) do
        arith :tags, model: [0, 80, 95, 100], type: :uint16be
      end
      obj = cls.new
      obj.tags.assign([0, 1, 0])
      read_back = cls.read(obj.to_binary_s)
      _(read_back.tags.snapshot).must_equal [0, 1, 0]
    end
  end

  describe "causal model selection" do
    it "selects the model from an already processed field" do
      cls = Class.new(BinData::Record) do
        uint8 :kind
        arith :tags, model: -> {
          kind.zero? ? [0, 90, 99, 100] : [0, 10, 99, 100]
        }
      end

      [0, 1].each do |kind|
        obj = cls.new
        obj.kind = kind
        obj.tags.assign(kind.zero? ? [0, 0, 1, 0] : [1, 1, 0, 1])
        read_back = cls.read(obj.to_binary_s)
        _(read_back.kind).must_equal kind
        _(read_back.tags.snapshot).must_equal obj.tags.snapshot
      end
    end

    it "selects the model from previous symbols and index" do
      cls = Class.new(BinData::Record) do
        arith :tags, model: -> {
          if index.zero?
            [0, 50, 75, 100]
          elsif element.zero?
            [0, 98, 99, 100]   # after a 0, expect 0
          else
            [0, 1, 99, 100]    # after a 1, expect 1
          end
        }
      end

      srand(5)
      values = Array.new(3000) { |i| i.zero? ? 0 : (rand(10) < 8 ? 0 : 1) }

      obj = cls.new
      obj.tags.assign(values)
      wire = obj.to_binary_s
      _(cls.read(wire).tags.snapshot).must_equal values
      _(wire.bytesize).must_be :<, values.length / 2
    end

    it "accepts an ArithmeticCodec::Model as the model" do
      model = BinData::ArithmeticCodec::Model.new([80, 15, 4, 1])
      cls = Class.new(BinData::Record) do
        arith :tags, model: model
      end
      obj = cls.new
      srand(0)
      values = Array.new(500) { |i| i < 400 ? 0 : rand(3) }
      obj.tags.assign(values)
      _(cls.read(obj.to_binary_s).tags.snapshot).must_equal values
    end
  end

  describe "adaptive model" do
    it "round trips with an independent model per side" do
      cls = Class.new(BinData::Record) do
        arith :tags, adaptive: { num_symbols: 8 }
      end
      srand(9)
      values = Array.new(5000) { rand < 0.95 ? 0 : rand(1...8) }
      obj = cls.new
      obj.tags.assign(values)
      wire = obj.to_binary_s
      _(wire.bytesize).must_be :<, 500
      _(cls.read(wire).tags.snapshot).must_equal values
    end

    it "honours initial_frequency and max_total" do
      cls = Class.new(BinData::Record) do
        arith :tags, adaptive: {
          num_symbols: 4, initial_frequency: 1, max_total: 64
        }
      end
      srand(13)
      values = Array.new(10_000) { rand < 0.9 ? 0 : rand(1...4) }
      obj = cls.new
      obj.tags.assign(values)
      _(cls.read(obj.to_binary_s).tags.snapshot).must_equal values
    end

    it "round trips an empty adaptive sequence" do
      cls = Class.new(BinData::Record) do
        arith :tags, adaptive: { num_symbols: 2 }
      end
      obj = cls.new
      obj.tags.assign([])
      _(cls.read(obj.to_binary_s).tags.snapshot).must_equal []
    end

    it "rejects :model together with :adaptive" do
      assert_raises(ArgumentError) do
        Class.new(BinData::Record) do
          arith :tags, model: [0, 1], adaptive: { num_symbols: 2 }
        end
      end
    end

    it "rejects a bad adaptive configuration" do
      assert_raises(ArgumentError) do
        Class.new(BinData::Record) do
          arith :tags, adaptive: { max_total: 64 }
        end
      end
    end
  end

  describe "initial_length" do
    it "round trips when satisfied" do
      cls = Class.new(BinData::Record) do
        arith :tags, model: [0, 90, 100, 101], initial_length: 3
      end
      obj = cls.new
      obj.tags.assign([0, 1, 0])
      _(cls.read(obj.to_binary_s).tags.snapshot).must_equal [0, 1, 0]
    end

    it "raises on write when the length differs" do
      cls = Class.new(BinData::Record) do
        arith :tags, model: [0, 90, 100, 101], initial_length: 3
      end
      obj = cls.new
      obj.tags.assign([0, 1])
      assert_raises(BinData::ValidityError) { obj.to_binary_s }
    end

    it "raises on read when the coded length differs" do
      good_cls = Class.new(BinData::Record) do
        arith :tags, model: [0, 90, 100, 101]
      end
      obj = good_cls.new
      obj.tags.assign([0, 1])
      wire = obj.to_binary_s

      strict_cls = Class.new(BinData::Record) do
        arith :tags, model: [0, 90, 100, 101], initial_length: 5
      end
      assert_raises(BinData::ValidityError) { strict_cls.read(wire) }
    end
  end

  describe "invalid models and symbols" do
    it "rejects illegal static frequencies at definition time" do
      assert_raises(BinData::ArithmeticCodec::InvalidModelError) do
        Class.new(BinData::Record) do
          arith :tags, model: [0, 50, 30, 100]
        end
      end
    end

    it "rejects an illegal model from a callable before writing" do
      cls = Class.new(BinData::Record) do
        arith :tags, model: -> { [0, 50, 30, 100] }
      end
      obj = cls.new
      obj.tags.assign([0, 1])
      assert_raises(BinData::ArithmeticCodec::InvalidModelError) do
        obj.to_binary_s
      end
    end

    it "rejects a symbol with zero frequency before writing" do
      cls = Class.new(BinData::Record) do
        arith :tags, model: [0, 50, 50, 100] # symbol 1 zero frequency
      end
      obj = cls.new
      obj.tags.assign([1])
      assert_raises(BinData::ArithmeticCodec::InvalidModelError) do
        obj.to_binary_s
      end
    end

    it "rejects a symbol outside the model range before writing" do
      cls = Class.new(BinData::Record) do
        arith :tags, model: [0, 50, 100] # only symbol 0 plus marker
      end
      obj = cls.new
      obj.tags.assign([7])
      assert_raises(BinData::ArithmeticCodec::InvalidModelError) do
        obj.to_binary_s
      end
    end

    it "rejects a non integer symbol before writing" do
      custom_type = Class.new(BinData::BasePrimitive) do
        def sensible_default
          0
        end

        def value_to_binary_string(val)
          val.to_s
        end

        def read_and_return_value(io)
          raise NotImplementedError
        end
      end
      BinData::RegisteredClasses.register("", "NonIntSymbol", custom_type)

      cls = Class.new(BinData::Record) do
        arith :tags, model: [0, 50, 100], type: :non_int_symbol
      end
      obj = cls.new
      obj.tags.assign(["x"])
      assert_raises(BinData::ArithmeticCodec::InvalidModelError) do
        obj.to_binary_s
      end
    end

    it "rejects a model whose end marker index changes mid stream" do
      cls = Class.new(BinData::Record) do
        arith :tags, model: -> {
          if index < 2
            [0, 80, 100]            # marker at 1
          else
            [0, 80, 95, 100]        # marker at 2
          end
        }
      end
      obj = cls.new
      obj.tags.assign([0, 0, 1, 0])
      assert_raises(BinData::ArithmeticCodec::InvalidModelError) do
        obj.to_binary_s
      end
    end

    it "requires a :model parameter" do
      assert_raises(ArgumentError) do
        Class.new(BinData::Record) do
          arith :tags
        end
      end
    end
  end

  describe "truncated and corrupt input" do
    before do
      @cls = Class.new(BinData::Record) do
        arith :tags, model: [0, 60, 90, 100]
      end
      obj = @cls.new
      srand(21)
      obj.tags.assign(Array.new(500) { rand(3) })
      @wire = obj.to_binary_s
    end

    it "raises on a truncated header" do
      assert_raises(EOFError, IOError) { @cls.read(@wire[0, 3]) }
    end

    it "raises on a payload cut short" do
      cut = @wire[0...-3]
      # declared length now exceeds available bytes
      assert_raises(EOFError, IOError) { @cls.read(cut) }
    end

    it "raises when the payload length header is corrupted downward" do
      bad = @wire.dup
      bad.setbyte(8, bad.getbyte(8) - 1)
      assert_raises(IOError, EOFError) { @cls.read(bad) }
    end

    it "raises when the symbol count header is corrupted" do
      bad = @wire.dup
      bad.setbyte(1, bad.getbyte(1) ^ 0x80)
      assert_raises(IOError) { @cls.read(bad) }
    end

    it "raises on garbage payload bytes" do
      bad = @wire.dup
      (9...bad.bytesize).each { |i| bad.setbyte(i, rand(256)) }
      assert_raises(IOError, EOFError) { @cls.read(bad) }
    end
  end

  describe "independent of IO chunking" do
    def wire
      @wire ||= begin
        cls = Class.new(BinData::Record) do
          uint8 :kind
          arith :tags, adaptive: { num_symbols: 6 }
        end
        obj = cls.new
        obj.kind = 3
        srand(17)
        obj.tags.assign(Array.new(2000) { rand < 0.9 ? 0 : rand(1...6) })
        obj.to_binary_s
      end
    end

    def expected
      @expected ||= begin
        cls = Class.new(BinData::Record) do
          uint8 :kind
          arith :tags, adaptive: { num_symbols: 6 }
        end
        cls.read(wire).tags.snapshot
      end
    end

    [1, 2, 3, 5, 7, 64, 4096].each do |chunk|
      it "decodes identically with chunk size #{chunk}" do
        cls = Class.new(BinData::Record) do
          uint8 :kind
          arith :tags, adaptive: { num_symbols: 6 }
        end
        decoded = cls.read(ChunkedIO.new(wire, chunk)).tags.snapshot
        _(decoded).must_equal expected
      end
    end

    5.times do |i|
      it "decodes identically with random chunking (#{i})" do
        cls = Class.new(BinData::Record) do
          uint8 :kind
          arith :tags, adaptive: { num_symbols: 6 }
        end
        decoded = cls.read(RandomChunkedIO.new(wire, 100 + i)).tags.snapshot
        _(decoded).must_equal expected
      end
    end

    [1, 2, 3, 8].each do |chunk|
      it "decodes identically over an unseekable IO (chunk #{chunk})" do
        cls = Class.new(BinData::Record) do
          uint8 :kind
          arith :tags, adaptive: { num_symbols: 6 }
        end
        decoded = cls.read(UnseekableIO.new(wire, chunk)).tags.snapshot
        _(decoded).must_equal expected
      end
    end
  end

  describe "composition" do
    it "lets a later field choose its model from an earlier decoded arith field" do
      cls = Class.new(BinData::Record) do
        arith :a, model: [0, 90, 99, 100]
        arith :b, model: -> {
          a[0].zero? ? [0, 80, 95, 100, 101] : [0, 5, 15, 95, 101]
        }
      end
      obj = cls.new
      obj.a.assign([0, 0, 1, 0])
      obj.b.assign([0, 0, 0, 2, 0])
      wire = obj.to_binary_s
      read_back = cls.read(wire)
      _(read_back.a.snapshot).must_equal [0, 0, 1, 0]
      _(read_back.b.snapshot).must_equal [0, 0, 0, 2, 0]
    end

    it "works as elements of an array" do
      cls = Class.new(BinData::Record) do
        array :blocks, initial_length: 3 do
          arith model: [0, 90, 100, 101]
        end
      end
      obj = cls.new
      obj.blocks[0].assign([0, 0, 1])
      obj.blocks[1].assign([])
      obj.blocks[2].assign([1, 0])
      wire = obj.to_binary_s
      read_back = cls.read(wire)
      _(read_back.blocks.map(&:snapshot)).must_equal [[0, 0, 1], [], [1, 0]]
    end

    it "works inside a buffer" do
      cls = Class.new(BinData::Record) do
        buffer :buf, length: 32 do
          arith :tags, model: [0, 90, 100, 101]
        end
      end
      obj = cls.new
      obj.buf.assign([0, 0, 1, 0, 0])
      _(cls.read(obj.to_binary_s).buf.snapshot).must_equal [0, 0, 1, 0, 0]
    end

    it "can be used anonymously" do
      # an anonymous field is hidden from the snapshot but still reads
      cls = Class.new(BinData::Record) do
        arith model: [0, 90, 100, 101]
      end
      producer = Class.new(BinData::Record) do
        arith :tags, model: [0, 90, 100, 101]
      end.new
      producer.tags.assign([0, 1, 0])
      read_back = cls.read(producer.to_binary_s)
      _(read_back.snapshot).must_equal({})
    end
  end

  describe "payload byte cross check" do
    it "emits exactly the bytes of the independent reference coder" do
      srand(33)
      values = Array.new(1500) { |i| i < 1000 ? 0 : rand(2) }
      obj = make_record(values)
      wire = obj.to_binary_s
      # leading uint8 :kind, then 32 bit count and 32 bit payload length
      count, payload_len = wire.byteslice(1, 8).unpack("NN")
      _(count).must_equal values.length
      payload = wire.byteslice(9, payload_len)

      ref = ReferenceArithmetic::Encoder.new
      values.each { |s| ref.encode(s, CUM) }
      reference_payload = ref.finish(3, CUM)

      _(payload).must_equal reference_payload
    end
  end
end
