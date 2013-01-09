# Build with something like:
#   make INCPATH=~/src/julia/src
# Calling require("postinstall.jl") from within Julia should handle
# this for you.

CC=gcc
JULIALIBS=
CFLAGS=-Wall -I $(INCPATH)
LDFLAGS=
LINKLIBS=

platform=$(shell uname -o)
ifeq ($(platform),GNU/Linux)
	LINKLIBS+=-lrt
endif
ifeq ($(platform),Darwin)
	LDFLAGS+=-Wl,-U,_rec_backtrace
endif

profile: profile.c
	$(CC) $(CFLAGS) -O2 -shared -fPIC profile.c $(LDFLAGS) $(LINKLIBS) -o libprofile.so

clean:
	-rm libprofile.so

.PHONY: \
	profile
