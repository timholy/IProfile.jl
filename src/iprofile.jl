module IProfile

PROFILE_LINES = 1
PROFILE_DESCEND = 2
PROFILE_STATE = PROFILE_LINES | PROFILE_DESCEND    # state is a bitfield

# Record of expressions to parse according to the current PROFILE_STATE
PROFILE_EXPR = {}

# To avoid the performance penalty of global variables, we design the
# macro to create local variables through a "let" block that shares
# the timing and count data with "reporting" and "clearing" functions.
PROFILE_REPORTS = {}  # list of reporting functions
PROFILE_CLEARS = {}   # list of clearing functions
PROFILE_TAGS = {}     # line #s for all timing variables

# Profile calibration, to compensate for the overhead of calling time()
PROFILE_CALIB = 0
# Do it inside a let block, just like in real profiling, in case of
# extra overhead
let # tlast::Uint64 = 0x0, tnow::Uint64 = 0x0
global profile_calib
function profile_calib(n_iter)
    trec = Array(Uint64, n_iter)
    for i = 1:n_iter
        tlast = time_ns()
        blast = Base.gc_bytes()
        tnow = time_ns()
        bnow = Base.gc_bytes()
        trec[i] = tnow - tlast
    end
    return trec
end
end
PROFILE_CALIB = min(profile_calib(100))

# Utilities
# Generic expression type testing
is_expr_head(ex::Expr, s::Symbol) = ex.head == s
is_expr_head(nonex, s::Symbol) = false

# Test whether an expression is a function declaration
function isfuncexpr(ex::LineNumberNode)
    return false
end
function isfuncexpr(ex::Expr)
    return ex.head == :function || (ex.head == :(=) && typeof(ex.args[1]) == Expr && ex.args[1].head == :call)
end

# Get the "full syntax" of the function call
function funcsyntax(ex::Expr)
    return ex.args[1]
end

# Get the symbol associated with the function call
function funcsym(ex::Expr)
    tmp = funcsyntax(ex)
    tmp = tmp.args[1]
    if is_expr_head(tmp, :curly)
        tmp = tmp.args[1]
    end
    return tmp
end

# Test for control-flow statements
#is_cf_expr(ex::Expr) = contains([:for, :while, :if, :try], ex.head)
is_cf_expr(ex::Expr) = in(ex.head, [:for, :while, :if, :try])
is_cf_expr(ex) = false

# General switchyard function
function insert_profile(ex::Expr, tlast, tnow, timers, blast, bnow, byters, counters, tags, indx::Int, retsym, rettest)
    if ex.head == :block
        insert_profile_block(ex, tlast, tnow, timers, blast, bnow, byters, counters, tags, indx, retsym, rettest)
    elseif is_cf_expr(ex)
        insert_profile_cf(ex, tlast, tnow, timers, blast, bnow, byters, counters, tags, indx, retsym)
    else
        error("Don't know what to do")
    end
end

# A variant for anything but an expression (a no-op).
insert_profile(notex, tlast, tnow, timers, blast, bnow, byters, counters, tags, indx::Int, retsym, rettest) = notex, indx

# Insert profiling statements into a code block
# rettest is a function with the following syntax:
#    rettest(Expr, Int)
# and evaluates to true if the return value of Expr needs to be saved
# before inserting profiling statements.
function insert_profile_block(fblock::Expr, tlast, tnow, timers, blast, bnow, byters, counters, tags, indx::Int, retsym, rettest)
    global PROFILE_STATE, PROFILE_DESCEND
    if fblock.head != :block
        println(fblock)
        error("expression is not a block")
    end
    descend = PROFILE_STATE & PROFILE_DESCEND > 0
    fblocknewargs = {}
    for i = 1:length(fblock.args)
        if isa(fblock.args[i],LineNumberNode) || is_expr_head(fblock.args[i], :line)
            # This is a line expression, so no counters/timers required
            push!(fblocknewargs,fblock.args[i])
             # ...but keep track of the line # for use during reporting
            lasttag = fblock.args[i]
        elseif descend && is_cf_expr(fblock.args[i])
            # This is a control-flow statement, it requires special
            # handling (recursive)
            cfnew, indx = insert_profile_cf(fblock.args[i], tlast, tnow, timers, blast, bnow, byters, counters, tags, indx, retsym)
            push!(fblocknewargs, cfnew)
        else
            # This is an "ordinary" statement
            saveret = rettest(fblock, i)
            push!(tags,lasttag)
            if saveret
                if is_expr_head(fblock.args[i], :return)
                    push!(fblocknewargs, :($retsym = $(fblock.args[i].args[1])))
                else
                    push!(fblocknewargs, :($retsym = $(fblock.args[i])))
                end
            else
                push!(fblocknewargs, fblock.args[i])
            end
            # This next line inserts timing statements between two
            # lines of code, equivalent to:
            #   timehr(PROFILE_USE_CLOCK, tnow)  # end time of prev
            #   timers[indx] += timehr_diff(tlast, tnow)
            #   counters[indx] += 1
            #   timehr(PROFILE_USE_CLOCK, tlast) # start time for next
            append!(fblocknewargs,{:($tnow = time_ns()), :($bnow = Base.gc_bytes()), :(($timers)[($indx)] += $tnow - $tlast),  :(($byters)[($indx)] += $bnow - $blast), :(($counters)[($indx)] += 1), :($tlast = time_ns()), :($blast = Base.gc_bytes())})
            indx += 1
            if saveret
                push!(fblocknewargs, :(return $retsym))
            end
        end
    end
    return Expr(:block, fblocknewargs...), indx
end

# Handling control-flow statements
function insert_profile_cf(ex::Expr, tlast, tnow, timers, blast, bnow, byters, counters, tags, indx::Int, retsym)
    rettest = (ex, i) -> is_expr_head(ex, :return)
    if length(ex.args) == 2
        # This is a for, while, or 2-argument if or try block
        block1, indx = insert_profile(ex.args[2], tlast, tnow, timers, blast, bnow, byters, counters, tags, indx, retsym, rettest)
        return Expr(ex.head, {ex.args[1], block1}...), indx
    elseif length(ex.args) == 3
        # This is for a 3-argument if or try block
        block1, indx = insert_profile(ex.args[2], tlast, tnow, timers, blast, bnow, byters, counters, tags, indx, retsym, rettest)
        block2, indx = insert_profile(ex.args[3], tlast, tnow, timers, blast, bnow, byters, counters, tags, indx, retsym, rettest)
        return Expr(ex.head, {ex.args[1], block1, block2}...), indx
    else
        error("Wrong number of arguments")
    end
end

# Insert timing and counters into function body.
# Function bodies differ from blocks in these respects:
#   - We need to initialize tlast
#   - The final statement of a function should be returned, even if there
#     is no explicit return statement
#   - Functions can be defined in "short-form" (e.g.,
#     "isempty(x) = numel(x)==0"), and the return value for these
#     needs to be managed, too
function insert_profile_function(ex::Expr, tlast, tnow, timers, blast, bnow, byters, counters, tags, indx::Int, retsym)
    fblock = ex.args[2]
    if fblock.head != :block
        error("Can't parse func expression")
    end
    # Prepare the test for whether we need to save the return value of
    # a given line of code.  We may need to store the return value
    # because we need to run timing operations after computing the
    # output.
    # For a function, this will be true in three cases:
    #   - For a "f1(x) = x+1" type of function declaration
    #   - For an explicit return statement
    #   - For the last line of a function that does not have
    #     an explicit return statement in it.
    if ex.head == :(=)
        # This is a short-form function declaration
        savefunc = (ex, i) -> true
    else
        # Long form, check to see if it's a return or the last line
        savefunc = (ex, i) -> i == length(fblock.args) || is_expr_head(ex, :return)
    end
    # Insert the profiling statements in the function
    fblocknewargs, indx = insert_profile_block(fblock, tlast, tnow, timers, blast, bnow, byters, counters, tags, indx, retsym, savefunc)
    # Prepend the initialization of tlast
    fblocknewargs = vcat({:($tlast = time_ns())}, {:($blast = Base.gc_bytes())}, fblocknewargs.args)
    return Expr(:function,{funcsyntax(ex),Expr(:block,fblocknewargs...)}...), indx
end

function profile_parse(ex::Expr)
    if PROFILE_STATE & PROFILE_LINES > 0
        # Create the "let" variables for timing and counting
        tlast = gensym()
        tnow = gensym()
        timers = gensym()
        blast = gensym()
        bnow = gensym()
        byters = gensym()
        counters = gensym()
        # Keep track of line numbers
        tags = {}
        # Preserve return values
        retsym = gensym()
        # Create the symbols used for reporting and clearing the data
        # for this block
        funcreport = gensym()
        funcclear = gensym()
        # Parse the block and insert instructions
        indx = 1
        coreargs = {}
        if ex.head == :block
            # This is a block which may contain many function declarations
            for i = 1:length(ex.args)
                if isfuncexpr(ex.args[i])
                    # Insert "global" statement for each function
                    push!(coreargs,Expr(:global,funcsym(ex.args[i])))
                    # Insert function-call counters
                    newfuncexpr, indx = insert_profile_function(ex.args[i], tlast, tnow, timers, blast, bnow, byters, counters, tags, indx, retsym)
                    push!(coreargs, newfuncexpr)
                else
                    push!(coreargs,ex.args[i])
                end
            end
        elseif isfuncexpr(ex)
            # This is a single function declaration
            push!(coreargs,Expr(:global,funcsym(ex)))
            newfuncexpr, indx = insert_profile_function(ex, tlast, tnow, timers, blast, bnow, byters, counters, tags, indx, retsym)
            push!(coreargs, newfuncexpr)
        else
            error("Could not parse expression")
        end
        n_lines = indx-1
        # Insert reporting function
        # Because we're using a gensym for the function name, we can't
        # quote the whole thing
        push!(coreargs, Expr(:global, funcreport))
        push!(coreargs, Expr(:function, {Expr(:call, {funcreport}...), Expr(:block,{:(return $timers, $byters, $counters)}...)}...))
        # Insert clearing function
        push!(coreargs, Expr(:global, funcclear))
        push!(coreargs, Expr(:function, {Expr(:call, {funcclear}...), Expr(:block,{:(fill!($timers,0)), :(fill!($byters,0)), :(fill!($counters,0))}...)}...))
        # Put all this inside a let block
        excore = Expr(:block,coreargs...)
        exlet = Expr(:let,{Expr(:block,excore), :($timers = zeros(Uint64, $n_lines)), :($byters = zeros(Uint64, $n_lines)), :($counters = zeros(Uint64, $n_lines))}...)
        # Export the reporting and clearing functions, in case we're inside a module
        exret = Expr(:toplevel, {esc(exlet), Expr(:export, {esc(funcclear), esc(funcreport)}...)}...)
        return exret, tags, funcreport, funcclear
    else
        return ex ,{}, :funcnoop, :funcnoop
    end
end

function funcnoop()
end

function profile_parse_all()
    empty!(PROFILE_REPORTS)
    empty!(PROFILE_CLEARS)
    empty!(PROFILE_TAGS)
    retargs = {}
    for i = 1:length(PROFILE_EXPR)
        newblock, tags, funcreport, funcclear = profile_parse(PROFILE_EXPR[i])
        retargs = vcat(retargs, newblock.args)
        if !isempty(tags)
            push!(PROFILE_TAGS, tags)
            push!(PROFILE_REPORTS, esc(funcreport))
            push!(PROFILE_CLEARS, esc(funcclear))
        end
    end
    push!(retargs,:(return nothing))
    return esc(Expr(:block,retargs...))
end

function profile_report()
    exret = cell(length(PROFILE_REPORTS)+2)
    ret = gensym()
    exret[1] = :($ret = {})
    for i = 1:length(PROFILE_REPORTS)
        exret[i+1] = :(push!($ret,$(Expr(:call,{PROFILE_REPORTS[i]}...))))
    end
    exret[end] = :(profile_print($ret))
    return Expr(:block,exret...)
end

compensated_time(t, c) = t >= c*PROFILE_CALIB ? t-c*PROFILE_CALIB : 0
show_unquoted(linex::Expr) = show_linenumber(linex.args...)
show_unquoted(lnn::LineNumberNode) = show_linenumber(lnn.line)
show_linenumber(line)       = string("\t#  line ",line)
show_linenumber(line, file) = string("\t#  ",file,", line ",line)

function profile_print(tc)
    # Compute total elapsed time
    ttotal = 0.0
    btotal = 0.0
    for i = 1:length(tc)
        timers = tc[i][1]
        byters = tc[i][2]
        counters = tc[i][3]
        for j = 1:length(counters)
            comp_time = compensated_time(timers[j], counters[j])
            ttotal += comp_time
            btotal += byters[j]
        end
    end
    # Display output
    for i = 1:length(tc)
        timers = tc[i][1]
        byters = tc[i][2]
        counters = tc[i][3]
        println("  count  time(%)   time(s) bytes(%) bytes(k)")
        for j = 1:length(counters)
            if counters[j] != 0
                comp_time = compensated_time(timers[j], counters[j])
                @printf("%8d  %5.2f  %9.6f  %5.2f  %8d  %s\n", counters[j],
                        100*(comp_time/ttotal),
                        comp_time*1e-9,
                        100*(byters[j]/btotal),
                        byters[j] / 1e3,
                        show_unquoted(PROFILE_TAGS[i][j]))
            end
        end
    end
end

function profile_clear()
    exret = cell(length(PROFILE_CLEARS)+1)
    for i = 1:length(PROFILE_CLEARS)
        exret[i] = Expr(:call,{PROFILE_CLEARS[i]}...)
    end
    exret[end] = :(return nothing)
    return Expr(:block,exret...)
end

macro iprofile(ex)
    global PROFILE_STATE
    if isa(ex,Symbol)
        # State changes
        if ex == :off
            PROFILE_STATE = 0
        elseif ex == :on
            PROFILE_STATE = PROFILE_LINES
        elseif ex == :reset
        elseif ex == :report
            return profile_report()
        elseif ex == :clear
            return profile_clear()
        else
            error("Profile mode not recognized")
        end
        return profile_parse_all()
    elseif isa(ex,Expr)
        push!(PROFILE_EXPR,ex)
        exret, tags, funcreport, funcclear = profile_parse(ex)
        if !isempty(tags)
            push!(PROFILE_TAGS, tags)
            push!(PROFILE_REPORTS, esc(funcreport))
            push!(PROFILE_CLEARS, esc(funcclear))
        end
        return exret
    end
end

export @iprofile

end # module Profile
