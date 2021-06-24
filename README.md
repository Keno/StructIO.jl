# StructIO

[![StructIO](http://pkg.julialang.org/badges/StructIO_0.6.svg)](http://pkg.julialang.org/?pkg=StructIO)
[![StructIO](http://pkg.julialang.org/badges/StructIO_0.7.svg)](http://pkg.julialang.org/?pkg=StructIO)
[![Build Status](https://travis-ci.org/Keno/StructIO.jl.svg?branch=master)](https://travis-ci.org/Keno/StructIO.jl)
[![Coverage](http://codecov.io/github/Keno/StructIO.jl/coverage.svg?branch=master)](http://codecov.io/github/Keno/StructIO.jl?branch=master)

Generates IO methods (`pack`, `unpack`) from structure definitions.  Also defines `packed_sizeof` to give the on-disk size of a packed structure, which is smaller than `sizeof` would give, if the struct is marked as `align_packed`.

# Example usage
```julia
julia> using StructIO

julia> @io struct TwoUInt64s
           x::UInt64
           y::UInt64
       end

julia> buf = IOBuffer(collect(UInt8(1):UInt8(16))); 

julia> seekstart(buf); unpack(buf, TwoUInt64s) # Default endianness depends on machine
TwoUInt64s(0x0807060504030201, 0x100f0e0d0c0b0a09)

julia> seekstart(buf); unpack(buf, TwoUInt64s, :BigEndian)
TwoUInt64s(0x0102030405060708, 0x090a0b0c0d0e0f10)

julia> @io struct H_default
                 char  ::  UInt8   # Default packing includes a padding byte inbetween fields here
                 short ::  UInt16
              end

julia> seekstart(buf); unpack(buf, H_default) # Notice byte 0x02 is not used
H_default(0x01, 0x0403)

julia> @io struct H_packed
                 char  ::  UInt8
                 short ::  UInt16
              end align_packed

julia> seekstart(buf); unpack(buf, H_packed) # Notice byte 0x02 is now used
H_packed(0x01, 0x0302)


```
