# Build with something like:
#   make JULIALIBS=~/src/julia/usr/lib

CC=gcc
JULIALIBS=
CFLAGS=-Wall
LDFLAGS=-Wl,-rpath,$(JULIALIBS) -L$(JULIALIBS)

profile: profile.c
	$(CC) $(CFLAGS) $(LDFLAGS) -O2 -shared -fPIC profile.c -lrt -ljulia-release -o libprofile.so

clean:
	-rm libprofile.so

.PHONY: \
	profile
