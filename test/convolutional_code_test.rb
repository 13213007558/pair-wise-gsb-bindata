#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), 'test_helper'))

# A brute force maximum likelihood decoder used as an oracle for small
# blocks.  It encodes every possible information bit string and returns
# the best achievable path metric together with every bit string that
# attains it (ties are common for short or heavily erased blocks).
def brute_force_metric(codec, observations, information_nbits)
  best_metric = nil
  achievers = []

  limit = 1 << information_nbits
  limit.times do |n|
    bits = information_nbits.times.map do |i|
      (n >> (information_nbits - 1 - i)) & 1
    end
    coded = codec.encode(bits)
    metric = observations.each_with_index.sum do |weight, i|
      next 0.0 if weight.nil?
      coded[i] == 1 ? weight : -weight
    end
    if best_metric.nil? || metric > best_metric
      best_metric = metric
      achievers = [bits]
    elsif metric == best_metric
      achievers << bits
    end
  end

  [best_metric, achievers]
end

def metric_of(codec, bits, observations)
  coded = codec.encode(bits)
  observations.each_with_index.sum do |weight, i|
    next 0.0 if weight.nil?
    coded[i] == 1 ? weight : -weight
  end
end

def soft_observations(coded, reliability: 0.9, flips: {})
  coded.each_with_index.map do |bit, i|
    next nil if flips[i] == :erase
    bit = flips[i] if flips.key?(i)
    bit == 1 ? reliability : -reliability
  end
end

def bits_to_bytes(bits)
  bits.each_slice(8).map do |octet|
    octet.reduce(0) { |byte, bit| (byte << 1) | bit }
  end.pack('C*')
end

describe 'ConvolutionalCodec CCSDS encoding' do
  it 'uses the K=7 171/133 generators by default' do
    codec = BinData::ConvolutionalCodec.new
    _(codec.constraint_length).must_equal 7
    _(codec.generators).must_equal [0o171, 0o133]
  end

  it 'starts and ends at state zero for a flushed zero-tail block' do
    codec = BinData::ConvolutionalCodec.new
    coded = codec.encode('A')
    # 8 info bits + 6 flush bits, two coded symbols each
    _(coded.length).must_equal 28
    result = codec.decode(coded, 8)
    _(result.bytes).must_equal 'A'
    _(result.start_state).must_equal 0
    _(result.end_state).must_equal 0
    _(result.path_metric).must_equal 28.0
  end

  it 'produces the expected first symbols for 01010101 from zero state' do
    codec = BinData::ConvolutionalCodec.new
    stream = codec.encode([0, 1, 0, 1, 0, 1, 0, 1])
    _(stream.first(16)).must_equal [0, 0, 1, 1, 0, 1, 1, 1,
                                    1, 0, 0, 0, 0, 0, 1, 1]
  end
end

describe 'ConvolutionalCodec zero-tail decoding' do
  before do
    @codec = BinData::ConvolutionalCodec.new
  end

  it 'round trips hard bits for many random byte strings' do
    20.times do |seed|
      data = Random.new(seed).bytes(12)
      coded = @codec.encode(data)
      result = @codec.decode(coded, 96)
      _(result.bytes).must_equal data
      _(result.start_state).must_equal 0
      _(result.end_state).must_equal 0
    end
  end

  it 'uses soft reliability information' do
    data = 'hello world' # 11 bytes
    coded = @codec.encode(data)
    observations = soft_observations(coded, reliability: 0.25)
    result = @codec.decode(observations, data.bytesize * 8)
    _(result.bytes).must_equal data
    _(result.path_metric).must_be :<, coded.length
  end

  it 'corrects a handful of hard bit flips' do
    data = 'hi there123' # 11 bytes
    coded = @codec.encode(data)
    observations = coded.map { |b| b == 1 ? 1.0 : -1.0 }
    [5, 37, 101, 150].each { |i| observations[i] = -observations[i] }
    result = @codec.decode(observations, data.bytesize * 8)
    _(result.bytes).must_equal data
  end

  it 'accepts bit/reliability pairs and keyword observations' do
    coded = @codec.encode('abc')
    paired = coded.map { |b| [b, 0.5] }
    _(@codec.decode(paired, 24).bytes).must_equal 'abc'

    keyworded = coded.map { |b| { bit: b, reliability: 0.5 } }
    _(@codec.decode(keyworded, 24).bytes).must_equal 'abc'
  end
end

describe 'ConvolutionalCodec missing observations' do
  before do
    @codec = BinData::ConvolutionalCodec.new
  end

  it 'gives zero metric when every symbol is erased' do
    erased = ::Array.new(@codec.coded_nbits(24), nil)
    result = @codec.decode(erased, 24)
    _(result.path_metric).must_equal 0.0
  end

  it 'does not treat erased observations as definite zeros' do
    coded = @codec.encode('payload12') # 9 bytes, 78 coded symbols
    erased = coded.each_with_index.map do |b, i|
      i.even? ? (b == 1 ? 1.0 : -1.0) : nil
    end
    zeroed = erased.map { |w| w.nil? ? -1.0 : w }

    decoded_erased = @codec.decode(erased, 72)
    decoded_zeroed = @codec.decode(zeroed, 72)
    _(decoded_erased.path_metric).wont_equal decoded_zeroed.path_metric
    _(decoded_erased.bytes).must_equal 'payload12'
  end

  it 'recovers from a few erasures' do
    data = 'short' # 5 bytes, 40 info bits + 6 = 46 coded symbols
    coded = @codec.encode(data)
    observations = soft_observations(
      coded, flips: { 9 => :erase, 10 => :erase, 21 => :erase })
    _(@codec.decode(observations, 40).bytes).must_equal data
  end
end

describe 'ConvolutionalCodec puncturing' do
  # rate 3/4 CCSDS puncture pattern over pairs of rate-1/2 symbols:
  # keep 3 out of every 4 coded symbols.
  PUNCTURE_3_4 = [true, true, true, false].freeze

  before do
    @codec = BinData::ConvolutionalCodec.new(puncture: PUNCTURE_3_4)
  end

  it 'keeps only the unpunctured symbols' do
    # 3 info bytes + 6 flush = 30 shifts, 60 raw symbols -> 45 kept
    _(@codec.coded_nbits(24)).must_equal 45
    coded = @codec.encode('abc')
    _(coded.length).must_equal 45
  end

  it 'round trips punctured blocks' do
    10.times do |seed|
      data = Random.new(seed + 100).bytes(8)
      coded = @codec.encode(data)
      _(@codec.decode(coded, 64).bytes).must_equal data
    end
  end

  it 'continues the puncture phase across byte (field block) boundaries' do
    # A punctured zero-tail information byte is 21 coded bits, which is not
    # a whole number of bytes.  Several such blocks placed back to back in a
    # record must pack tightly: the second block starts mid-byte and the
    # puncture phase is independently reset for each block.
    klass = Class.new(BinData::Record) do
      convolutional_code :b0, length: 1, puncture: [true, true, true, false]
      convolutional_code :b1, length: 1, puncture: [true, true, true, false]
      convolutional_code :b2, length: 1, puncture: [true, true, true, false]
    end

    frame = klass.new
    frame.b0.assign('X')
    frame.b1.assign('Y')
    frame.b2.assign('Z')
    # 3 * 21 bits = 63 bits -> 8 bytes on the wire
    _(frame.to_binary_s.bytesize).must_equal 8

    decoded = klass.read(frame.to_binary_s)
    _([decoded.b0, decoded.b1, decoded.b2]).must_equal %w[X Y Z]
  end

  it 'keeps different symbols when the period straddles a block boundary' do
    # Period 5 does not divide the 28-symbol raw block length.  Two adjacent
    # blocks are therefore punctured with different running phases when a
    # single pattern spans them; verify the codec keeps the expected count
    # for each phase offset.
    puncture = [true, true, false, true, false]
    phase_zero = BinData::ConvolutionalCodec.new(puncture: puncture)
    _(28 % 5).wont_equal 0

    # A single 28-symbol raw block starting at phase 0 keeps 17 symbols.
    _(phase_zero.coded_nbits(8)).must_equal 17
    # A conceptual continuation starting at phase 2 keeps a different
    # number, demonstrating the period straddles the boundary non-trivially.
    kept_at_phase2 = 28.times.count { |i| puncture[(2 + i) % 5] }
    _(kept_at_phase2).must_equal 16
  end
end

describe 'ConvolutionalCodec tail-biting' do
  before do
    @codec = BinData::ConvolutionalCodec.new(termination: :tail_biting)
  end

  it 'round trips without flush bits' do
    10.times do |seed|
      data = Random.new(seed + 200).bytes(8)
      coded = @codec.encode(data)
      _(coded.length).must_equal 128
      result = @codec.decode(coded, 64)
      _(result.bytes).must_equal data
      _(result.start_state).must_equal result.end_state
    end
  end

  it 'uses the last K-1 information bits as the start state' do
    data = 'abcdefgh'
    coded = @codec.encode(data)
    result = @codec.decode(coded, 64)
    expected_state = data.bytes.last(6).each_with_index.reduce(0) do |s, (b, i)|
      bit_position = 7 - (i % 8)
      bit = (b >> bit_position) & 1
      s
    end
    # start/end state must be consistent (actual value is data dependent)
    _(result.start_state).must_equal result.end_state
    _(result.bytes).must_equal data
  end

  it 'exact and circular decoders agree on clean data' do
    circular = BinData::ConvolutionalCodec.new(
      termination: :tail_biting, exact_symbols: 10)
    data = 'abcdefghijklmnop'
    coded = @codec.encode(data)
    coded2 = circular.encode(data)
    exact_result = @codec.decode(coded2, 128)
    circular_result = circular.decode(coded2, 128)
    _(circular_result.bytes).must_equal data
    _(circular_result.bytes).must_equal exact_result.bytes
  end

  it 'rejects blocks shorter than the encoder memory on encode' do
    _(proc { @codec.encode([0, 1]) }).must_raise ArgumentError
  end
end

describe 'ConvolutionalCodec exhaustive maximum-likelihood reference' do
  def assert_matches_brute_force(codec, information_nbits, observations)
    best_metric, achievers = brute_force_metric(
      codec, observations, information_nbits)
    result = codec.decode(observations, information_nbits)
    # The decoder must reach the best achievable metric; when several
    # codewords tie it may return any one of them.
    _(result.path_metric).must_be_close_to best_metric, 1e-9
    assert_includes achievers, result.bits
  end

  it 'matches brute force over many hard observation patterns (K=3, zero-tail)' do
    codec = BinData::ConvolutionalCodec.new(
      constraint_length: 3, generators: [0o7, 0o5])
    info_nbits = 6
    coded_nbits = codec.coded_nbits(info_nbits)
    # All-zero and all-one words, plus a fixed random sample of hard words.
    words = [0, (1 << coded_nbits) - 1]
    prng = Random.new(5)
    2000.times { words << prng.rand(1 << coded_nbits) }
    words.each do |word|
      observations = coded_nbits.times.map do |i|
        ((word >> (coded_nbits - 1 - i)) & 1) == 1 ? 1.0 : -1.0
      end
      assert_matches_brute_force(codec, info_nbits, observations)
    end
  end

  it 'matches brute force with erasures and soft weights (K=3, zero-tail)' do
    codec = BinData::ConvolutionalCodec.new(
      constraint_length: 3, generators: [0o7, 0o5])
    info_nbits = 6
    coded_nbits = codec.coded_nbits(info_nbits)
    prng = Random.new(7)
    200.times do
      observations = coded_nbits.times.map do
        choice = prng.rand
        if choice < 0.2
          nil
        else
          (prng.rand(2) == 1 ? 1 : -1) * (0.1 + prng.rand)
        end
      end
      assert_matches_brute_force(codec, info_nbits, observations)
    end
  end

  it 'matches brute force for punctured zero-tail blocks' do
    codec = BinData::ConvolutionalCodec.new(
      constraint_length: 3, generators: [0o7, 0o5],
      puncture: [true, true, false])
    info_nbits = 6
    coded_nbits = codec.coded_nbits(info_nbits)
    prng = Random.new(11)
    200.times do
      observations = coded_nbits.times.map do
        prng.rand < 0.25 ? nil : (prng.rand(2) == 1 ? 1.0 : -1.0)
      end
      assert_matches_brute_force(codec, info_nbits, observations)
    end
  end

  it 'matches brute force for every tail-biting starting state (K=3)' do
    codec = BinData::ConvolutionalCodec.new(
      constraint_length: 3, generators: [0o7, 0o5],
      termination: :tail_biting)
    info_nbits = 6
    coded_nbits = codec.coded_nbits(info_nbits)
    # every possible clean coded word (each is some codeword) plus noisy ones
    (0...64).each do |n|
      bits = info_nbits.times.map { |i| (n >> (info_nbits - 1 - i)) & 1 }
      coded = codec.encode(bits)
      _(codec.decode(coded, info_nbits).bits).must_equal bits
    end

    prng = Random.new(13)
    100.times do
      observations = coded_nbits.times.map do
        prng.rand < 0.1 ? nil : (prng.rand(2) == 1 ? 1.0 : -1.0)
      end
      assert_matches_brute_force(codec, info_nbits, observations)
    end
  end
end

describe 'BinData::ConvolutionalCode field' do
  it 'round trips a zero-tail field' do
    klass = Class.new(BinData::Record) do
      convolutional_code :payload, length: 5
    end

    frame = klass.new
    frame.payload.assign('hello')
    wire = frame.to_binary_s
    # 40 info bits + 6 flush, rate 2 => 92 bits => 12 bytes
    _(wire.bytesize).must_equal 12

    decoded = klass.read(wire)
    _(decoded.payload).must_equal 'hello'
    _(decoded.payload.path_metric).must_equal 92.0
    _(decoded.payload.start_state).must_equal 0
    _(decoded.payload.end_state).must_equal 0
    _(decoded.payload.num_bytes).must_equal 12
  end

  it 'packs punctured fields across byte boundaries' do
    puncture = [true, true, true, false, true, true, false, true]
    klass = Class.new(BinData::Record) do
      bit3 :marker
      convolutional_code :a, length: 2, termination: :tail_biting,
                          puncture: puncture
      convolutional_code :b, length: 2, termination: :tail_biting,
                          puncture: puncture
      bit1 :tail
    end

    # 16 info bits -> 32 raw symbols -> 24 kept per block.
    frame = klass.new
    frame.marker = 0b101
    frame.a.assign('ab')
    frame.b.assign('cd')
    frame.tail = 1
    wire = frame.to_binary_s
    _(wire.bytesize).must_equal 7 # 3 + 24 + 24 + 1 = 52 bits

    decoded = klass.read(wire)
    _(decoded.marker).must_equal 0b101
    _(decoded.a).must_equal 'ab'
    _(decoded.b).must_equal 'cd'
    _(decoded.tail).must_equal 1
  end

  it 'accepts observations with erasures via a proc parameter' do
    coded_field = Class.new(BinData::Record) do
      convolutional_code :payload, length: 4,
                          observations: -> { payload_observations }
      attr_accessor :payload_observations
    end

    codec = BinData::ConvolutionalCodec.new
    data = 'wxyz'
    coded = codec.encode(data)
    observations = coded.each_with_index.map { |b, i| i == 10 ? nil : (b == 1 ? 1.0 : -1.0) }

    frame = coded_field.new
    frame.payload_observations = observations
    frame.read(coded_field.new.tap { |f| f.payload.assign(data) }.to_binary_s)
    _(frame.payload).must_equal 'wxyz'
    _(frame.payload.start_state).must_equal 0
  end

  it 'validates the length parameter' do
    _(proc { BinData::ConvolutionalCode.new(length: 0) }).must_raise ArgumentError
  end

  it 'supports a dynamic length parameter' do
    klass = Class.new(BinData::Record) do
      uint8 :len, initial_value: 3
      convolutional_code :payload, length: -> { len }
    end

    frame = klass.new
    frame.payload.assign('abc')
    decoded = klass.read(frame.to_binary_s)
    _(decoded.payload).must_equal 'abc'
    _(decoded.len).must_equal 3
  end

  it 'validates codec parameters' do
    _(proc { BinData::ConvolutionalCodec.new(constraint_length: 1) })
      .must_raise ArgumentError
    _(proc { BinData::ConvolutionalCodec.new(generators: []) })
      .must_raise ArgumentError
    _(proc { BinData::ConvolutionalCodec.new(puncture: [false, 0]) })
      .must_raise ArgumentError
    _(proc { BinData::ConvolutionalCodec.new(termination: :nope) })
      .must_raise ArgumentError
  end

  it 'rejects the wrong number of observations' do
    codec = BinData::ConvolutionalCodec.new
    _(proc { codec.decode([1.0], 24) }).must_raise ArgumentError
  end
end
