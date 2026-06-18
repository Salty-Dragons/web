include Makefile.local

all:
	nix develop -c ninja

clean:
	rm -rf build.ninja .ninja_log outputs

install:
	mkdir -p $(INSTALLDIR)
	cp -R -c -p outputs/out/* $(INSTALLDIR)
