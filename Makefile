-include Makefile.local
-include .env
export

CLOUDFLARE_PAGES_PROJECT ?= saltydragons
INSTALLDIR ?= /tmp/saltydragons.web

all:
	nix develop -c ninja

clean:
	rm -rf build.ninja .ninja_log outputs result

install: all
	mkdir -p $(INSTALLDIR)
	cp -R -c -p outputs/out/* $(INSTALLDIR)

deploy: all
	@if [ -z "$$CLOUDFLARE_API_TOKEN" ] || [ -z "$$CLOUDFLARE_PAGES_PROJECT" ]; then \
		echo "Error: CLOUDFLARE_API_TOKEN or CLOUDFLARE_PAGES_PROJECT not set in .env" >&2; \
		exit 1; \
	fi
	@STATUS=$$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $(CLOUDFLARE_API_TOKEN)" "https://api.cloudflare.com/client/v4/accounts/$(CLOUDFLARE_ACCOUNT_ID)/pages/projects/$(CLOUDFLARE_PAGES_PROJECT)"); \
	if [ "$$STATUS" = "404" ]; then \
		echo "Pages project '$(CLOUDFLARE_PAGES_PROJECT)' not found. Creating non-interactively..."; \
		CLOUDFLARE_API_TOKEN="$(CLOUDFLARE_API_TOKEN)" \
		CLOUDFLARE_ACCOUNT_ID="$(CLOUDFLARE_ACCOUNT_ID)" \
		nix develop -c wrangler pages project create "$(CLOUDFLARE_PAGES_PROJECT)" --production-branch main || exit 1; \
	fi
	CI=1 \
	CLOUDFLARE_API_TOKEN="$(CLOUDFLARE_API_TOKEN)" \
	CLOUDFLARE_ACCOUNT_ID="$(CLOUDFLARE_ACCOUNT_ID)" \
	nix develop -c wrangler pages deploy outputs/out --project-name "$(CLOUDFLARE_PAGES_PROJECT)" --commit-dirty=true

trash:
	@if [ -z "$$CLOUDFLARE_API_TOKEN" ] || [ -z "$$CLOUDFLARE_PAGES_PROJECT" ]; then \
		echo "Error: CLOUDFLARE_API_TOKEN or CLOUDFLARE_PAGES_PROJECT not set in .env" >&2; \
		exit 1; \
	fi
	CI=1 \
	CLOUDFLARE_API_TOKEN="$(CLOUDFLARE_API_TOKEN)" \
	CLOUDFLARE_ACCOUNT_ID="$(CLOUDFLARE_ACCOUNT_ID)" \
	nix develop -c wrangler pages project delete "$(CLOUDFLARE_PAGES_PROJECT)" --yes
