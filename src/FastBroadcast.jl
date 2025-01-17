module FastBroadcast

export @..

using Base.Broadcast: Broadcasted
using LinearAlgebra: Adjoint, Transpose
using Static, Polyester

getstyle(::Type{Broadcasted{S,Axes,F,Args}}) where {S,Axes,F,Args} = S
getAxes(::Type{Broadcasted{S,Axes,F,Args}}) where {S,Axes,F,Args} = Axes
getF(::Type{Broadcasted{S,Axes,F,Args}}) where {S,Axes,F,Args} = F
getArgs(::Type{Broadcasted{S,Axes,F,Args}}) where {S,Axes,F,Args} = collect(Args.parameters)
getAxes(::Type{T}) where {T<:Tuple} = collect(T.parameters)

use_fast_broadcast(_) = false
use_fast_broadcast(::Type{<:Base.Broadcast.DefaultArrayStyle}) = true
use_fast_broadcast(::Type{<:Base.Broadcast.DefaultArrayStyle{0}}) = false

@inline function fast_materialize(::SB, bc::Broadcasted{S}) where {S, SB}
    if use_fast_broadcast(S)
        fast_materialize!(SB(), similar(bc, Base.Broadcast.combine_eltypes(bc.f, bc.args)), bc)
    else
        Base.Broadcast.materialize(bc)
    end
end

@inline function fast_materialize!(::False, dst, bc::Broadcasted{S}) where S
    if use_fast_broadcast(S)
        fast_materialize!(dst, bc, axes(dst), _get_axes(bc), _index_style(bc))
    else
        Base.Broadcast.materialize!(dst, bc)
    end
end

@generated function fast_materialize!(dst, bc::Broadcasted, dstaxes::Tuple{Vararg{Any,N}}, ax, indexstyle) where {N}
    loopbody_lin = :($setindex!(dst))
    loopbody_car = :($setindex!(dst))
    loopbody_slow = :($setindex!(dst))
    bcc = BroadcastCharacteristics()
    ii = map(i->Symbol(:i_, i), 1:N)

    walk_bc!(
        bcc, loopbody_lin, loopbody_car, loopbody_slow,
        ii, bc, :bc, ax, :ax
       )
    push!(loopbody_lin.args, :i)
    append!(loopbody_car.args, ii)
    append!(loopbody_slow.args, ii)
    loop_quote = if !(bcc.maybelinear && (indexstyle === IndexLinear))
        :(@inbounds Base.Cartesian.@nloops $N i dst begin
            $loopbody_car
        end)
    elseif bcc.maybeivdep
        :(@inbounds @simd ivdep for i in $eachindex(dst)
            $loopbody_lin
        end)
    else
        :(@inbounds @simd for i in $eachindex(dst)
            $loopbody_lin
        end)
    end
    quote
        $(Expr(:meta,:inline))
        isfast = true
        (Base.Cartesian.@ntuple $N dstaxis) = dstaxes
        $(bcc.loopheader)
        if isfast
            $loop_quote
        else
            Base.Cartesian.@nloops $N i dst begin
                $loopbody_slow
            end
        end
        dst
    end
end

_view(A::AbstractArray{<:Any,N}, r, ::Val{N}) where {N} = view(A, ntuple(_ -> :, N-1)..., r)
_view(A::AbstractArray, r, ::Val) = A
_view(x, r, ::Val) = x
__view(t::Tuple{T}, r, ::Val{N}) where {T,N} = (_view(first(t), r, Val(N)),)
__view(t::Tuple{T,Vararg}, r, ::Val{N}) where {T,N} = (_view(first(t), r, Val(N)), __view(Base.tail(t), r, Val(N))...)
function _view(bc::Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{N},Nothing}, r, ::Val{N}) where {N}
  Base.Broadcast.Broadcasted(bc.f, __view(bc.args, r, Val(N)), Val(N))
end
_view(bc::Base.Broadcast.Broadcasted{<:Base.Broadcast.DefaultArrayStyle}, r, ::Val{N}) where {N} = bc
_view(t::Tuple{Vararg{AbstractRange,N}}, r, ::Val{N}) where {N} = (Base.front(t)..., r)

function fast_materialize!(::True, dst, bc::Broadcasted{S}) where S
    if use_fast_broadcast(S)
        fast_materialize_threaded!(dst, bc, axes(dst))
    else
        Base.Broadcast.materialize!(dst, bc)
    end
end
function fast_materialize_threaded!(dst, bc::Broadcasted, dstaxes::Tuple{Vararg{Any,N}}) where {N}
    last_dstaxes = dstaxes[N]
    Polyester.batch(
        (length(last_dstaxes), Threads.nthreads()), dst, last_dstaxes, bc, Val(N)
    ) do (dest, ldstaxes, bcobj, VN), start, stop
        r = ldstaxes[start:stop]
        fast_materialize!(False(), _view(dest, r, VN), _view(bcobj, r, VN))
    end
    return dst
end


@inline _get_axes(x) = axes(x)
@inline _get_axes(bc::Broadcasted) = map(_get_axes, bc.args)
@inline __index_style(_) = Val{false}()
@inline __index_style(::IndexLinear) = Val{true}()

# Two arg `_index_style` checks, either stopping with `Val{false}()`, or continues
@inline _index_style(_, __) = IndexCartesian()
@inline _index_style(::IndexLinear, x) = _index_style(x)
@inline _index_style(::IndexLinear, x::Tuple{}) = IndexLinear()
@inline _index_style(::IndexLinear, x::Tuple{T}) where {T} = _index_style(first(x))
@inline _index_style(::IndexLinear, x::Tuple{T,S,Vararg}) where {T,S} = _index_style(_index_style(first(x)), Base.tail(x))

@inline _index_style(x) = IndexStyle(typeof(x)) # require `IndexStyle` to be defined
@inline _index_style(x::Tuple) = IndexLinear()
@inline _index_style(x::Number) = IndexLinear()
@inline _index_style(x::Ref) = IndexLinear()
@inline _index_style(x::AbstractArray) = IndexStyle(x)

@inline _index_style(bc::Broadcasted) = _index_style(_index_style(first(bc.args)), Base.tail(bc.args))

@generated function broadcastgetindex(A, i::Vararg{Int,N}) where {N}
  quote
    $(Expr(:meta,:inline))
    Base.Cartesian.@nref $N A n -> ifelse(size(A, n) == 1, firstindex(A, n), i[n])
  end
end

fast_materialize!(_, dest, x::Number) = fill!(dest, x)
fast_materialize!(_, dest, x::AbstractArray) = copyto!(dest, x)

safeivdep(_) = false
safeivdep(::Type{Array{T,N}}) where {T <: Union{Bool,Base.HWNumber},N} = true
safeivdep(::Type{Adjoint{T,Array{T,N}}}) where {T <: Union{Bool,Base.HWNumber}, N} = true
safeivdep(::Type{Transpose{T,Array{T,N}}}) where {T <: Union{Bool,Base.HWNumber}, N} = true
safeivdep(::Type{SubArray{T,N,Array{T,M}}}) where {T <: Union{Bool,Base.HWNumber}, N, M} = true

mutable struct BroadcastCharacteristics
    loopheader::Expr
    arrays::Vector{Symbol}
    maybelinear::Bool
    maybeivdep::Bool
end
BroadcastCharacteristics() = BroadcastCharacteristics(Expr(:block), Symbol[], true, true)

_tuplelen(::Type{T}) where {N,T<:Tuple{Vararg{Any,N}}} = N

function walk_bc!(
        bcc::BroadcastCharacteristics, loopbody_lin, loopbody_car, loopbody_slow,
        ii, bc::Type{<:Broadcasted}, bcsym, ax::Type{<:Tuple}, axsym
       )
    f = gensym(:f)
    push!(bcc.loopheader.args, :($f = $bcsym.f))
    new_loopbody_lin = Expr(:call, f)
    new_loopbody_car = Expr(:call, f)
    new_loopbody_slow = Expr(:call, f)
    args = getArgs(bc)
    axs  = getAxes(ax)
    push!(loopbody_lin.args, new_loopbody_lin)
    push!(loopbody_car.args, new_loopbody_car)
    push!(loopbody_slow.args, new_loopbody_slow)
    for (i, arg) in enumerate(args)
        if arg <: Broadcasted
            new_bcsym = gensym(:bcsym); new_axsym = gensym(:axsym);
            push!(bcc.loopheader.args, :($new_bcsym = $bcsym.args[$i]))
            push!(bcc.loopheader.args, :($new_axsym = $axsym[$i]))
            walk_bc!(bcc, new_loopbody_lin, new_loopbody_car, new_loopbody_slow, ii, arg, new_bcsym, axs[i], new_axsym)
        else
            new_arg = gensym(:x)
            push!(bcc.loopheader.args, :($new_arg = $bcsym.args[$i]))
            nd::Int = length(ii)
            if (arg <: Adjoint{<:Any,<:AbstractVector}) || (arg <: Transpose{<:Any,<:AbstractVector})
                push!(bcc.arrays, new_arg)
                bcc.maybelinear = false
                new_arg_parent = Symbol(new_arg, "##parent##")
                push!(bcc.loopheader.args, :($new_arg_parent = parent($new_arg)))
                push!(bcc.loopheader.args, :(isfast &= axes($new_arg_parent,1) == dstaxis_2))
                index = :($new_arg_parent[$(ii[2])])
                slowindex = :(broadcastgetindex($new_arg_parent, $(ii[2])))
                if eltype(arg) <: Base.HWReal
                    nothing # `adjoint` and `transpose` are the identity
                elseif (arg <: Adjoint)
                    index = :(adjoint($index))
                    slowindex = :(adjoint($slowindex))
                else
                    index = :(transpose($index))
                    slowindex = :(transpose($slowindex))
                end
                push!(new_loopbody_car.args, index)
                push!(new_loopbody_slow.args, slowindex)
            elseif arg <: Tuple
                tuple_length = _tuplelen(arg)
                if tuple_length == 1
                  scalar = gensym(:scalar)
                  push!(bcc.loopheader.args, :($scalar = $new_arg[1]))
                  push!(new_loopbody_lin.args, scalar)
                  push!(new_loopbody_car.args, scalar)
                  push!(new_loopbody_slow.args, scalar)
                else
                  bcc.maybelinear &= nd == 1
                  push!(bcc.loopheader.args, :(isfast &= Base.OneTo($tuple_length) == dstaxis_1))
                  push!(new_loopbody_lin.args, :($new_arg[i]))
                  push!(new_loopbody_car.args, :($new_arg[i1]))
                  push!(new_loopbody_slow.args, :($new_arg[i1]))
                end
            else
                new_nd::Int = _tuplelen(axs[i]) # ndims on `arg` won't work because of possible world age errors.
                if new_nd == 0
                    scalar = gensym(:scalar)
                    push!(bcc.loopheader.args, :($scalar = $new_arg[]))
                    push!(new_loopbody_lin.args, scalar)
                    push!(new_loopbody_car.args, scalar)
                    push!(new_loopbody_slow.args, scalar)
                else
                    push!(bcc.arrays, new_arg)
                    bcc.maybelinear &= (nd == new_nd)
                    bcc.maybeivdep = bcc.maybeivdep && safeivdep(arg)
                    new_arg_axes = Symbol(new_arg, "#axes#")
                    push!(bcc.loopheader.args, :($new_arg_axes = $axsym[$i]))
                    push!(bcc.loopheader.args, :((Base.Cartesian.@ntuple $new_nd $new_arg_axes) = $new_arg_axes))
                    for n ∈ 1:new_nd
                        push!(bcc.loopheader.args, :(isfast &= $(Symbol(new_arg_axes,'_',n)) == $(Symbol(:dstaxis_,n))))
                    end
                    push!(new_loopbody_lin.args, :($new_arg[i]))
                    push!(new_loopbody_car.args, :($new_arg[$(ii[1:new_nd]...)]))
                    push!(new_loopbody_slow.args, :(broadcastgetindex($new_arg, $(ii[1:new_nd]...))))
                end
            end
        end
    end
    return nothing
end

function pushsymname!(ex::Expr, base::Symbol, @nospecialize(arg))
    if arg isa Core.SSAValue
        push!(ex.args, Symbol(base, '_', arg.id))
    elseif arg isa Core.SlotNumber
        push!(ex.args, Symbol(base, 's', arg.id))
    else
        push!(ex.args, arg)
    end
end
function _goto(base::Symbol, i::Int, sym::Symbol)
  Expr(:macrocall, sym, LineNumberNode(@__LINE__,Symbol(@__FILE__)), Symbol(base, "#label#", i))
end
goto(base::Symbol, i::Int) = _goto(base, i, Symbol("@goto"))
label(base::Symbol, i::Int) = _goto(base, i, Symbol("@label"))

function add_gotoifnot!(q::Expr, gotos::Vector{Int}, base::Symbol, cond, dest::Int)
    ex = Expr(:||)
    pushsymname!(ex, base, cond)
    push!(ex.args, goto(base, dest))
    push!(q.args, ex)
    push!(gotos, dest)
    nothing
end

function broadcast_codeinfo(ci, threadarg)
    q = Expr(:block)
    base = gensym(:fastbroadcast)
    gotos = Int[]
    for (i, code) ∈ enumerate(ci.code)
        k = findfirst(==(i), gotos)
        if k ≢ nothing
            push!(q.args, label(base, i))
        end
        if Meta.isexpr(code, :call)
            ex = Expr(:call)
            f = code.args[1]
            if f === GlobalRef(Base, :materialize)
                push!(ex.args, fast_materialize, threadarg)
            elseif f === GlobalRef(Base, :materialize!)
                push!(ex.args, fast_materialize!, threadarg)
            elseif f === GlobalRef(Base, :getindex)
                push!(ex.args, Base.Broadcast.dotview)
            else
                pushsymname!(ex, base, f)
            end
            for arg ∈ @view(code.args[2:end])
                pushsymname!(ex, base, arg)
            end
            push!(q.args, Expr(:(=), Symbol(base, '_', i), ex))
        elseif Meta.isexpr(code, :(=))
            ex = Expr(:(=), Symbol(base, 's', code.args[1].id))
            pushsymname!(ex, base, code.args[2])
            push!(q.args, ex)
        elseif VERSION ≥ v"1.6" && code isa Core.GotoIfNot
            add_gotoifnot!(q, gotos, base, code.cond, code.dest)
        elseif VERSION < v"1.6" && Meta.isexpr(code, :gotoifnot)
            add_gotoifnot!(q, gotos, base, code.args[1], code.args[2])
        elseif code isa Core.GotoNode
            push!(q.args, goto(base, code.label))
            push!(gotos, code.label)
        elseif !(VERSION ≥ v"1.6" ? isa(code, Core.ReturnNode) : Meta.isexpr(code, :return))
            ex = Expr(:(=), Symbol(base, '_', i))
            pushsymname!(ex, base, code)
            push!(q.args, ex)
        end
    end
    q
end

function fb_macro(ex, mod, threadarg)
    lowered = Meta.lower(mod, Base.Broadcast.__dot__(ex))
    lowered isa Expr || return esc(lowered)
    esc(broadcast_codeinfo(lowered.args[1], threadarg))
end

macro (..)(ex)
    fb_macro(ex, __module__, False())
end

macro (..)(kwarg, ex)
    @assert Meta.isexpr(kwarg, :(=), 2)
    @assert kwarg.args[1] === :thread
    threadarg = kwarg.args[2]
    if threadarg isa Bool
        threadarg = threadarg ? True() : False()
    end
    fb_macro(ex, __module__, threadarg)
end

end
