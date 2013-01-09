# Profile.jl

This package contains profiling tools for the [Julia][Julia] language. Profilers are mainly used for code optimization, particularly to find bottlenecks.

This package implements two [types of profilers][wp], an "instrumenting" profiler and a "sampling" (statistical) profiler.

### Instrumenting profiler

The instrumenting profiler provides detailed information, including the number of times each line gets executed and the total run time. However, the instrumenting profiler requires that your code be (automatically) modified by encapsulating it in "@iprofile begin...end". It also has a significant performance cost.

### Sampling profiler

The sampling profiler works by grabbing "snapshots" during the execution of any task. Each "snapshot" extracts the currently-running function line number. Lines that occur frequently are indicative of a step in your computation that consumes significant resources.

On the downside, these snapshots occur at intervals (by default, 1 ms) and hence do not provide complete line-by-line coverage. On the upside, the sampling profiler requires no code modifications. As an important consequence, it can profile into Julia's core code and even (optionally) into C libraries. Finally, by running "infrequently" there is very little performance overhead.

## Installation

Within Julia, use the package manager:
```julia
load("pkg.jl")
Pkg.init()     # if you've never installed a package before
Pkg.add("Profile")
```

You also need to compile a C library. Within the `Profile/src` directory, type `include("postinstall.jl")` from the Julia prompt.

## Using the sampling profiler

Unless you want to see Julia's compiler in action, it's a good idea to run the code you intend to profile first. Here's a demo:

```julia
require("Profile")
using SProfile  # use the sampling profiler
function myfunc()
    A = rand(100, 100, 200)
    sum(A)
end
myfunc()  # to run once
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

Here's how to interpret these results: the first column indicates the number of samples taken, the second the filename, the third the function name, and the fourth the line nubmer. There were 12 "samples" taken during the running of `myfunc`. The top level was in the system's `libc`, in `__libc_start_main`, which then calls `julia_trampoline`, which in turn calls our first julia function, `_start` in `client.jl`. Each one of these shows 12 samples, meaning that these functions lay "above" each snapshot taken. The first "interesting" part is actually the line

```
4 none; myfunc; line: 3
```
`none` refers to the fact that we typed this function in at the REPL, rather than putting it in a file. Line 3 of `myfunc` contains the call to `sum`, and there were 4 (out of 12) snapshots taken here. Below that, you can see the specific places in `base/array.jl` that implement the `sum` function for these inputs.

A little further down, you see
```
8 none; myfunc; line: 2
```
Line 2 contains the call to `rand`, and there were 8 (out of 12) snapshots taken here. Below that, you can see calls inside `librandom` and finally back down again into a C library. You might be surprised not to see the `rand` function listed explicitly: that's because `rand` is _inlined_, and hence doesn't appear in the backtraces.

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

[Julia]: http://julialang.org "Julia"
[wp]: http://en.wikipedia.org/wiki/Profiling_(computer_programming)