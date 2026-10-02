#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))

RS = BinData::Transform::ReedSolomon

def erase_encoded_shards(encoded, erased_shards)
  header = encoded.byteslice(0, RS::HEADER_SIZE)
  data_shards = header.getbyte(6)
  parity_shards = header.getbyte(7)
  original_length = header.byteslice(9, 8).unpack1("Q>")
  shard_size = original_length.zero? ? 0 : (original_length + data_shards - 1) / data_shards

  surviving = String.new.force_encoding(Encoding::BINARY)
  (data_shards + parity_shards).times do |position|
    next if erased_shards.include?(position)
    surviving << encoded.byteslice(RS::HEADER_SIZE + position * shard_size, shard_size)
  end

  header + surviving
end

describe RS do
  it "uses an independent fixed coding vector" do
    encoded = RS.encode("\x01\x02\x03\x04".b, 2, 2)
    expected = "BDRS1\x01\x02\x02\x00\x00\x00\x00\x00\x00\x00\x00\x04".b +
               "\x01\x02\x03\x04\x8f\xf6\x7b\xf7".b

    _(encoded).must_equal expected
    0.upto(2) do |count|
      (0...4).to_a.combination(count) do |erased_shards|
        damaged = erase_encoded_shards(encoded, erased_shards)
        _(RS.decode(damaged, erased_shards)).must_equal_binary "\x01\x02\x03\x04".b
      end
    end
  end

  it "recovers every permitted erasure pattern for a small group" do
    [[1, 1], [1, 2], [2, 1], [2, 2], [3, 2], [3, 3], [4, 2]].each do |data_shards, parity_shards|
      0.upto(10) do |length|
        data = (1..length).map { |index| ((index * 37) ^ (index << 3)) & 0xff }.pack("C*")
        encoded = RS.encode(data, data_shards, parity_shards)

        0.upto(parity_shards) do |count|
          (0...(data_shards + parity_shards)).to_a.combination(count) do |erased_shards|
            damaged = erase_encoded_shards(encoded, erased_shards)
            _(RS.decode(damaged, erased_shards)).must_equal_binary data
          end
        end
      end
    end
  end

  it "reconstructs an empty data region" do
    encoded = RS.encode("".b, 3, 2)

    [[], [0], [2, 4]].each do |erased_shards|
      damaged = erase_encoded_shards(encoded, erased_shards)
      _(RS.decode(damaged, erased_shards)).must_equal_binary "".b
    end
  end

  it "does not return partial data when recovery capacity is exceeded" do
    encoded = RS.encode("abcdef", 2, 1)
    damaged = erase_encoded_shards(encoded, [0, 2])

    error = _(-> { RS.decode(damaged, [0, 2]) }).must_raise(RS::ErasureError)
    _(error.message).must_equal "2 erasures exceed recovery capacity of 1"
  end

  it "rejects an erasure position outside the coding group" do
    encoded = RS.encode("abc", 2, 1)

    _(-> { RS.decode(encoded, [3]) }).must_raise RS::ErasureError
  end

  it "rejects a truncated header and payload" do
    encoded = RS.encode("abcdef", 2, 1)

    _(-> { RS.decode(encoded.byteslice(0, 5), []) }).must_raise RS::FormatError
    _(-> { RS.decode(erase_encoded_shards(encoded, [2]).chop, [2]) }).must_raise RS::FormatError
  end

  it "rejects a reconstructed stream with an inconsistent short block flag" do
    encoded = RS.encode("xy", 2, 1)
    encoded.setbyte(8, encoded.getbyte(8) | RS::SHORT_FINAL_BLOCK)

    _(-> { RS.decode(encoded) }).must_raise RS::FormatError
  end

  it "works inside a Section with known erased blocks" do
    data = "systematic reed-solomon data"
    erased_shards = []
    transform = -> { RS.new(data_shards: 2, parity_shards: 2, erased_shards: erased_shards) }
    section = BinData::Section.new(transform: transform,
                                  type: [:string, read_length: data.bytesize])

    section.assign(data)
    encoded = section.to_binary_s
    erased_shards.replace([0, 3])
    damaged = erase_encoded_shards(encoded, [0, 3])

    recovered = BinData::Section.new(transform: transform,
                                     type: [:string, read_length: data.bytesize])
    _(recovered.read(damaged)).must_equal data
  end
end
