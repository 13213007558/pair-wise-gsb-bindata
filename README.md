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

# Convolutional coded telemetry

`ConvolutionalCode` stores a rate 1/n convolutional code (the default is
the CCSDS K=7, 0o171/0o133 telemetry code).  The wire value is the coded
bit stream; the Ruby value is the decoded information bytes.  Zero-tail and
tail-biting termination, puncturing, and hard or soft (reliability weighted)
observations are supported.  Missing observations may be passed as `nil` and
are treated as erasures, never as definite zeros.

```ruby
class Frame < BinData::Record
  bit3 :marker
  convolutional_code :payload, length: 16,
                      termination: :tail_biting,
                      puncture: [1,1,1,0,1,1,0,1]
end

frame = Frame.read(io)
frame.payload              #=> decoded String
frame.payload.path_metric  #=> Viterbi path metric
frame.payload.start_state  #=> starting trellis state
frame.payload.end_state    #=> ending trellis state
```

The codec is also usable without BinData records:

```ruby
codec = BinData::ConvolutionalCodec.new(termination: :tail_biting)
coded = codec.encode('hello')
result = codec.decode(soft_observations, 40)
result.bytes       #=> "hello"
```

# Installation

    $ gem install bindata

# Documentation

[BinData manual](http://github.com/dmendel/bindata/wiki).

# Contact

If you have any queries / bug reports / suggestions, please contact me
(Dion Mendel) via email at bindata@dmau.org
