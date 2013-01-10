# Profile.jl

This package contains profiling tools for the [Julia][Julia] language. Profilers are mainly used for code optimization, particularly to find bottlenecks.

This package implements two [types of profilers][wp], an "instrumenting" profiler and a "sampling" (statistical) profiler.

### Instrumenting profiler

The instrumenting profiler provides detailed information, including the number of times each line gets executed and the total run time spent on that line. However, the instrumenting profiler requires that your code be (automatically) modified, by encapsulating it in "@iprofile begin...end". It also has a significant performance cost.

### Sampling profiler

The sampling profiler works by grabbing "snapshots" during the execution of any task. Each "snapshot" extracts the currently-running function and line number. When a line occurs frequently in the set of snapshots, one might suspect that this line consumes significant resources.

The weakness of a sampling profiler is that these snapshots do not provide complete line-by-line coverage, because they occur at intervals (by default, 1 ms). However, the sampling profiler also has strengths. First, it requires no code modifications. As an important consequence, it can profile into Julia's core code and even (optionally) into C libraries. Second, by running "infrequently" there is very little performance overhead.

## Installation

Within Julia, use the package manager:
```julia
load("pkg.jl")
Pkg.init()     # if you've never installed a package before
Pkg.add("Profile")
```

You also need to compile a C library. Within the `Profile/src` directory, type `include("postinstall.jl")` from the Julia prompt.

## Using the sampling profiler

Unless you want to see Julia's compiler in action, it's a good idea to first run the code you intend to profile at least once. Here's a demo:

```julia
require("Profile")
using SProfile  # use the sampling profiler
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
  12 ...nux-gnu/libc.so.6; __libc_start_main; offset: ed
      12 ...bjulia-release.so; julia_trampoline; offset: 60
              12 client.jl; _start; line: 318
                12 client.jl; run_repl; line: 155
                      12 client.jl; eval_user_input; line: 82
                            12 no file; anonymous; line: 193
                                  4 none; myfunc; line: 3
                                    1 array.jl; sum; line: 1376
                                    1 array.jl; sum; line: 1377
                                    2 array.jl; sum; line: 1377
                                  8 none; myfunc; line: 2
                                    8 librandom.jl; dsfmt_gv_fill_array_close_open!; line: 128
                                      8 .../lib/librandom.so; dsfmt_fill_array_close_open; offset: 17f
```
The `true` as an argument causes it to include C functions in the results; if you simply call `sprofile_tree()` by default it will exclude C functions.

Here's how to interpret these results: the first column indicates the number of samples taken, the second the filename, the third the function name, and the fourth the line number (or, for C code, the instruction offset in hex). There were 12 "samples" taken during the running of `myfunc`. The top level was in the system's `libc`, in `__libc_start_main`, which then calls `julia_trampoline`, which in turn calls our first Julia function, `_start`, in `client.jl`. Progressing a little further, `eval_user_input` is the function that gets evaluated each time you type something on the REPL, so this is, in a sense, the "parent" of all activity that you initiate from the REPL. Each one of these shows 12 samples, meaning that each snapshot captured a state "inside" these functions.

The first "interesting" part is the line

```
4 none; myfunc; line: 3
```
`none` refers to the fact that we typed this function in at the REPL, rather than putting it in a file. Line 3 of `myfunc` contains the call to `sum`, and there were 4 (out of 12) snapshots taken here. Below that, you can see the specific places in `base/array.jl` that implement the `sum` function for these inputs.

A little further down, you see
```
8 none; myfunc; line: 2
```
Line 2 contains the call to `rand`, and there were 8 (out of 12) snapshots taken here. Below that, you can see a call inside `librandom.jl` and finally back down again into a C library. You might be surprised not to see the `rand` function listed explicitly: that's because `rand` is _inlined_, and hence doesn't appear in the backtraces.

So we can conclude than random number generation is something like twice as expensive as the sum operation. To get better statistics, we'd want to run this multiple times.

An alternative way of viewing the results is as a "flat" dump:
```julia
julia> sprofile_flat(true)
 Count                 File                       Function   Line
    12 ...bjulia-release.so               julia_trampoline     96
     8 .../lib/librandom.so    dsfmt_fill_array_close_open    383
    12 ...nux-gnu/libc.so.6              __libc_start_main    237
     1             array.jl                            sum   1376
     2             array.jl                            sum   1377
     1             array.jl                            sum   1377
    12            client.jl                         _start    318
    12            client.jl                eval_user_input     82
    12            client.jl                       run_repl    155
     8         librandom.jl dsfmt_gv_fill_array_close_open!    128
    12              no file                      anonymous    193
     8                 none                         myfunc      2
     4                 none                         myfunc      3
```

You can accumulate the results of multiple calls, and view the combined results with these functions. If you want to start from scratch, use `sprofile_clear()`. 

The sampling profiler just accumulates snapshots, and the analysis only happens when you ask for the report with `sprofile_tree` or `sprofile_flat`. For a long-running computation, it's entirely possible that the pre-allocated buffer for storing snapshots will be filled. If that happens, the snapshots stop, but your computation continues. As a consequence, you may miss some important profiling data, although you will get a warning when that happens.

You can adjust the behavior by calling

```julia
sprofile_init(delay, nsamples)
```

where both parameters are integers. `delay` is expressed in nanoseconds, and is the amount of time that Julia gets between snapshots to perform the requested computations. (A very long-running job might not need such frequent snapshots.) The larger `nsamples`, the more snapshots you can take, at the cost of larger memory requirements.


## Using the instrumenting profiler

This starts similarly:
```julia
require("Profile")
using IProfile  # use the instrumenting profiler
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