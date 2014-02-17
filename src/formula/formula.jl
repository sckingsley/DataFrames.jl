# Formulas for representing and working with linear-model-type expressions
# Original by Harlan D. Harris.  Later modifications by John Myles White
# and Douglas M. Bates.

## Formulas are written as expressions and parsed by the Julia parser.
## For example :(y ~ a + b + log(c))
## In Julia the & operator is used for an interaction.  What would be written
## in R as y ~ a + b + a:b is written :(y ~ a + b + a&b) in Julia.
## The equivalent R expression, y ~ a*b, is the same in Julia

## The lhs of a one-sided formula is 'nothing'
## The rhs of a formula can be 1

type Formula
    lhs::Union(Symbol, Expr, Nothing)
    rhs::Union(Symbol, Expr, Integer)
end

macro ~(lhs, rhs)
    ex = Expr(:call,
              :Formula,
              Base.Meta.quot(lhs),
              Base.Meta.quot(rhs))
    return ex
end

type Terms
    terms::Vector
    eterms::Vector        # evaluation terms
    factors::Matrix{Int8} # maps terms to evaluation terms
    order::Vector{Int}    # orders of rhs terms
    response::Bool        # indicator of a response, which is eterms[1] if present
    intercept::Bool       # is there an intercept column in the model matrix?
end

type ModelFrame
    df::AbstractDataFrame
    terms::Terms
    msng::BitArray
end

type ModelMatrix{T <: Union(Float32, Float64)}
    m::Matrix{T}
    assign::Vector{Int}
end

Base.size(mm::ModelMatrix) = size(mm.m)
Base.size(mm::ModelMatrix, dim...) = size(mm.m, dim...)

function Base.show(io::IO, f::Formula)
    print(io,
          string("Formula: ",
                 f.lhs == nothing ? "" : f.lhs, " ~ ", f.rhs))
end

## Return, as a vector of symbols, the names of all the variables in
## an expression or a formula
function allvars(ex::Expr)
    if ex.head != :call error("Non-call expression encountered") end
    [[allvars(a) for a in ex.args[2:end]]...]
end
allvars(f::Formula) = unique(vcat(allvars(f.rhs), allvars(f.lhs)))
allvars(sym::Symbol) = [sym]
allvars(v::Any) = Array(Symbol, 0)

# special operators in formulas
const specials = Set(:+, :-, :*, :/, :&, :|, :^)

function dospecials(ex::Expr)
    if ex.head != :call error("Non-call expression encountered") end
    a1 = ex.args[1]
    if !(a1 in specials) return ex end
    excp = copy(ex)
    excp.args = vcat(a1,map(dospecials, ex.args[2:end]))
    if a1 != :* return excp end
    aa = excp.args
    a2 = aa[2]
    a3 = aa[3]
    if length(aa) > 3
        excp.args = vcat(a1, aa[3:end])
        a3 = dospecials(excp)
    end
    :($a2 + $a3 + $a2 & $a3)
end
dospecials(a::Any) = a

const associative = Set(:+,:*,:&)       # associative special operators

## If the expression is a call to the function s return its arguments
## Otherwise return the expression
function ex_or_args(ex::Expr,s::Symbol)
    if ex.head != :call error("Non-call expression encountered") end
    excp = copy(ex)
    a1 = ex.args[1]
    a2 = map(condense, ex.args[2:end])
    if a1 == s return a2 end
    excp.args = vcat(a1, a2)
    excp
end
ex_or_args(a,s::Symbol) = a

## Condense calls like :(+(a,+(b,c))) to :(+(a,b,c))
## Also need to work out how to distribute & over +
function condense(ex::Expr)
    if ex.head != :call error("Non-call expression encountered") end
    a1 = ex.args[1]
    if !(a1 in associative) return ex end
    excp = copy(ex)
    excp.args = vcat(a1, map(x->ex_or_args(x,a1), ex.args[2:end])...)
    excp
end
condense(a::Any) = a

getterms(ex::Expr) = (ex.head == :call && ex.args[1] == :+) ? ex.args[2:end] : ex
getterms(a::Any) = a

ord(ex::Expr) = (ex.head == :call && ex.args[1] == :&) ? length(ex.args)-1 : 1
ord(a::Any) = 1

const nonevaluation = Set(:&,:|)        # operators constructed from other evaluations
## evaluation terms - the (filtered) arguments for :& and :|, otherwise the term itself
function evt(ex::Expr)
    if ex.head != :call error("Non-call expression encountered") end
    if !(ex.args[1] in nonevaluation) return ex end
    filter(x->!isa(x,Number), vcat(map(getterms, ex.args[2:end])...))
end
evt(a) = {a}

function Terms(f::Formula)
    rhs = condense(dospecials(f.rhs))
    tt = getterms(rhs)
    if !isa(tt,AbstractArray) tt = [tt] end
    tt = tt[!(tt .== 1)]             # drop any explicit 1's
    noint = (tt .== 0) | (tt .== -1) # should also handle :(-(expr,1))
    tt = tt[!noint]
    oo = int(map(ord, tt))           # orders of interaction terms
    if !issorted(oo)                 # sort terms by increasing order
        pp = sortperm(oo)
        tt = tt[pp]
        oo = oo[pp]
    end
    etrms = map(evt, tt)
    haslhs = f.lhs != nothing
    if haslhs
        unshift!(etrms, {f.lhs})
        unshift!(oo, 1)
    end
    ev = unique(vcat(etrms...))
    facs = int8(hcat(map(x->(s=Set(x...);map(t->int8(t in s), ev)),etrms)...))
    Terms(tt, ev, facs, oo, haslhs, !any(noint))
end

## Default NA handler.  Others can be added as keyword arguments
function na_omit(df::DataFrame)
    cc = complete_cases(df)
    df[cc,:], cc
end

## Trim the pool field of da to only those levels that occur in the refs
function dropUnusedLevels!(da::PooledDataArray)
    rr = da.refs
    uu = unique(rr)
    if length(uu) == length(da.pool) return da end
    T = eltype(rr)
    su = sort!(uu)
    dict = Dict(su, one(T):convert(T,length(uu)))
    da.refs = map(x->dict[x], rr)
    da.pool = da.pool[uu]
    da
end
dropUnusedLevels!(x) = x

function ModelFrame(f::Formula, d::AbstractDataFrame)
    trms = Terms(f)
    df, msng = na_omit(DataFrame(map(x -> d[x], trms.eterms)))
    names!(df, convert(Vector{Symbol}, map(string, trms.eterms)))
    for c in eachcol(df) dropUnusedLevels!(c[2]) end
    ModelFrame(df, trms, msng)
end
ModelFrame(ex::Expr, d::AbstractDataFrame) = ModelFrame(Formula(ex), d)

function model_response(mf::ModelFrame)
    mf.terms.response || error("Model formula one-sided")
    convert(Array, mf.df[bool(mf.terms.factors[:,1])][:,1])
end

function contr_treatment(n::Integer, contrasts::Bool, sparse::Bool, base::Integer)
    if n < 2 error("not enought degrees of freedom to define contrasts") end
    contr = sparse ? speye(n) : eye(n) .== 1.
    if !contrasts return contr end
    if !(1 <= base <= n) error("base = $base is not allowed for n = $n") end
    contr[:,vcat(1:(base-1),(base+1):end)]
end
contr_treatment(n::Integer,contrasts::Bool,sparse::Bool) = contr_treatment(n,contrasts,sparse,1)
contr_treatment(n::Integer,contrasts::Bool) = contr_treatment(n,contrasts,false,1)
contr_treatment(n::Integer) = contr_treatment(n,true,false,1)
cols(v::PooledDataVector) = contr_treatment(length(v.pool))[v.refs,:]
cols(v::DataVector) = reshape(float64(v.data), (length(v),1))

function isfe(ex::Expr)                 # true for fixed-effects terms
    if ex.head != :call error("Non-call expression encountered") end
    ex.args[1] != :|
end
isfe(a) = true

## Expand the columns in an interaction term
function expandcols(trm::Vector)
    if length(trm) == 1 return float64(trm[1]) end
    if length(trm) == 2
        a = float64(trm[1])
        b = float64(trm[2])
        nca = size(a,2)
        ncb = size(b,2)
        return hcat([a[:,i].*b[:,j] for i in 1:nca, j in 1:ncb]...)
    end
    error("code for 3rd and higher order interactions not yet written")
end

nc(trm::Vector) = *([size(x,2) for x in trm]...)

function ModelMatrix(mf::ModelFrame)
    trms = mf.terms
    aa = {{ones(size(mf.df,1),int(trms.intercept))}}
    asgn = zeros(Int, (int(trms.intercept)))
    fetrms = bool(map(isfe, trms.terms))
    if trms.response unshift!(fetrms,false) end
    ff = trms.factors[:,fetrms]
    ## need to be cautious here to avoid evaluating cols for a factor with many levels
    ## if the factor doesn't occur in the fetrms
    rows = vec(bool(sum(ff,[2])))
    ff = ff[rows,:]
    cc = [cols(x[2]) for x in eachcol(mf.df[:,rows])]
    for j in 1:size(ff,2)
        trm = cc[bool(ff[:,j])]
        push!(aa, trm)
        asgn = vcat(asgn, fill(j, nc(trm)))
    end
    ModelMatrix{Float64}(hcat([expandcols(t) for t in aa]...), asgn)
end

function coefnames(fr::ModelFrame)
    if fr.terms.intercept
        vnames = UTF8String["(Intercept)"]
    else
        vnames = UTF8String[]
    end
    # Need to only include active levels
    for term in fr.terms.terms
        if isa(fr.df[term], PooledDataArray)
            for lev in levels(fr.df[term])[2:end]
                push!(vnames, string(term, " - ", lev))
            end
        else
            push!(vnames, string(term))
        end
    end
    return vnames
end