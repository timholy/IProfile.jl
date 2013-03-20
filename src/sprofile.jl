module SProfile

## Wrap the C library
fnames = ["libprofile.so", "libprofile.dylib", "libprofile.dll"]
paths = [pwd(), joinpath(Pkg.dir(), "Profile", "deps")]
global libname
found = false
for path in paths
    if !found
        for fname in fnames
            libname = Base.find_in_path(joinpath(path, fname))
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

function sprofile_init(nsamples::Integer, delay::Integer)
    status = ccall((:sprofile_init, libprofile), Cint, (Uint64, Uint), nsamples, delay)
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

function sprofile_lookup(ip::Uint, doCframes::Bool)
    info = ccall(:jl_lookup_code_address, Any, (Ptr{Void}, Bool), ip, doCframes)
    if length(info) == 3
        return string(info[1]), string(info[2]), info[3]
    else
        return info
    end
end

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
# Use a max size of 1M profile samples
const nsamples = 1_000_000
# Have the timer fire every 1ms = 10^6ns
const delay = 1_000_000
sprofile_init(nsamples, delay)

# Number of backtrace "steps" that are triggered by taking the backtrace, e.g., inside profile_bt
# May be platform-specific
const btskip = 2

## A simple linecount parser
function sprofile_parse_flat(doCframes::Bool)
    data = sprofile_get()
    linecount = (Uint=>Int)[]
    toskip = btskip
    for ip in data
        if toskip > 0
            toskip -= 1
            continue
        end
        if ip == 0
            toskip = btskip
            continue
        end
        linecount[ip] = get(linecount, ip, 0)+1
    end
    # Extract dict as arrays
    buf = Array(Uint, 0)
    n = Array(Int, 0)
    for (k,v) in linecount
        push!(buf, k)
        push!(n, v)
    end
    # Convert instruction pointers to names & line numbers
    bt = Array(Any, length(buf))
    for i = 1:length(buf)
        bt[i] = sprofile_lookup(buf[i], doCframes)
    end
    # Keep only the interpretable ones
    # The ones with no line number might appear multiple times in a single
    # capture, giving the wrong impression about the total number of captures.
    # Delete them too.
    keep = !Bool[isempty(x) || x[3] == 0 for x in bt]
    n = n[keep]
    bt = bt[keep]
    bt, n
end

function sprofile_flat(io::IO, doCframes::Bool, mergelines::Bool, cols::Int)
    bt, n = sprofile_parse_flat(doCframes)
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
    wcounts = max(6, ndigits(max(n)))
    maxline = 0
    maxfile = 0
    maxfun = 0
    for thisbt in bt
        maxline = max(maxline, thisbt[3])
        maxfile = max(maxfile, length(thisbt[2]))
        maxfun = max(maxfun, length(thisbt[1]))
    end
    wline = max(12, ndigits(maxline))
    ntext = cols - wcounts - wline - 3
    if maxfile+maxfun <= ntext
        wfile = maxfile
        wfun = maxfun
    else
        wfile = ifloor(2*ntext/5)
        wfun = ifloor(3*ntext/5)
    end
    println(io, lpad("Count", wcounts, " "), " ", rpad("File", wfile, " "), " ", rpad("Function", wfun, " "), " ", lpad("Line/offset", wline, " "))
    for i = 1:length(n)
        thisbt = bt[i]
        println(io, lpad(string(n[i]), wcounts, " "), " ", rpad(truncto(thisbt[2], wfile), wfile, " "), " ", rpad(truncto(thisbt[1], wfun), wfun, " "), " ", lpad(string(thisbt[3]), wline, " "))
    end
end
sprofile_flat(io::IO) = sprofile_flat(io, false, true, tty_cols())
sprofile_flat() = sprofile_flat(OUTPUT_STREAM)
sprofile_flat(doCframes::Bool, mergelines::Bool) = sprofile_flat(OUTPUT_STREAM, doCframes,  mergelines, tty_cols())
sprofile_flat(doCframes::Bool) = sprofile_flat(OUTPUT_STREAM, doCframes,  true, tty_cols())

## A tree representation
# Identify and counts repetitions of all unique captures
function sprof_tree()
    data = sprofile_get()
    iz = find(data .== 0)  # find the breaks between captures
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

sprof_tree_format_linewidth(x) = isempty(x) ? 0 : ndigits(x[3])+6

function sprof_tree_format(infoa::Vector{Any}, counts::Vector{Int}, level::Int, cols::Integer)
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
                base = string(base, "+", nextra, " ")
            end
            base = string(base,
                          rpad(string(counts[i]), ndigcounts, " "),
                          " ",
                          truncto(string(info[2]), widthfile),
                          "; ",
                          truncto(string(info[1]), widthfunc),
                          "; ")
            strs[i] = string(base, "line: ", info[3])
        else
            strs[i] = ""
        end
    end
    strs
end
sprof_tree_format(infoa::Vector{Any}, counts::Vector{Int}, level::Int) = sprof_tree_format(infoa, counts, level, tty_cols())

# Print a "branch" starting at a particular level. This gets called recursively.
function sprofile_tree(io, bt::Vector{Vector{Uint}}, counts::Vector{Int}, level::Int, doCframes::Bool, mergelines::Bool)
    # Organize captures into groups that are identical up to this level
    d = Dict{Any, Vector{Int}}()
    local key
    for i = 1:length(bt)
        thisbt = bt[i][level+1]
        if mergelines
            key = sprofile_lookup(thisbt, doCframes)
        else
            key = thisbt
        end
        indx = Base.ht_keyindex(d, key)
        if indx == -1
            d[key] = [i]
        else
            push!(d.vals[indx], i)
        end
    end
    # Generate the counts and code lookups (if we don't already have them)
    infoa = Array(Any, length(d))
    group = Array(Vector{Int}, length(d))
    n = Array(Int, length(d))
    i = 1
    for (k,v) in d
        if mergelines
            infoa[i] = k
        else
            infoa[i] = sprofile_lookup(k, doCframes)
        end
        group[i] = v
        n[i] = sum(counts[v])
        i += 1
    end
    # Order them
    p = sprof_sortorder(infoa)
    infoa = infoa[p]
    group = group[p]
    n = n[p]
    # Generate the string for each line
    strs = sprof_tree_format(infoa, n, level)
    # Recurse to the next level
    len = Int[length(x) for x in bt]
    for i = 1:length(infoa)
        if !isempty(strs[i])
            println(io, strs[i])
        end
        idx = group[i]
        keep = len[idx] .> level+1
        if any(keep)
            idx = idx[keep]
            sprofile_tree(io, bt[idx], counts[idx], level+1, doCframes, mergelines)
        end
    end
end

function sprofile_tree(io::IO, doCframes::Bool, mergelines::Bool)
    bt, counts = sprof_tree()
    level = 0
    len = Int[length(x) for x in bt]
    keep = len .> 0
    sprofile_tree(io, bt[keep], counts[keep], level, doCframes, mergelines)
end
sprofile_tree(io::IO) = sprofile_tree(io, false, true)
sprofile_tree(doCframes::Bool, mergelines::Bool) = sprofile_tree(OUTPUT_STREAM, doCframes, mergelines)
sprofile_tree(doCframes::Bool) = sprofile_tree(OUTPUT_STREAM, doCframes, true)
sprofile_tree() = sprofile_tree(OUTPUT_STREAM)

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
        ret = string("...", str[end-w+4:end])
    end
    ret
end

# Order alphabetically (file, function) and then by line number
function sprof_sortorder(bt::Vector{Any})
    comb = Array(ASCIIString, length(bt))
    for i = 1:length(bt)
        thisbt = bt[i]
        if !isempty(thisbt)
            comb[i] = @sprintf("%s:%s:%06d", thisbt[2], thisbt[1], thisbt[3])
        else
            comb[i] = "zzz"
        end
    end
    sortperm(comb)
end

export @sprofile, sprofile_clear, sprofile_flat, sprofile_init, sprofile_tree

end # module
