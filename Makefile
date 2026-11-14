# No CI: run these locally before pushing.
.PHONY: lint scan check
lint:
	tools/lint.sh
scan:
	tools/scan-secrets.sh
check: lint scan
