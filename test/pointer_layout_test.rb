#!/usr/bin/env ruby

require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))

class PointerSharedNode < BinData::Record
  endian :little

  uint32 :tag
  pointer :link, type: :pointer_shared_node, offset_base: :relative,
                    target_align: 4
end

class PointerSharedIndex < BinData::Record
  endian :little

  pointer :head, type: :pointer_shared_node, target_align: 4
  pointer :tail, type: :pointer_shared_node, target_align: 4
  uint32 :link_relative_to_root
end

class PointerAlignedIndex < BinData::Record
  endian :little

  pointer :head, type: :pointer_shared_node, target_align: 8
  pointer :tail, type: :pointer_shared_node, target_align: 16
  uint32 :link_relative_to_root
end

class PointerSelfNode < BinData::Record
  endian :little

  uint32 :tag
  pointer :link, type: :pointer_self_node, offset_base: :relative,
                    target_align: 4
end

class PointerSelfIndex < BinData::Record
  endian :little

  pointer :head, type: :pointer_self_node, target_align: 8
end

class PointerShortIndex < BinData::Record
  endian :little

  pointer :head, type: :uint16, offset_size: 16,
                    target_align: 4
end

class PointerBadIndex < BinData::Record
  endian :little

  pointer :head, type: :pointer_self_node, target_align: 4
end

FIXTURE_DIR = File.expand_path("fixtures/pointer_layout", __dir__)

def fixture_path(name)
  File.join(FIXTURE_DIR, name)
end

def fixture_bytes(name)
  File.binread(fixture_path(name))
end

describe BinData::Layout, "shared target fixture" do
  let(:data) { fixture_bytes("shared_target.bin") }
  let(:obj) { PointerSharedIndex.read(data) }

  it "returns the same object for duplicate pointers" do
    _(obj.head.target).must_be_same_as obj.tail.target
  end

  it "reads a relative pointer from the containing structure" do
    target = obj.head.target
    _(target.tag).must_equal 65
    _(target.link).must_equal 0
  end

  it "shares the root target for a self relative offset" do
    _(obj.head.target.link.target).must_be_same_as obj.head.target
  end

  it "rewrites the same offsets and layout" do
    _(obj.to_layout_binary_s).must_equal_binary data
  end
end

describe BinData::Layout, "self loop fixture" do
  let(:data) { fixture_bytes("self_loop.bin") }
  let(:obj) { PointerSelfIndex.read(data) }

  it "resolves a target pointing back to itself" do
    _(obj.head.target.tag).must_equal 7
    _(obj.head.target.link.target).must_be_same_as obj.head.target
  end

  it "rewrites the absolute and relative offsets" do
    _(obj.to_layout_binary_s).must_equal_binary data
  end
end

describe BinData::Layout, "out of bounds fixture" do
  let(:data) { fixture_bytes("out_of_bounds_pointer.bin") }
  let(:obj) { PointerBadIndex.read(data) }

  it "reports an invalid pointer address and rewrites it unchanged" do
    _ { obj.head.target }.must_raise BinData::ValidityError
    _(obj.to_layout_binary_s).must_equal_binary data
  end
end

describe BinData::Layout, "new object graphs" do
  it "writes a shared target once at an aligned offset" do
    target = PointerSharedNode.new(tag: 42, link: { tag: 0 })
    target.link.target = target
    obj = PointerSharedIndex.new(head: target, tail: target,
                                link_relative_to_root: 0)

    binary = obj.to_layout_binary_s
    written = PointerSharedIndex.read(binary)

    _(binary).must_equal_binary [
      12, 0, 0, 0,
      12, 0, 0, 0,
      0, 0, 0, 0,
      42, 0, 0, 0,
      0, 0, 0, 0
    ].pack("C*")
    _(written.head.target).must_be_same_as written.tail.target
    _(written.head.target.link.target).must_be_same_as written.head.target
  end

  it "uses the strictest alignment required by references" do
    target = PointerSharedNode.new(tag: 42)
    target.link.target = target
    obj = PointerAlignedIndex.new(head: target, tail: target,
                                  link_relative_to_root: 0)

    _(obj.to_layout_binary_s).must_equal_binary [
      16, 0, 0, 0,
      16, 0, 0, 0,
      0, 0, 0, 0,
      0, 0, 0, 0,
      42, 0, 0, 0,
      0, 0, 0, 0
    ].pack("C*")
  end

  it "supports narrower pointer offsets" do
    target = BinData::Uint16le.new(8)
    obj = PointerShortIndex.new(head: target)

    _(obj.head.num_bytes).must_equal 2
    _(obj.to_layout_binary_s).must_equal_binary [
      4, 0,
      0, 0,
      8, 0
    ].pack("C*")
  end

  it "writes a self loop created outside the root" do
    target = PointerSelfNode.new(tag: 7)
    target.link.target = target
    obj = PointerSelfIndex.new(head: target)

    _(obj.to_layout_binary_s).must_equal_binary fixture_bytes("self_loop.bin")
  end

  it "keeps an out of bounds pointer when rewriting a fixed file" do
    obj = PointerBadIndex.read(fixture_bytes("out_of_bounds_pointer.bin"))
    _(obj.head.target_for_layout).must_be_nil
    _ { obj.head.target }.must_raise BinData::ValidityError
    _(obj.to_layout_binary_s).must_equal_binary fixture_bytes("out_of_bounds_pointer.bin")
  end
end
