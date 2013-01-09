module SProfile

## Wrap the C library
fnames = ["libprofile.so", "libprofile.dylib", "libprofile.dll"]
paths = [pwd(), joinpath(julia_pkgdir(), "Profile", "src")]
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
    error("Library cannot be found. Did you build it?\n  Try include(\"postinstall.jl\") from within the src directory.")
end
const libprofile = libname

function profile_init(delay::Integer, nsamples::Integer)
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
        warn("the profile data buffer is full; profiling probably terminated\nbefore your program finished. To profile for longer runs, call profile_init()\nwith a larger buffer and/or larger delay.")
    end
    pointer_to_array(sprofile_get_data_pointer(), (len,))
end


## Initialize the profile data structures
# Have the timer fire every 1ms = 10^6ns
const delay = 1_000_000
# Use a max size of 1M profile samples
const nsamples = 1_000_000
profile_init(delay, nsamples)


## A simple linecount parser
function sprof_flat(doCframes::Bool)
    data = sprofile_get()
    linecount = (Uint=>Int)[]
    for i = 1:length(data)
        if data[i] == 0
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
    bt = Array(Any, length(buf))
    for i = 1:length(buf)
        bt[i] = sprofile_parse(buf[i], doCframes)
    end
    # Keep only the interpretable ones
    keep = !Bool[isempty(x) for x in bt]
    n = n[keep]
    bt = bt[keep]
    bt, n
end

function sprofile_flat(doCframes::Bool)
    bn, n = sprof_flat(doCframes)
    # Sort
    comb = Array(ASCIIString, length(n))
    for i = 1:length(n)
        comb[i] = @sprintf("%s:%s:%06d", bt[i][2], bt[i][1], bt[i][3])
    end
    scomb, p = sortperm(comb)
    n = n[p]
    bt = bt[p]
    @printf("%6s %20s %30s %6s\n", "Count", "File", "Function", "Line")
    for i = 1:length(n)
        @printf("%6d %20s %30s %6d\n", n[i], truncto(string(bt[i][2]), 20), bt[i][1], bt[i][3])
    end
end
sprofile_flat() = sprofile_flat(false)

## A tree representation
function sprof_tree()
    data = sprofile_get()
    iz = find(data .== 0)
    treecount = (Vector{Uint}=>Int)[]
    istart = 1
    for iend in iz
        tmp = data[iend-1:-1:istart]
        treecount[tmp] = get(treecount, tmp, 0)+1
        istart = iend+1
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

function sprofile_tree(bt::Vector{Vector{Uint}}, counts::Vector{Int}, level::Int, doCframes::Bool)
    umatched = falses(length(counts))
    len = Int[length(x) for x in bt]
#     if any(len .< level)
#         error("level is ", level, " and len = ", len)
#     end
    while !all(umatched)
        ind = findfirst(!umatched)
        pattern = bt[ind][1:level+1]
        matched = sprof_treematch(bt, counts, pattern)
        n = sum(counts[matched])
        info = sprofile_parse(pattern[end], doCframes)
        if !isempty(info)
            if isa(info[3], Signed)
                @printf("%s%d %s; %s; line: %d\n", "  "^level, n, truncto(string(info[2]), 20), info[1], info[3])
            else
                @printf("%s%d %s; %s; offset: %x\n", "  "^level, n, truncto(string(info[2]), 20), info[1], info[3])
            end
        end
        keep = matched & (len .> level+1)
        if any(keep)
            sprofile_tree(bt[keep], counts[keep], level+1, doCframes)
        end
        umatched |= matched
    end
#     print("\n")
end

function sprofile_tree(doCframes::Bool)
    bt, counts = sprof_tree()
    level = 0
    len = Int[length(x) for x in bt]
    keep = len .> 0
    sprofile_tree(bt[keep], counts[keep], level, doCframes)
end
sprofile_tree() = sprofile_tree(false)

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

function truncto(str::ASCIIString, w::Int)
    ret = str;
    if strlen(str) > w
        ret = strcat("...", str[end-16:end])
    end
    ret
end

export @sprofile, sprofile_clear, sprofile_flat, sprofile_init, sprofile_tree

end # module