module TestShow
    using DataFrames
    df = DataFrame(A = 1:3, B = ["x", "y", "z"])

    io = IOBuffer()
    show(io, df)
    show(io, df, true)
    showall(io, df)
    showall(io, df, true)

    subdf = df[df[:A] .> 1.0, :]
    show(io, subdf)
    show(io, subdf, true)
    showall(io, subdf)
    showall(io, subdf, true)

    dfr = DataFrameRow(df, 1)
    show(io, dfr)

    df = DataFrame(A = Array(UTF8String, 3))
end
