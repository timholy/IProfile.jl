# IProfile.jl

This package contains an "instrumenting profiler" for the [Julia][Julia] language. Profilers
are mainly used for code optimization, particularly to find bottlenecks.

### Sampling profiler is now in base

This package used to contain a sampling profiler, but that has been moved to Julia proper.
The built-in sampling profiler has far fewer limitations than this package, and is recommended
over this one in essentially all cases.
See the [documentation](https://docs.julialang.org/en/v1/manual/profile/) and [API reference](https://docs.julialang.org/en/v1/stdlib/Profile/).

Because the sampling profiler is so much better, I am not fixing bugs in this package anymore.
However, I am happy to accept pull requests.

### Instrumenting profiler

The instrumenting profiler provides detailed information, including the number
of times each line gets executed and the total run time spent on that line.
However, the instrumenting profiler requires that your code be (automatically)
modified, by encapsulating it in "@iprofile begin...end". It also has a
significant performance cost.

## Installation

Within Julia, use the package manager:
```julia
Pkg.add("IProfile")
```

## Usage

This starts similarly:
```julia
using IProfile
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
