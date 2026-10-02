# What is BinData?

[![Github CI](https://github.com/dmendel/bindata/actions/workflows/ci.yml/badge.svg)](https://github.com/dmendel/bindata/actions/workflows/ci.yml)
[![Version](https://img.shields.io/gem/v/bindata.svg)](https://rubygems.org/gems/bindata)
[![Downloads](https://img.shields.io/gem/dt/bindata.svg)](https://rubygems.org/gems/bindata)
[![Coverage](https://img.shields.io/coveralls/dmendel/bindata.svg)](https://coveralls.io/r/dmendel/bindata)

Do you ever find yourself writing code like this?

```ruby
io = File.open(...)
len = io.read(2).unpack("v")
name = io.read(len)
width, height = io.read(8).unpack("VV")
puts "Rectangle #{name} is #{width} x #{height}"
```

It’s ugly, violates DRY and doesn't feel like Ruby.

There is a better way. Here’s how you’d write the above using BinData.

```ruby
class Rectangle < BinData::Record
  endian :little
  uint16 :len
  string :name, :read_length => :len
  uint32 :width
  uint32 :height
end

io = File.open(...)
r  = Rectangle.read(io)
puts "Rectangle #{r.name} is #{r.width} x #{r.height}"
```

BinData provides a _declarative_ way to read and write structured binary data.

This means the programmer specifies *what* the format of the binary
data is, and BinData works out *how* to read and write data in this
format.  It is an easier (and more readable) alternative to
Ruby's `#pack` and `#unpack` methods.

BinData makes it easy to create new data types. It supports all the common
primitive datatypes that are found in structured binary data formats. Support
for dependent and variable length fields is built in. 

# Checksums

A primitive field can calculate or verify a checksum. The caller supplies the
algorithm, which receives the actual bytes serialized for the named field
ranges.

```ruby
class Message < BinData::Record
  endian :little

  uint32 :header_checksum,
         checksum: { range: :payload,
                     algorithm: ->(bytes) { Zlib.crc32(bytes) } }
  string :payload, length: 3
  uint32 :message_checksum,
         checksum: { range: [:header_checksum, :payload],
                     algorithm: ->(bytes) { Zlib.crc32(bytes) } }
end
```

A single field, a pair of fields defining an inclusive range, or an array of
those can be passed as `range`. Fields are resolved using the bytes actually
produced by nested structures and dynamic arrays. Checksum fields covered by
their own range must explicitly choose `self: :exclude` or supply a fixed
filler value. Writes topologically order checksum dependencies; reads raise
`BinData::ValidityError`, including the field and mismatching range. True
cyclic checksum dependencies are rejected.

# Installation

    $ gem install bindata

# Documentation

[BinData manual](http://github.com/dmendel/bindata/wiki).

# Contact

If you have any queries / bug reports / suggestions, please contact me
(Dion Mendel) via email at bindata@dmau.org
