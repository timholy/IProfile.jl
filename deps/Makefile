CC=gcc
JULIALIBS=
CFLAGS=-Wall
LDFLAGS=
LINKLIBS=

platform=$(shell uname)
ifeq ($(platform),Linux)
	LINKLIBS+=-lrt
	LIBEXT=so
else ifeq ($(platform),Darwin)
	LDFLAGS+=-Wl,-U,_rec_backtrace
	LIBEXT=dylib
else
	# WINDOWS
	# what are the appropriate LDFLAGS??
	LDFLAGS+=-lrt
	LIBEXT=dll
endif

profile: profile.c
	$(CC) $(CFLAGS) -O2 -shared -fPIC profile.c $(LDFLAGS) $(LINKLIBS) -o libprofile.$(LIBEXT)

clean:
	-rm libprofile.$(LIBEXT)

.PHONY: \
	profile
