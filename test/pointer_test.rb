require File.expand_path(File.join(File.dirname(__FILE__), "test_helper"))

describe BinData::Pointer do
  fixture_dir = File.expand_path("fixtures/pointer", __dir__)

  class PointerNode < BinData::Record
    endian :little

    uint16 :val
    pointer :link,
            type: :pointer_node,
            align: 2,
            pointer_type: :int32le,
            offset_base: :relative
  end

  class AbsolutePointerNode < BinData::Record
    endian :little

    uint16 :val
    pointer :link, type: :absolute_pointer_node, align: 2
  end

  class RelativePointerNode < BinData::Record
    endian :little

    pointer :back,
            type: :pointer_node,
            align: 2,
            pointer_type: :int32le,
            offset_base: :relative
  end

  class SmallNode < BinData::Record
    endian :little

    uint16 :val
  end

  class BlockPointerLayout < BinData::Layout
    endian :little

    pointer :node, type: :small_node, align: 2 do
      uint16le
    end
  end

  class SharedTargetLayout < BinData::Layout
    endian :little

    pointer :one,   type: :absolute_pointer_node, align: 4
    pointer :two,   type: :absolute_pointer_node, align: 4
  end

  class SelfLoopLayout < BinData::Layout
    endian :little

    pointer :node, type: :pointer_node, align: 4
  end

  class OutOfBoundsLayout < BinData::Layout
    endian :little

    pointer :node, type: :pointer_node, align: 4
    pointer :ignored, type: :pointer_node
  end

  describe "shared target fixture" do
    let(:data) { File.binread(File.join(fixture_dir, "shared_target.bin")) }
    let(:layout) { SharedTargetLayout.read(data) }

    it "maps equal addresses and types to one object" do
      assert_same(layout.one.target, layout.two.target)
      assert_equal(7, layout.one.target.val)
    end

    it "caches independently for different target types" do
      different_type = Class.new(BinData::Layout) do
        endian :little
        pointer :one, type: :absolute_pointer_node
        pointer :two, type: :small_node
      end.read(data)

      refute_same(different_type.one.target, different_type.two.target)
    end

    it "preserves offsets and rewrite" do
      assert_equal(8, layout.one.offset)
      assert_equal(8, layout.two.offset)
      assert_equal(8, layout.one.target.link.offset)
      assert_equal(14, layout.num_bytes)
      assert_equal data, layout.to_binary_s
    end

    it "allocates aligned shared targets once when writing" do
      node = AbsolutePointerNode.new(val: 7)
      node.link.target = node
      written = SharedTargetLayout.new(one: node, two: node)

      assert_equal data, written.to_binary_s
    end
  end

  describe "self-loop fixture" do
    let(:data) { File.binread(File.join(fixture_dir, "self_loop.bin")) }
    let(:layout) { SelfLoopLayout.read(data) }

    it "resolves the cycle without recursion" do
      assert_same(layout.node.target, layout.node.target.link.target)
      assert_equal(9, layout.node.target.val)
    end

    it "uses the enclosing structure as relative pointer base" do
      assert_equal(4, layout.node.offset)
      assert_equal(0, layout.node.target.link.offset)
      assert_equal(4, layout.node.target.abs_offset)
      assert_equal(0, layout.node.target.link.target.abs_offset - layout.node.target.abs_offset)
    end

    it "rewrites the same aligned layout" do
      node = PointerNode.new(val: 9)
      node.link.target = node
      written = SelfLoopLayout.new(node: node)

      assert_equal data, written.to_binary_s
      assert_equal data, layout.to_binary_s
    end
  end

  describe "out-of-bounds fixture" do
    let(:data) { File.binread(File.join(fixture_dir, "out_of_bounds.bin")) }

    it "raises when resolving the pointer target" do
      assert_raises(EOFError) do
        OutOfBoundsLayout.read(data)
      end
    end
  end

  describe "alignment" do
    it "rejects a pointer whose target is misaligned" do
      data = "\x01\x00\x00\x00"
      layout_class = Class.new(BinData::Layout) do
        endian :little
        pointer :node, type: :pointer_node, align: 4
      end

      assert_raises(BinData::ValidityError) do
        layout_class.read(data)
      end
    end
  end

  describe "declaration" do
    it "accepts the pointer storage type as a DSL block" do
      node = SmallNode.new(val: 5)
      layout = BlockPointerLayout.new(node: node)

      assert_equal "\x02\x00\x05\x00", layout.to_binary_s
    end

    it "accepts relative offsets as an offset alias" do
      layout_class = Class.new(BinData::Layout) do
        endian :little
        pointer :node, type: :small_node, offset: :relative
      end
      layout = layout_class.new(node: SmallNode.new(val: 2))

      assert_equal "\x04\x00\x00\x00\x02\x00", layout.to_binary_s
    end

    it "accepts the boolean relative flag" do
      layout_class = Class.new(BinData::Layout) do
        endian :little
        pointer :node, type: :small_node, relative_offset: true
      end
      layout = layout_class.new(node: SmallNode.new(val: 2))

      assert_equal "\x04\x00\x00\x00\x02\x00", layout.to_binary_s
    end
  end
end
