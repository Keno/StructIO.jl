__precompile__()
module StructIO

using Base: @pure
using Base.Meta
export @io, unpack, pack, fix_endian, packed_sizeof

"""
    needs_bswap(endianness::Symbol)

Returns `true` if the given endianness does not match the current host system.
"""
@pure function needs_bswap(endianness::Symbol)
    if ENDIAN_BOM == 0x01020304
        return endianness == :LittleEndian
    else
        return endianness == :BigEndian
    end
end

"""
    bswap!(ptr::Ptr{UInt8}, sz)

Byte-swap a chunk of data in-place
"""
function bswap!(ptr::Ptr{UInt8}, sz)
    # Count from outside edge to middle
    for i = 0:div(sz-1,2)
        # Swap two mirrored bytes
        ptr_hi = ptr + sz - i - 1
        ptr_lo = ptr + i
        val_hi = unsafe_load(ptr_hi)
        val_lo = unsafe_load(ptr_lo)
        unsafe_store!(ptr_hi, val_lo)
        unsafe_store!(ptr_lo, val_hi)
    end
end

"""
    fix_endian(x, endianness::Symbol)

Returns a byte-swapped version of `x` if the given endianness must be swapped
for the current host system.
"""
@pure function fix_endian(x, endianness::Symbol)
    if needs_bswap(endianness)
        return bswap(x)
    end
    return x
end

# Alignment traits
abstract type PackingStrategy end
struct Packed <: PackingStrategy; end
struct Default <: PackingStrategy; end

"""
    packing_strategy(x)

Return the packing strategy for the given type, defaults to `Default`, is
overridden by auto-generated methods for specific types from `@io` invocations.
"""
function packing_strategy(x)
    return Default
end

# Sizeof computation
@pure function packed_sizeof(T::DataType, ::Type{Default})
    return Core.sizeof(T)
end

@pure function packed_sizeof(T::DataType, ::Type{Packed})
    @assert fieldcount(T) != 0 && isbitstype(T)
    return sum(packed_sizeof, T.types)
end

@pure function packed_sizeof(T::DataType)
    if fieldcount(T) == 0
        return packed_sizeof(T, Default)
    else
        return packed_sizeof(T, packing_strategy(T))
    end
end

"""
    fieldsize(T::DataType, field_idx)

Return the size (in bytes) of a field within `T` in memory
"""
@pure function fieldsize(T::DataType, field_idx)
    @assert fieldcount(T) != 0 && isbitstype(T)
    @assert field_idx <= fieldcount(T)

    # We figure out the (padded) size of the given field by looking at the
    # offset of the next field (if it exists) or just the overall size of the
    # parent
    offset = fieldoffset(T, field_idx)
    if field_idx == fieldcount(T)
        # If there are no further fields, use the total size of the object
        return Core.sizeof(T) - offset
    else
        # If there are fields, diff this one with the next
        return fieldoffset(T, field_idx + 1) - offset
    end
end


"""
    @io <type definition>
        ...
    end

Generates `packing_strategy()` and `packed_sizeof()` methods for the type being
defined within the given type definition.  This enables usage of the `unpack`
method.
"""
macro io(typ, annotations...)
    alignment = :align_default
    if length(annotations) == 1
        ann = annotations[1]
        if isa(ann, Symbol) || haskey(alignments, ann)
            alignment = ann
        end
    end
    
    # Get typename, collapsing type expressions until we get the actual type
    T = typ.args[2]
    if isexpr(T, :(<:))
        T = T.args[1]
    end
    if isexpr(T, :curly)
        T = T.args[1]
    end

    ret = Expr(:toplevel, :(Base.@__doc__ $(typ)))
    strat = (alignment == :align_default ? StructIO.Default : StructIO.Packed)
    push!(ret.args, :(StructIO.packing_strategy(::Type{T}) where {T <: $T} = $strat))
    return esc(ret)
end

"""
    unsafe_unpack(io, T, target, endianness, ::Type{Default})

Unpack an object of type `T` from `io` into `target`, byte-swapping if
`endianness` dictates we should, assuming a `Default` packing strategy.  All
packed structs recurse until bitstypes objects are eventually reached, at which
point `Default` packing is the only behavior.
"""
function unsafe_unpack(io, ::Type{T}, target, endianness, ::Type{Default}) where {T}
    sz = Core.sizeof(T)

    if !needs_bswap(endianness)
        # If we don't need to bswap, just read directly into `target`
        unsafe_read(io, target, sz)
    elseif fieldcount(T) == 0
        # If this is a primitive data type, unpack it directly and bswap()
        unsafe_read(io, target, sz)

        # Special case small sizes, LLVM should turn this into a jump table
        if sz == 1
        elseif sz == 2
            ptr = Base.unsafe_convert(Ptr{T}, target)
            unsafe_store!(ptr, bswap(unsafe_load(ptr)))
        elseif sz == 4
            ptr = Base.unsafe_convert(Ptr{T}, target)
            unsafe_store!(ptr, bswap(unsafe_load(ptr)))
        elseif sz == 8
            ptr = Base.unsafe_convert(Ptr{T}, target)
            unsafe_store!(ptr, bswap(unsafe_load(ptr)))
        else
            # Otherwise, for large primitive objects, fall back to our
            # `bswap!()` method which will swap in-place
            void_ptr = Base.unsafe_convert(Ptr{Cvoid}, target)
            bswap!(Base.unsafe_convert(Ptr{UInt8}, void_ptr), sz)
        end
    else
        # If we need to bswap, but it's not a primitive type, recurse!
        target_ptr = Base.unsafe_convert(Ptr{Cvoid}, target)
        for i = 1:fieldcount(T)
            # Unpack this field into `target` at the appropriate offset
            fT = fieldtype(T, i)
            target_i = target_ptr + fieldoffset(T, i)

            # Unpack from this point in the IOStream into this field
            unsafe_unpack(io, fT, target_i, endianness, Default)

            # If bytes_read != Core.sizeof(fT), move it on forward
            skip(io, fieldsize(T, i) - Core.sizeof(fT))
        end
    end
end

"""
    unsafe_pack(io, source, endianness, ::Type{Packed/Default})

Pack `source` into `io`, byte-swapping if `endianness` dictates we should.  The
last argument is a packing strategy, used to determine the layout of the data
in memory.  All `Packed` objects recurse until bitstypes objects are eventually
reached, at which point `Default` packing is identical to `Packed` behavior.
"""
function unsafe_pack(io, source::Ref{T}, endianness, ::Type{Default}) where {T}
    sz = packed_sizeof(T)
    if !needs_bswap(endianness)
        # If we don't need to bswap, just write directly from `source`
        unsafe_write(io, source, sz)
    elseif fieldcount(T) == 0
        # Hopefully, LLVM turns this into a jump list for us
        @GC.preserve source if sz == 1
            write(io, source[])
        elseif sz == 2
            ptr = Base.unsafe_convert(Ptr{T}, source)
            write(io, bswap(unsafe_load(ptr)))
        elseif sz == 4
            ptr = Base.unsafe_convert(Ptr{T}, source)
            write(io, bswap(unsafe_load(ptr)))
        elseif sz == 8
            ptr = Base.unsafe_convert(Ptr{T}, source)
            write(io, bswap(unsafe_load(ptr)))
        else
            # If we must bswap something of unknown size, copy first so as
            # to not clobber `source`, then bswap, then write
            source_copy = Ref{T}(copy(source[]))
            @GC.preserve source_copy begin
                void_ptr = Base.unsafe_convert(Ptr{Cvoid}, source_copy)
                ptr = Base.unsafe_convert(Ptr{UInt8}, void_ptr)
                bswap!(ptr, sz)
                unsafe_write(io, ptr, sz)
            end
        end
    else
        # If we need to bswap, but it's not a primitive type, recurse!
        for i = 1:fieldcount(T)
            # Pack field `i` into `io`
            f = getfield(source, fieldname(source, i))
            unsafe_pack(io, f, endianness, Default)
        end
    end
end

# `Packed` packing strategy override for `unsafe_unpack`
function unsafe_unpack(io, T, target, endianness, ::Type{Packed})
    # If this type cannot be subdivided, packing strategy means nothing, so
    # hand it off to the `Default` packing strategy method
    if fieldcount(T) == 0
        return unsafe_unpack(io, T, target, endianness, Default)
    end

    # Otherwise, iterate over the fields, unpacking each into `target`
    target_ptr = Base.unsafe_convert(Ptr{Cvoid}, target)
    for i = 1:fieldcount(T)
        # Unpack this field into `target` at the appropriate offset
        fT = fieldtype(T, i)
        target_i = target_ptr + fieldoffset(T, i)
        unsafe_unpack(io, fT, target_i, endianness, Packed)
    end
end

# `Packed` packing strategy override for `unsafe_pack`
function unsafe_pack(io, source::Ref{T}, endianness, ::Type{Packed}) where {T}
    # If this type cannot be subdivided, packing strategy means nothing, so
    # hand it off to the `Default` packing strategy method
    if fieldcount(T) == 0
        return unsafe_pack(io, source, endianness, Default)
    end

    # Otherwise, iterate over the fields, packing each into `io`
    for i = 1:fieldcount(T)
        # Unpack this field into `target` at the appropriate offset
        fT = fieldtype(T, i)
        f = Ref{fT}(getfield(source[], fieldname(T, i)))
        unsafe_pack(io, f, endianness, Packed)
    end
end

"""
    unpack(io::IO, T::Type, endianness::Symbol = :NativeEndian)

Given an input `io`, unpack type `T`, byte-swapping according to the given
`endianness` of `io`. If `endianness` is `:NativeEndian` (the default), no
byteswapping will occur.  If `endianness` is `:LittleEndian` or `:BigEndian`,
byteswapping will occur of the endianness if the host system does not match
the endianness of `io`.
"""
function unpack(io::IO, T::Type, endianness::Symbol = :NativeEndian)
    # Create a `Ref{}` pointing to type T, we'll unpack into that
    r = Ref{T}()
    packstrat = fieldcount(T) == 0 ? Default : packing_strategy(T)
    unsafe_unpack(io, T, r, endianness, packstrat)

    # De-reference `r` and return its unpacked contents
    return r[]
end

"""
    pack(io::IO, source, endianness::Symbol = :NativeEndian)

Given an input `source`, pack it into `io`, byte-swapping according to the
given `endianness` of `io`. If `endianness` is `:NativeEndian` (the default),
no byteswapping will occur.  If `endianness` is `:LittleEndian` or
`:BigEndian`, byteswapping will occur if the endianness of the host system
does not match the endianness of `io`.
"""
function pack(io::IO, source::T, endianness::Symbol = :NativeEndian) where {T}
    r = Ref{T}(source)
    packstrat = fieldcount(T) == 0 ? Default : packing_strategy(T)
    unsafe_pack(io, r, endianness, packstrat)
    return nothing
end

end # module
