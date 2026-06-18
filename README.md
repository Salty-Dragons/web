# Salty Dragons

The Salty Dragons web site.

## Build

```bash
make all          # Build the site
nix build -Lv     # Full hermetic build
make install      # Copy to $(INSTALLDIR) from Makefile.local
```

See `AGENTS.md` for architecture details.
