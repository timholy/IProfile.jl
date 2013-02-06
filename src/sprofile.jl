module SProfile
require("Options")
using OptionsMod

## Wrap the C library
fnames = ["libprofile.so", "libprofile.dylib", "libprofile.dll"]
paths = [pwd(), joinpath(Pkg.dir(), "Profile", "deps")]
global libname
found = false
for path in paths
    if !found
        for fname in fnames
            libname = find_in_path(joinpath(path, fname))
            if isfile(libname)
                found = true
                break
            end
        end
    end
end
if !isfile(libname)
    error("Library cannot be found; it may not have been built correctly.\n Try include(\"build.jl\") from within the deps directory.")
end
const libprofile = libname

function sprofile_init(delay::Integer, nsamples::Integer)
    status = ccall((:sprofile_init, libprofile), Void, (Uint64, Uint), delay, nsamples)
    if status == -1
        error("Could not allocate space for ", nsamples, " profiling samples")
    end
end

sprofile_start_timer() = ccall((:sprofile_start_timer, libprofile), Int32, ())

sprofile_stop_timer() = ccall((:sprofile_stop_timer, libprofile), Void, ())

sprofile_get_data_pointer() = convert(Ptr{Uint}, ccall((:sprofile_get_data, libprofile), Ptr{Uint8}, ()))

sprofile_len_data() = convert(Int, ccall((:sprofile_len_data, libprofile), Uint, ()))

sprofile_maxlen_data() = convert(Int, ccall((:sprofile_maxlen_data, libprofile), Uint, ()))


sprofile_clear() = ccall((:sprofile_clear_data, libprofile), Void, ())

sprofile_parse(a::Vector{Uint}, doCframes::Bool) = ccall(:jl_parse_backtrace, Array{Any, 1}, (Ptr{Uint}, Uint, Int32), a, length(a), doCframes)

sprofile_parse(u::Uint, doCframes::Bool) = sprofile_parse([u], doCframes)

sprofile_error_codes = (Int=>ASCIIString)[
    -1=>"Cannot specify signal action for profiling",
    -2=>"Cannot create the timer for profiling",
    -3=>"Cannot start the timer for profiling"]

function sprofile_get()
    len = sprofile_len_data()
    maxlen = sprofile_maxlen_data()
    if (len == maxlen)
        warn("the profile data buffer is full; profiling probably terminated\nbefore your program finished. To profile for longer runs, call sprofile_init()\nwith a larger buffer and/or larger delay.")
    end
    pointer_to_array(sprofile_get_data_pointer(), (len,))
end


## Initialize the profile data structures
# Have the timer fire every 1ms = 10^6ns
const delay = 1_000_000
# Use a max size of 1M profile samples
const nsamples = 1_000_000
sprofile_init(delay, nsamples)

# Number of backtrace "steps" that are triggered by taking the backtrace, e.g., inside profile_bt
# May be platform-specific
const btskip = 2

## A simple linecount parser
function sprof_flat(doCframes::Bool)
    data = sprofile_get()
    linecount = (Uint=>Int)[]
    toskip = btskip
    for i = 1:length(data)
        if toskip > 0
            toskip -= 1
            continue
        end
        if data[i] == 0
            toskip = btskip
            continue
        end
        linecount[data[i]] = get(linecount, data[i], 0)+1
    end
    buf = Array(Uint, 0)
    n = Array(Int, 0)
    for (k,v) in linecount
        push!(buf, k)
        push!(n, v)
    end
    bt = Array(Vector{Any}, length(buf))
    for i = 1:length(buf)
        bt[i] = sprofile_parse(buf[i], doCframes)
    end
    # Keep only the interpretable ones
    keep = !Bool[isempty(x) for x in bt]
    n = n[keep]
    bt = bt[keep]
    bt, n
end

function sprofile_flat(io::Stream, opts::Options)
    @defaults opts doCframes=false mergelines=true
    bt, n = sprof_flat(doCframes)
    p = sprof_sortorder(bt)
    n = n[p]
    bt = bt[p]
    if mergelines
        j = 1
        for i = 2:length(bt)
            if bt[i] == bt[j]
                n[j] += n[i]
                n[i] = 0
            else
                j = i
            end
        end
        keep = n .> 0
        n = n[keep]
        bt = bt[keep]
    end
    if doCframes
        @printf(io, "%6s %20s %30s %12s\n", "Count", "File", "Function", "Line/offset")
    else
        @printf(io, "%6s %20s %30s %6s\n", "Count", "File", "Function", "Line")
    end
    for i = 1:length(n)
        if doCframes
            if isa(bt[i][3], Signed)
                @printf(io, "%6d %20s %30s %12d\n", n[i], truncto(string(bt[i][2]), 20), truncto(string(bt[i][1]), 30), bt[i][3])
            else
                @printf(io, "%6d %20s %30s %12x\n", n[i], truncto(string(bt[i][2]), 20), truncto(string(bt[i][1]), 30), bt[i][3])
            end
        else
            @printf(io, "%6d %20s %30s %6d\n", n[i], truncto(string(bt[i][2]), 20), truncto(string(bt[i][1]), 30), bt[i][3])
        end
    end
    @check_used opts
end
sprofile_flat(io::Stream) = sprofile_flat(io, Options())
sprofile_flat(doCframes::Bool) = sprofile_flat(OUTPUT_STREAM, Options(:doCframes, doCframes))
sprofile_flat(opts::Options) = sprofile_flat(OUTPUT_STREAM, opts)
sprofile_flat() = sprofile_flat(OUTPUT_STREAM, Options())

## A tree representation
function sprof_tree()
    data = sprofile_get()
    iz = find(data .== 0)
    treecount = (Vector{Uint}=>Int)[]
    istart = 1+btskip
    for iend in iz
        tmp = data[iend-1:-1:istart]
        treecount[tmp] = get(treecount, tmp, 0)+1
        istart = iend+1+btskip
    end
    bt = Array(Vector{Uint}, 0)
    counts = Array(Int, 0)
    for (k,v) in treecount
        push!(bt, k)
        push!(counts, v)
    end
    bt, counts
end

function sprof_treematch(bt::Vector{Vector{Uint}}, counts::Vector{Int}, pattern::Vector{Uint})
    l = length(pattern)
    n = length(counts)
    matched = falses(n)
    for i = 1:n
        k = bt[i]
        if length(k) >= l && k[1:l] == pattern
            matched[i] = true
        end
    end
    matched
end

sprof_tree_format_linewidth(x::Vector{Any}) = isempty(x) ? 0 : ndigits(x[3])+(isa(x[3],Signed) ? 6 : 11)
function minbytes(x::Uint)
    if x <= typemax(Uint8)
        return uint8(x)
    elseif x <= typemax(Uint16)
        return uint16(x)
    elseif x <= typemax(Uint32)
        return uint32(x)
    else
        return x
    end
end

function sprof_tree_format(infoa::Vector{Vector{Any}}, counts::Vector{Int}, level::Int, cols::Integer)
    nindent = min(ifloor(cols/2), level)
    ndigcounts = ndigits(max(counts))
    ndigline = max([sprof_tree_format_linewidth(x) for x in infoa])
    ntext = cols-nindent-ndigcounts-ndigline-5
    widthfile = ifloor(0.4ntext)
    widthfunc = ifloor(0.6ntext)
    strs = Array(ASCIIString, length(infoa))
    showextra = false
    if level > nindent
        nextra = level-nindent
        nindent -= ndigits(nextra)+2
        showextra = true
    end
    for i = 1:length(infoa)
        info = infoa[i]
        if !isempty(info)
            base = " "^nindent
            if showextra
                base = strcat(base, "+", nextra, " ")
            end
            base = strcat(base,
                          rpad(string(counts[i]), ndigcounts, " "),
                          " ",
                          truncto(string(info[2]), widthfile),
                          "; ",
                          truncto(string(info[1]), widthfunc),
                          "; ")
            if isa(info[3], Signed)
                strs[i] = strcat(base, "line: ", info[3])
            else
                strs[i] = strcat(base, "offset: ", minbytes(info[3]))
            end
        else
            strs[i] = ""
        end
    end
    strs
end
sprof_tree_format(infoa::Vector{Vector{Any}}, counts::Vector{Int}, level::Int) = sprof_tree_format(infoa, counts, level, tty_cols())

function sprofile_tree(io, bt::Vector{Vector{Uint}}, counts::Vector{Int}, level::Int, doCframes::Bool)
    umatched = falses(length(counts))
    len = Int[length(x) for x in bt]
    infoa = Array(Vector{Any}, 0)
    keepa = Array(BitArray, 0)
    n = Array(Int, 0)
    while !all(umatched)
        ind = findfirst(!umatched)
        pattern = bt[ind][1:level+1]
        matched = sprof_treematch(bt, counts, pattern)
        info = sprofile_parse(pattern[end], doCframes)
        push!(infoa, info)
        keep = matched & (len .> level+1)
        push!(keepa, keep)
        umatched |= matched
        push!(n, sum(counts[matched]))
    end
    p = sprof_sortorder(infoa)
    infoa = infoa[p]
    keepa = keepa[p]
    n = n[p]
    strs = sprof_tree_format(infoa, n, level)
    for i = 1:length(infoa)
        if !isempty(strs[i])
            println(io, strs[i])
        end
        keep = keepa[i]
        if any(keep)
            sprofile_tree(io, bt[keep], counts[keep], level+1, doCframes)
        end
    end
#     print("\n")
end

function sprofile_tree(io::Stream, doCframes::Bool)
    bt, counts = sprof_tree()
    level = 0
    len = Int[length(x) for x in bt]
    keep = len .> 0
    sprofile_tree(io, bt[keep], counts[keep], level, doCframes)
end
sprofile_tree(io::Stream) = sprofile_tree(io, false)
sprofile_tree(doCframes::Bool) = sprofile_tree(OUTPUT_STREAM, doCframes)
sprofile_tree() = sprofile_tree(OUTPUT_STREAM, false)

## Use this to profile code
macro sprofile(ex)
    quote
        try
            status = sprofile_start_timer()
            if status < 0
                error(sprofile_error_codes[status])
            end
            $(esc(ex))
        finally
            sprofile_stop_timer()
        end
    end
end

# Utilities
function truncto(str::ASCIIString, w::Int)
    ret = str;
    if length(str) > w
        ret = strcat("...", str[end-w+4:end])
    end
    ret
end

function sprof_sortorder(bt::Vector{Vector{Any}})
    comb = Array(ASCIIString, length(bt))
    for i = 1:length(bt)
        if !isempty(bt[i])
            comb[i] = @sprintf("%s:%s:%06d", bt[i][2], bt[i][1], bt[i][3])
        else
            comb[i] = "zzz"
        end
    end
    scomb, p = sortperm(comb)
    p
end

export @sprofile, sprofile_clear, sprofile_flat, sprofile_init, sprofile_tree

end # module
