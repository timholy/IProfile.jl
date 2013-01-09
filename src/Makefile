# Build with something like:
#   make JULIALIBS=~/src/julia/usr/lib INCPATH=~/src/julia/src
# Calling require("postinstall.jl") from within Julia should handle
# this for you.

CC=gcc
JULIALIBS=
CFLAGS=-Wall -I $(INCPATH)
LDFLAGS=-Wl,-rpath,$(JULIALIBS) -L$(JULIALIBS)

profile: profile.c
	$(CC) $(CFLAGS) $(LDFLAGS) -O2 -shared -fPIC profile.c -lrt -ljulia-release -o libprofile.so

clean:
	-rm libprofile.so

.PHONY: \
	profile
