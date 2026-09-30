require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))
require File.expand_path(File.join(File.dirname(__FILE__), "arithmetic_reference"))

describe "BinData::ArithmeticCodec against the independent reference" do
  def weighted(weights)
    target = rand(weights.sum)
    weights.each_with_index do |w, i|
      target -= w
      return i if target.negative?
    end
    weights.length - 1
  end

  def static_models(weights, symbols = nil)
    symbols ||= (0...weights.length).to_a
    primary = StaticModel.new(symbols, weights)
    reference = ReferenceArithmeticCoder::Model.new(symbols.zip(weights), :eos)
    [primary, reference]
  end

  # A plain (non adaptive) model for the BinData coder.
  class StaticModel
    def initialize(symbols, weights)
      @symbols = symbols
      @weights = weights
    end

    def cumulative_frequencies
      total = 0
      @symbols.zip(@weights).flat_map do |sym, freq|
        entry = [sym, total, total + freq]
        total += freq
        entry
      end
    end
  end

  it "produces byte identical output to the reference for random static models" do
    srand(1234)
    300.times do
      n = rand(400)
      m = 2 + rand(250)
      weights = Array.new(m) { 1 + rand(5000) }
      primary, reference = static_models(weights)
      symbols = Array.new(n) { weighted(weights) }

      primary_bytes   = BinData::ArithmeticCodec.encode(primary, symbols)
      reference_bytes = ReferenceArithmeticCoder.encode(reference, symbols)

      _(primary_bytes).must_equal reference_bytes

      decoded = BinData::ArithmeticCodec.decode(StaticModel.new((0...m).to_a, weights),
                                                reference_bytes)
      _(decoded).must_equal symbols
      ref_decoded = ReferenceArithmeticCoder.decode(
        ReferenceArithmeticCoder::Model.new((0...m).to_a.zip(weights), :eos),
        primary_bytes
      )
      _(ref_decoded).must_equal symbols
    end
  end

  it "produces byte identical output for adaptive models" do
    srand(9876)
    50.times do
      n = rand(500)
      symbols = Array.new(n) { rand(4) }

      primary = BinData::ArithmeticCodec::Model.new([0, 1, 2, 3])
      reference = ReferenceArithmeticCoder::Model.new(
        0.upto(3).map { |s| [s, 1] }, :eos
      ) { |model, symbol| model.increment!(symbol) }

      primary_bytes   = BinData::ArithmeticCodec.encode(primary, symbols)
      reference_bytes = ReferenceArithmeticCoder.encode(reference, symbols)

      _(primary_bytes).must_equal reference_bytes

      decoded = BinData::ArithmeticCodec.decode(
        BinData::ArithmeticCodec::Model.new([0, 1, 2, 3]), primary_bytes
      )
      _(decoded).must_equal symbols
    end
  end

  it "handles a rare symbol (frequency 1) interleaved with a common one" do
    srand(4242)
    weights = [1, 10_000]
    symbols = Array.new(1000) { rand < 0.05 ? 0 : 1 }

    primary, reference = static_models(weights)
    _(BinData::ArithmeticCodec.encode(primary, symbols)).must_equal(
      ReferenceArithmeticCoder.encode(reference, symbols)
    )

    decoded = BinData::ArithmeticCodec.decode(StaticModel.new([0, 1], weights),
      BinData::ArithmeticCodec.encode(StaticModel.new([0, 1], weights), symbols))
    _(decoded).must_equal symbols
  end

  it "handles a long run of the same symbol" do
    weights = [1, 10]
    [1, 100, 10_000].each do |len|
      symbols = [1] * len
      primary, reference = static_models(weights)
      bytes = BinData::ArithmeticCodec.encode(primary, symbols)
      _(bytes).must_equal ReferenceArithmeticCoder.encode(reference, symbols)
      _(BinData::ArithmeticCodec.decode(StaticModel.new([0, 1], weights), bytes)).
        must_equal symbols
    end
  end

  it "handles empty symbol streams" do
    bytes = BinData::ArithmeticCodec.encode(
      BinData::ArithmeticCodec::Model.new([0]), []
    )
    _(BinData::ArithmeticCodec.decode(BinData::ArithmeticCodec::Model.new([0]), bytes)).
      must_equal []
    _(ReferenceArithmeticCoder.encode(
      ReferenceArithmeticCoder::Model.new([[0, 1]], :eos), [])).must_equal bytes
  end

  it "codes every symbol at least once when frequencies are extreme" do
    srand(55)
    m = 200
    weights = Array.new(m) { |i| i == 0 ? 1 : 1_000 }
    symbols = (0...m).to_a + Array.new(2000) { weighted(weights) }
    primary, reference = static_models(weights)
    bytes = BinData::ArithmeticCodec.encode(primary, symbols)
    _(bytes).must_equal ReferenceArithmeticCoder.encode(reference, symbols)
    _(BinData::ArithmeticCodec.decode(StaticModel.new((0...m).to_a, weights), bytes)).
      must_equal symbols
  end

  it "keeps symbols with zero-ish relative frequency codable after scaling down" do
    # total far above MAX_FREQUENCY forces halving; rare symbol must survive
    weights = [1] + Array.new(20_000) { 1000 }
    symbols = [0, 1, 0, 5000, 0]
    primary, reference = static_models(weights)
    bytes = BinData::ArithmeticCodec.encode(primary, symbols)
    _(bytes).must_equal ReferenceArithmeticCoder.encode(reference, symbols)
    decoded = BinData::ArithmeticCodec.decode(
      StaticModel.new((0...weights.length).to_a, weights), bytes
    )
    _(decoded).must_equal symbols
  end
end

describe "BinData::ArithmeticCodec error handling" do
  it "rejects a non array cumulative table" do
    model = Object.new
    def model.cumulative_frequencies; {a: [0, 1]}; end
    _(-> { BinData::ArithmeticCodec.encode(model, []) }).must_raise(
      BinData::ArithmeticCodec::InvalidFrequencyError)
  end

  it "rejects malformed triples" do
    model = Object.new
    def model.cumulative_frequencies; [:a, 0, 1, :b]; end
    _(-> { BinData::ArithmeticCodec.encode(model, []) }).must_raise(
      BinData::ArithmeticCodec::InvalidFrequencyError)
  end

  it "rejects non integer frequencies" do
    model = Object.new
    def model.cumulative_frequencies; [:a, 0, 1.5]; end
    _(-> { BinData::ArithmeticCodec.encode(model, []) }).must_raise(
      BinData::ArithmeticCodec::InvalidFrequencyError)
  end

  it "rejects zero or negative frequencies" do
    model = Object.new
    def model.cumulative_frequencies; [:a, 0, 0]; end
    _(-> { BinData::ArithmeticCodec.encode(model, []) }).must_raise(
      BinData::ArithmeticCodec::InvalidFrequencyError)
  end

  it "rejects non contiguous cumulative bounds" do
    model = Object.new
    def model.cumulative_frequencies; [:a, 0, 2, :b, 3, 4]; end
    _(-> { BinData::ArithmeticCodec.encode(model, []) }).must_raise(
      BinData::ArithmeticCodec::InvalidFrequencyError)
  end

  it "rejects duplicate symbols" do
    model = Object.new
    def model.cumulative_frequencies; [:a, 0, 1, :a, 1, 2]; end
    _(-> { BinData::ArithmeticCodec.encode(model, []) }).must_raise(
      BinData::ArithmeticCodec::InvalidFrequencyError)
  end

  it "rejects a symbol colliding with the end marker" do
    model = Object.new
    def model.cumulative_frequencies; [:__bindata_arithmetic_end_of_stream__, 0, 1]; end
    _(-> { BinData::ArithmeticCodec.encode(model, []) }).must_raise(
      BinData::ArithmeticCodec::InvalidFrequencyError)
  end

  it "rejects coding a symbol absent from the model" do
    model = BinData::ArithmeticCodec::Model.new([0, 1])
    _(-> { BinData::ArithmeticCodec.encode(model, [2]) }).must_raise(
      BinData::ArithmeticCodec::InvalidFrequencyError)
  end

  it "rejects a model with no #cumulative_frequencies" do
    _(-> { BinData::ArithmeticCodec.encode(Object.new, []) }).must_raise(
      ArgumentError)
  end

  it "raises on truncated input" do
    bytes = BinData::ArithmeticCodec.encode(
      BinData::ArithmeticCodec::Model.new([0, 1]), [0, 1, 0, 1])
    truncated = bytes[0, bytes.bytesize - 1]
    _(-> { BinData::ArithmeticCodec.decode(
      BinData::ArithmeticCodec::Model.new([0, 1]), truncated) }).must_raise(
      BinData::ArithmeticCodec::CorruptedStreamError)
  end

  it "raises on completely empty input" do
    _(-> { BinData::ArithmeticCodec.decode(
      BinData::ArithmeticCodec::Model.new([0]), "") }).must_raise(
      BinData::ArithmeticCodec::CorruptedStreamError)
  end

  it "raises on corrupted input" do
    bytes = BinData::ArithmeticCodec.encode(
      BinData::ArithmeticCodec::Model.new([0, 1]), [0, 1] * 10)
    corrupted = bytes.dup
    corrupted.setbyte(0, corrupted.getbyte(0) ^ 0xff)
    _(-> { BinData::ArithmeticCodec.decode(
      BinData::ArithmeticCodec::Model.new([0, 1]), corrupted) }).must_raise(
      BinData::ArithmeticCodec::CorruptedStreamError)
  end
end

describe "BinData::Arithmetic field" do
  FourSymbolModel = -> { BinData::ArithmeticCodec::Model.new([0, 1, 2, 3]) }

  class SimpleArithmeticRecord < BinData::Record
    endian :big
    uint16 :header
    arithmetic :payload, model: FourSymbolModel do
      array initial_length: 8, type: :uint8
    end
  end

  it "round trips normal field values" do
    values = [0, 1, 1, 3, 1, 1, 0, 2]
    pkt = SimpleArithmeticRecord.new(header: 42, payload: values)
    wire = pkt.to_binary_s

    read_back = SimpleArithmeticRecord.read(wire)
    _(read_back.header).must_equal 42
    _(read_back.payload.to_a).must_equal values
  end

  it "compresses skewed symbols to fewer bytes than the raw form" do
    values = Array.new(200) { rand < 0.95 ? 1 : 3 }
    pkt = SimpleArithmeticRecord.new(header: 0, payload: values)
    wire = pkt.to_binary_s
    _(wire.bytesize).must_be :<, 2 + values.size
  end

  it "can be embedded in an array of records with independent model instances" do
    class ArithmeticRow < BinData::Record
      endian :big
      uint8 :payload_length, value: -> { payload.num_bytes }
      arithmetic :payload, length: :payload_length, model: FourSymbolModel do
        array initial_length: 4, type: :uint8
      end
    end

    class ManyPackets < BinData::Record
      endian :big
      uint8 :num_rows, value: -> { rows.size }
      array :rows, initial_length: :num_rows, type: :arithmetic_row
    end

    data = ManyPackets.new(rows: [{payload: [0, 1, 2, 3]},
                                  {payload: [1, 1, 1, 1]},
                                  {payload: [3, 2, 1, 0]}])
    wire = data.to_binary_s
    back = ManyPackets.read(wire)
    _(back.rows.map { |r| r.payload.to_a }).must_equal [[0, 1, 2, 3], [1, 1, 1, 1], [3, 2, 1, 0]]
  end

  it "selects the model from an earlier field" do
    even_model = -> { BinData::ArithmeticCodec::Model.new([0, 2, 4, 6]) }
    odd_model  = -> { BinData::ArithmeticCodec::Model.new([1, 3, 5, 7]) }

    class SwitchedRecord < BinData::Record
      endian :big
      uint8 :selector
      arithmetic :payload,
                 model: -> { selector.even? ? EvenModel.call : OddModel.call } do
        array initial_length: 6, type: :uint8
      end
    end

    EvenModel = even_model
    OddModel = odd_model

    [[0, [0, 2, 4, 6, 2, 0]], [1, [1, 3, 5, 7, 3, 1]]].each do |sel, vals|
      wire = SwitchedRecord.new(selector: sel, payload: vals).to_binary_s
      back = SwitchedRecord.read(wire)
      _(back.payload.to_a).must_equal vals
    end
  end

  it "reports num_bytes consistently with the encoded form" do
    values = [0, 0, 0, 1, 2, 3, 3, 3]
    pkt = SimpleArithmeticRecord.new(header: 1, payload: values)
    _(pkt.payload.num_bytes).must_equal pkt.to_binary_s.bytesize - 2
  end

  it "supports a fixed byte length with zero padding" do
    class FixedLengthRecord < BinData::Record
      endian :big
      arithmetic :payload, length: 16, model: FourSymbolModel do
        array initial_length: 4, type: :uint8
      end
    end

    wire = FixedLengthRecord.new(payload: [1, 1, 1, 1]).to_binary_s
    _(wire.bytesize).must_equal 16
    back = FixedLengthRecord.read(wire)
    _(back.payload.to_a).must_equal [1, 1, 1, 1]
  end

  it "raises before writing the record when encoded data overflows fixed length" do
    klass = Class.new(BinData::Record) do
      endian :big
      arithmetic :payload, length: 1, model: FourSymbolModel do
        array initial_length: 100, type: :uint8
      end
    end
    obj = klass.new(payload: Array.new(100) { |i| i % 4 })
    _(-> { obj.to_binary_s }).must_raise IOError
  end

  it "fails before any bytes are written when the model gives illegal frequencies" do
    bad_model = -> {
      Object.new.tap do |o|
        def o.cumulative_frequencies; [:a, 0, 0]; end
      end
    }
    obj = BinData::Arithmetic.new(
      [0, 0],
      model: bad_model,
      type: [:array, { initial_length: 2, type: :uint8 }]
    )
    io = StringIO.new
    _(-> { obj.write(io) }).must_raise(
      BinData::ArithmeticCodec::InvalidFrequencyError)
    _(io.string).must_equal ""

    # and the same failure applies when it is a field inside a record: the
    # arithmetic container itself emits nothing
    klass = Class.new(BinData::Record) do
      endian :big
      uint8 :marker, initial_value: 0xAA
      arithmetic :payload, model: bad_model do
        array initial_length: 2, type: :uint8
      end
    end
    record_io = StringIO.new
    _(-> { klass.new(payload: [0, 0]).write(record_io) }).must_raise(
      BinData::ArithmeticCodec::InvalidFrequencyError)
    _(record_io.string.bytesize).must_be :<=, 1
  end

  it "raises if the model factory is not callable" do
    _(-> {
      Class.new(BinData::Record) do
        endian :big
        arithmetic :payload, model: "not callable" do
          array initial_length: 1, type: :uint8
        end
      end
    }).must_raise ArgumentError
  end

  it "rejects a shared model instance instead of a factory" do
    _(-> {
      BinData::Arithmetic.new(
        [0],
        model: BinData::ArithmeticCodec::Model.new([0]),
        type: [:array, { initial_length: 1, type: :uint8 }]
      )
    }).must_raise ArgumentError
  end

  it "raises if the factory does not return a model" do
    factory = -> { Object.new }
    klass = Class.new(BinData::Record) do
      endian :big
      arithmetic :payload, model: factory do
        array initial_length: 1, type: :uint8
      end
    end
    _(-> { klass.new(payload: [0]).to_binary_s }).must_raise ArgumentError
  end

  it "keeps encoder and decoder model state independent" do
    instances = []
    initial_tables = []
    factory = lambda do
      model = BinData::ArithmeticCodec::Model.new([0, 1, 2, 3])
      instances << model
      initial_tables << model.cumulative_frequencies
      model
    end

    klass = Class.new(BinData::Record) do
      endian :big
      arithmetic :payload, model: factory do
        array initial_length: 3, type: :uint8
      end
    end
    wire = klass.new(payload: [0, 1, 2]).to_binary_s
    back = klass.read(wire)
    _(back.payload.to_a).must_equal [0, 1, 2]

    _(instances.length).must_equal 2
    _(instances[0]).wont_be_same_as instances[1]
    # every model starts from an untrained table, even though the encoder's
    # model adapted while writing
    fresh = BinData::ArithmeticCodec::Model.new([0, 1, 2, 3]).cumulative_frequencies
    _(initial_tables[0]).must_equal fresh
    _(initial_tables[1]).must_equal fresh
  end

  it "supports an array that reads until end of stream" do
    klass = Class.new(BinData::Record) do
      endian :big
      arithmetic :payload, model: FourSymbolModel do
        array read_until: :eof, type: :uint8
      end
    end
    values = [0, 3, 1, 2, 2, 0, 0, 1, 3, 3]
    wire = klass.new(payload: values).to_binary_s
    _(klass.read(wire).payload.to_a).must_equal values
  end

  it "honours a custom end symbol declared by the model" do
    model_class = Class.new do
      def initialize
        @counts = Hash.new(1)
      end

      def end_symbol
        :stop
      end

      def cumulative_frequencies
        [0, 0, @counts[0], 1, @counts[0], @counts[0] + @counts[1]]
      end

      def update(symbol)
        @counts[symbol] += 1
      end
    end

    values = [0, 1, 1, 0, 1]
    factory = -> { model_class.new }
    obj = BinData::Arithmetic.new(
      values,
      model: factory,
      type: [:array, { read_until: :eof, type: :uint8 }]
    )
    wire = obj.to_binary_s
    back = BinData::Arithmetic.read(
      wire,
      model: factory,
      type: [:array, { read_until: :eof, type: :uint8 }]
    )
    _(back.to_a).must_equal values

    bad_factory = -> {
      Object.new.tap do |o|
        def o.end_symbol; :stop; end
        def o.cumulative_frequencies; [:stop, 0, 1]; end
      end
    }
    _(-> {
      BinData::ArithmeticCodec.encode(bad_factory.call, [])
    }).must_raise BinData::ArithmeticCodec::InvalidFrequencyError
  end

  it "round trips an adaptive model with long runs of identical symbols" do
    klass = Class.new(BinData::Record) do
      endian :big
      arithmetic :payload, model: FourSymbolModel do
        array initial_length: 5000, type: :uint8
      end
    end
    values = [2] * 5000
    wire = klass.new(payload: values).to_binary_s
    _(wire.bytesize).must_be :<, 100
    back = klass.read(wire)
    _(back.payload.to_a).must_equal values
  end
end

describe "BinData::Arithmetic field with fragmented underlying IO" do
  # An IO that only ever hands out one byte per #read call.
  class OneByteAtATimeIO
    def initialize(data)
      @io = StringIO.new(data.b)
    end

    def read(n = nil)
      n = 1 if n.nil? || n > 1
      @io.read(n)
    end

    def pos; @io.pos; end
    def seek(amount, whence = IO::SEEK_SET); @io.seek(amount, whence); end
    def write(data); @io.write(data); end
  end

  it "decodes identically regardless of read chunking" do
    values = Array.new(300) { rand(4) }
    wire = BinData::Arithmetic.new(
      values,
      model: -> { BinData::ArithmeticCodec::Model.new([0, 1, 2, 3]) },
      type: [:array, { initial_length: 300, type: :uint8 }]
    ).to_binary_s

    # normal read
    normal = BinData::Arithmetic.read(
      wire,
      model: -> { BinData::ArithmeticCodec::Model.new([0, 1, 2, 3]) },
      type: [:array, { initial_length: 300, type: :uint8 }]
    ).to_a

    # byte-at-a-time read
    chunked = BinData::Arithmetic.read(
      OneByteAtATimeIO.new(wire),
      model: -> { BinData::ArithmeticCodec::Model.new([0, 1, 2, 3]) },
      type: [:array, { initial_length: 300, type: :uint8 }]
    ).to_a

    _(chunked).must_equal values
    _(chunked).must_equal normal
  end

  it "raises on truncated input even when read in one byte chunks" do
    wire = BinData::Arithmetic.new(
      Array.new(50) { rand(4) },
      model: -> { BinData::ArithmeticCodec::Model.new([0, 1, 2, 3]) },
      type: [:array, { initial_length: 50, type: :uint8 }]
    ).to_binary_s

    _(-> {
      BinData::Arithmetic.read(
        OneByteAtATimeIO.new(wire[0, wire.bytesize - 2]),
        model: -> { BinData::ArithmeticCodec::Model.new([0, 1, 2, 3]) },
        type: [:array, { initial_length: 50, type: :uint8 }]
      )
    }).must_raise BinData::ArithmeticCodec::CorruptedStreamError
  end

  it "works inside a fixed length buffer followed by more fields" do
    klass = Class.new(BinData::Record) do
      endian :big
      uint8 :before
      arithmetic :payload, length: 12,
                 model: -> { BinData::ArithmeticCodec::Model.new([0, 1, 2, 3]) } do
        array initial_length: 5, type: :uint8
      end
      uint8 :after
    end

    values = [0, 3, 3, 1, 2]
    wire = klass.new(before: 0x11, payload: values, after: 0x22).to_binary_s
    back = klass.read(OneByteAtATimeIO.new(wire))
    _(back.before).must_equal 0x11
    _(back.payload.to_a).must_equal values
    _(back.after).must_equal 0x22
  end
end
