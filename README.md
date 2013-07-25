# Profile.jl

This package contains profiling tools for the [Julia][Julia] language. Profilers
are mainly used for code optimization, particularly to find bottlenecks.

This package implements two [types of profilers][wp], an "instrumenting"
profiler and a "sampling" (statistical) profiler.

### Instrumenting profiler

The instrumenting profiler provides detailed information, including the number
of times each line gets executed and the total run time spent on that line.
However, the instrumenting profiler requires that your code be (automatically)
modified, by encapsulating it in "@iprofile begin...end". It also has a
significant performance cost.

### Sampling profiler

The sampling profiler works by periodically taking a backtrace during the execution of any
task. Each backtrace captures the the currently-running function and line number, plus the complete chain of function calls that led to this line, and hence is a "snapshot" of the current state of execution.
If you find that a particular line appears frequently in the set of backtraces, you might suspect that
much of the run-time is spent on this line (and therefore is a bottleneck in your code).

The weakness of a sampling profiler is that these snapshots do not provide
complete line-by-line coverage, because they occur at intervals (by default, 1
ms). However, the sampling profiler also has strengths. First, it requires no
code modifications. As an important consequence, it can profile into Julia's
core code and even (optionally) into C libraries. Second, by running
"infrequently" there is very little performance overhead.

## Installation

Within Julia, use the package manager:
```julia
Pkg.add("Profile")
```

## Using the sampling profiler

Unless you want to see Julia's compiler in action, it's a good idea to first run
the code you intend to profile at least once. Here's a demo:

```julia
using Profile

function myfunc()
    A = rand(100, 100, 200)
    sum(A)
end
myfunc()  # run once to force compilation
@sprofile myfunc()
```

To get the results, we do this:
```
julia> sprofile_tree(true)
14 julia; ???; line: 0
 14 /lib/x86_64-linux-gnu/libc.so.6; __libc_start_main; line: 237
  14 julia; ???; line: 0
   14 /home/tim/src/julia/usr/bin/../lib/libjulia-release.so; julia_trampoline; line: 131
    14 julia; ???; line: 0
     14 /home/tim/src/julia/usr/bin/../lib/libjulia-release.so; ???; line: 0
      14 ???; ???; line: 0
       14 client.jl; _start; line: 344
        14 client.jl; run_repl; line: 141
         14 /home/tim/src/julia/usr/bin/../lib/libjulia-release.so; ???; line: 0
          14 ???; ???; line: 0
           14 client.jl; eval_user_input; line: 68
            14 /home/tim/src/julia/usr/bin/../lib/libjulia-release.so; ???; line: 0
             14 /home/tim/src/julia/usr/bin/../lib/libjulia-release.so; ???; line: 0
              14 /home/tim/src/julia-modules/Profile.jl/src/sprofile.jl; anonymous; line: 301
               14 /home/tim/src/julia/usr/bin/../lib/libjulia-release.so; ???; line: 0
                14 ???; ???; line: 0
                 11 none; myfunc; line: 2
                  11 librandom.jl; dsfmt_gv_fill_array_close_open!; line: 128
                   1 /home/tim/src/julia/usr/bin/../lib/librandom.so; dsfmt_fill_array_close_open; line: 375
                   9 /home/tim/src/julia/usr/bin/../lib/librandom.so; dsfmt_fill_array_close_open; line: 383
                   1 /home/tim/src/julia/usr/bin/../lib/librandom.so; dsfmt_fill_array_close_open; line: 391
                 3  none; myfunc; line: 3
                  3 abstractarray.jl; sum; line: 1266
```
The `true` as an argument causes it to include C functions in the results; if
you simply call `sprofile_tree()`, or `sprofile_tree(false)`, it will exclude C
functions.

Here's how to interpret these results: the first "field" indicates the number of
samples taken, the second the filename followed by a semicolon, the third the
function name followed by a semicolon, and the fourth the line number (or, for C
code, the instruction offset). Long paths and function names are
truncated at their beginning, showing "...", and the display is set to fit
inside the width of your terminal (so your results may look slightly different).
Each sub-function call indents an additional space. There are some situations in
which the backtrace line cannot be not resolved to a function name, and these
lines are shown with `???`. In some
cases, you may see things like "+n" (where n is a number) prepended to one or
more lines; that's an indication that it should have indented another n spaces,
but ran out of room. 

In this specific case, there were 14 "samples" taken during the running of
`myfunc`. The top levels are `julia` itself, the system's `libc` in `__libc_start_main`,
a call to `julia_trampoline`, and eventually our first Julia
function, `_start`, in `client.jl`. Progressing a little further,
`eval_user_input` is the function that gets evaluated each time you type
something on the REPL, so this is essentially the "parent" of all activity that
you initiate from the REPL. Each one of these shows 14 samples, meaning that
each snapshot captured a state "inside" these functions.

The first "interesting" part is the line

```
11 none; myfunc; line: 2
```
`none` refers to the fact that we typed `myfunc` in at the REPL, rather than
putting it in a file. Line 2 contains the call to `rand`, and there were 11 (out
of 14) snapshots taken here. Below that, you can see a call to
`dsfmt_gv_fill_array_close_open!` inside `librandom.jl` and finally down again
into a C library. You might be surprised not to see the `rand` function listed
explicitly: that's because `rand` is _inlined_, and hence doesn't appear in the
backtraces.

A little further down, you see
```
3 none; myfunc; line: 3
```
Line 3 of `myfunc` contains the call to `sum`, and there were 3 (out of 14)
samples taken here. Below that, you can see the specific place in
`base/abstractarray.jl` that implements the `sum` function for these inputs.

Some lines contain multiple operations, and in fact the backtraces can
distinguish between these operations. By default, however, the counts are
"collapsed." By saying `sprofile_tree(true, false)` you can see separate
counts for each operation. The second argument determines whether the multiple
operations are merged into a single line.

Overall, we can tentatively conclude that random number generation is several
times as expensive as the sum operation. To get better statistics, we'd want to
run this multiple times.

An alternative way of viewing the results is as a "flat" dump, which
accumulates counts independent of their nesting:
 ```julia
julia> sprofile_flat(true)
 Count File                                                   Function                         Line/offset
    14 /home/tim/src/julia-modules/Profile.jl/src/sprofile.jl anonymous                                301
    14 /home/tim/src/julia/usr/bin/../lib/libjulia-release.so julia_trampoline                         131
     1 /home/tim/src/julia/usr/bin/../lib/librandom.so        dsfmt_fill_array_close_open              375
     9 /home/tim/src/julia/usr/bin/../lib/librandom.so        dsfmt_fill_array_close_open              383
     1 /home/tim/src/julia/usr/bin/../lib/librandom.so        dsfmt_fill_array_close_open              391
    14 /lib/x86_64-linux-gnu/libc.so.6                        __libc_start_main                        237
     3 abstractarray.jl                                       sum                                     1266
    14 client.jl                                              _start                                   344
    14 client.jl                                              eval_user_input                           68
    14 client.jl                                              run_repl                                 141
    11 librandom.jl                                           dsfmt_gv_fill_array_close_open!          128
    11 none                                                   myfunc                                     2
     3 none                                                   myfunc                                     3
```
The same flags apply for `sprofile_flat` as for `sprofile_tree`.

If your code has recursion, note that a line in a "child" function can
accumulate more counts than there are total backtraces. Consider the
following definitions:
```julia
dumbsum3() = dumbsum(3)
dumbsum(n::Integer) = n == 1 ? 1 : 1 + dumbsum(n-1)
```
Now execute `dumbsum3()`, and imagine that a backtrace is triggered
while executing `dumbsum(1)`. The backtrace looks like this:
```julia
dumbsum3
    dumbsum(3)
        dumbsum(2)
            dumbsum(1)
```
so the single line of this child function gets 3 counts, even though
the parent only gets one.

The sampling profiler just accumulates snapshots, and the analysis only happens
when you ask for the report with `sprofile_tree` or `sprofile_flat`. For a
long-running computation, it's entirely possible that the pre-allocated buffer
for storing snapshots will be filled. If that happens, the snapshots stop, but
your computation continues. As a consequence, you may miss some important
profiling data, although you will get a warning when that happens.

You can adjust the behavior by calling

```julia
sprofile_init(nsamples, delay)
```

where both parameters are integers. `delay` is expressed in nanoseconds, and is
the amount of time that Julia gets between snapshots to perform the requested
computations. (A very long-running job might not need such frequent snapshots.)
The larger `nsamples`, the more snapshots you can take, at the cost of larger
memory requirements.

Finally, note that you can accumulate the results of multiple calls,
and view the combined results with these functions. If you want to
start from scratch, use `sprofile_clear()`.

## Using the instrumenting profiler

This starts similarly:
```julia
using Profile
```

Here you encapsulate your code in a macro call:
```julia
@iprofile begin
function f1(x::Int)
  z = 0
  for j = 1:x
    z += j^2
  end
  return z
end

function f1(x::Float64)
  return x+2
end

function f1{T}(x::T)
  return x+5
end

f2(x) = 2*x
end     # @iprofile begin
```

Now load the file and execute the code you want to profile, e.g.:

```julia
f1(215)
for i = 1:100
  f1(3.5)
end
for i = 1:150
  f1(uint8(7))
end
for i = 1:125
  f2(11)
end
```

To view the execution times, type `@iprofile report`.

Here are the various options you have for controlling profiling:

- `@iprofile report`: display cumulative profiling results
- `@iprofile clear`: clear all timings accumulated thus far (start from zero)
- `@iprofile off`: turn profiling off (there is no need to remove @iprofile begin ... end blocks)
- `@iprofile on`: turn profiling back on

### Tips on using the instrumenting profiler

You should always discard the results of your first run: it may include the overhead needed to JIT-compile some of the subfunctions.

The primary source of variability is the garbage collector---if it runs between two instrumentation lines, its execution time gets added to the time that your own line of code contributes. This can make a fast-running line seem puzzlingly slow. One good way to reduce the variance is to run gc() before profiling. However, if your code tends to accumulate a bunch of temporaries that need to be cleaned up in the middle of the run, then calling `gc()` at the beginning can cause the collector to run at the same point in the code each time, a misleading but consistent result. A different approach is to use multiple runs (without an explicit `gc()`) and hope that the collector runs at different points in each run. The cost of a given line is probably best reflected in those runs with shortest time for that line.

### Limitations of the instrumenting profiler

Instrumenting profiling adds a performance overhead which can be significant. You can prevent a subsection of your code from being profiled by encapsulating it inside a `begin ... end` block; in this case, the block as a whole is profiled, but the individual lines inside the block are not separately timed.

The profiler tries to compensate for its overhead in the reported times. This naturally leads to some degree of uncertainty about the execution time of individual lines. More significantly, currently the profiler does not compensate for its own instrumentation in profiled subfunctions. Consequently, it’s recommended that you avoid profiling nested code as a chunk---you probably want to pick out individual functions or groups of functions to profile separately.

Both limitations are addressed by the sampling profiler. Consequently, it's probably best to start with the sampling profiler, and then use the instrumenting profiler when detailed attention to a particular function is warranted.

[Julia]: http://julialang.org "Julia"
[wp]: http://en.wikipedia.org/wiki/Profiling_(computer_programming)