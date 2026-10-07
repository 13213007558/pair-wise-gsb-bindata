#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))

describe BinData::RansSymbolBlock do
  let(:symbols) { [1, 0, 0, 0] }
  let(:frequencies) { [255, 1] }

  def write_block(**params)
    block = BinData::RansSymbolBlock.new(**params)
    block.assign(symbols)
    block.to_binary_s
  end

  it "writes and reads a single-state block with fixed byte output" do
    binary = write_block(frequencies: frequencies, quantization: :provided)

    _(binary).must_equal_binary(
      ["52414e310101020000000100000400000001000000ff838100ff00010004"].pack("H*")
    )

    block = BinData::RansSymbolBlock.read(binary)
    _(block).must_equal(symbols)
    _(block.layout).must_equal(1)
    _(block.quantization_rule).must_equal(0)
    _(block.frequency_sum).must_equal(256)
    _(block.encoded_final_states).must_equal([8_487_935])
    _(block.final_states).must_equal([8_388_608])
    _(block.payload).must_equal_binary "\x04"
  end

  it "writes and reads a two-state interleaved block" do
    binary = write_block(
      frequencies: frequencies,
      quantization: :provided,
      state_count: 2
    )

    _(binary).must_equal_binary(
      ["52414e310202020000000100000400000001000000ff80800081018100ff00010080"].pack("H*")
    )

    block = BinData::RansSymbolBlock.read(binary)
    _(block).must_equal(symbols)
    _(block.layout).must_equal(2)
    _(block.encoded_final_states).must_equal([8_421_631, 8_454_529])
    _(block.final_states).must_equal([8_388_608, 8_388_608])
    _(block.payload).must_equal_binary "\x80"
  end

  it "does not require decoder parameters" do
    binary = write_block(
      frequencies: frequencies,
      quantization: :provided,
      state_count: 3
    )

    _(BinData::RansSymbolBlock.read(binary)).must_equal(symbols)
  end

  it "stores multiple renormalization bytes in reverse emission order" do
    block = BinData::RansSymbolBlock.new(
      frequencies: frequencies,
      quantization: :provided,
      state_count: 2
    )
    repeated_symbols = [1, 0, 1, 0]
    block.assign(repeated_symbols)
    binary = block.to_binary_s
    decoded = BinData::RansSymbolBlock.read(binary)

    _(decoded.payload.bytes).must_equal([255, 0])
    _(decoded.encoded_final_states).must_equal([8_388_863, 8_454_529])
    _(decoded).must_equal(repeated_symbols)
  end

  it "stores the largest-remainder quantization rule in the block" do
    binary = write_block(frequencies: [765, 255])
    block = BinData::RansSymbolBlock.read(binary)

    _(block.quantization_rule).must_equal(1)
    _(block.encoded_frequencies).must_equal([192, 64])
    _(block.frequency_sum).must_equal(256)
    _(block).must_equal(symbols)
  end

  it "fails before writing when a symbol has zero frequency" do
    block = BinData::RansSymbolBlock.new(
      frequencies: [255, 1, 0],
      quantization: :provided
    )
    block.assign([0, 2])

    error = _(-> { block.to_binary_s }).must_raise(ArgumentError)
    _(error.message).must_equal("rANS symbol 2 has zero frequency")
  end

  it "fails before writing when a symbol is outside the alphabet" do
    block = BinData::RansSymbolBlock.new(
      frequencies: frequencies,
      quantization: :provided
    )
    block.assign([2])

    error = _(-> { block.to_binary_s }).must_raise(ArgumentError)
    _(error.message).must_equal("rANS symbol 2 has zero frequency")
  end

  it "restores the initial state after decoding" do
    binary = write_block(
      frequencies: [128, 128],
      quantization: :provided,
      state_count: 4
    )

    block = BinData::RansSymbolBlock.read(binary)
    _(block).must_equal(symbols)
    _(block.encoded_final_states).must_equal([16_777_344, 16_777_216,
                                              16_777_216, 16_777_216])
    _(block.final_states).must_equal([8_388_608] * 4)
  end

  it "fails when payload truncation prevents state restoration" do
    binary = write_block(frequencies: frequencies, quantization: :provided)
    truncated = binary.byteslice(0, binary.bytesize - 1)

    _(-> { BinData::RansSymbolBlock.read(truncated) }).must_raise(IOError)
  end

  it "fails when a final state is outside the declared range" do
    binary = write_block(frequencies: frequencies, quantization: :provided)
    corrupted = binary.dup
    corrupted.setbyte(23, 0xff)

    _(-> { BinData::RansSymbolBlock.read(corrupted) }).must_raise(
      BinData::ValidityError
    )
  end

  it "fails when the decoded frequency sum is unsupported" do
    binary = write_block(frequencies: frequencies, quantization: :provided)
    corrupted = binary.dup
    corrupted.setbyte(10, 0)
    corrupted.setbyte(11, 4)

    _(-> { BinData::RansSymbolBlock.read(corrupted) }).must_raise(
      BinData::ValidityError
    )
  end

  it "supports alphabets larger than 256 with a 65536 frequency sum" do
    large_symbols = [299, 0, 0, 0]
    frequencies = ::Array.new(300, 0)
    frequencies[0] = 65_535
    frequencies[299] = 1
    block = BinData::RansSymbolBlock.new(
      frequencies: frequencies,
      frequency_sum: 65_536,
      quantization: :provided,
      state_count: 2
    )
    block.assign(large_symbols)
    binary = block.to_binary_s
    block = BinData::RansSymbolBlock.read(binary)

    _(block.frequency_sum).must_equal(65_536)
    _(block.encoded_frequencies.length).must_equal(300)
    _(block).must_equal(large_symbols)
  end

  it "supports an empty symbol block" do
    binary = write_block(frequencies: frequencies, quantization: :provided)
    block = BinData::RansSymbolBlock.new(
      frequencies: frequencies,
      quantization: :provided
    )
    block.assign([])
    empty = block.to_binary_s

    _(BinData::RansSymbolBlock.read(empty)).must_equal([])
    _(empty.bytesize).wont_equal(binary.bytesize)
  end

  it "fails for an unknown frequency sum" do
    block = BinData::RansSymbolBlock.new(
      frequencies: frequencies,
      frequency_sum: 1024,
      quantization: :provided
    )
    block.assign(symbols)

    _(-> { block.to_binary_s }).must_raise(ArgumentError)
  end
end
