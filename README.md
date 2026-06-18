# Salty Dragons

The Salty Dragons web site.

## Build

```bash
make all          # Build the site
nix build -Lv     # Full hermetic build (as CI runs it)
make install      # Copy to $(INSTALLDIR) from Makefile.local
```

See `CLAUDE.md` for architecture details.
