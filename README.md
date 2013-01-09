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

[Julia]: http://julialang.org "Julia"
[wp]: http://en.wikipedia.org/wiki/Profiling_(computer_programming)