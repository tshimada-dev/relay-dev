# Security

relay-dev runs external provider CLIs and is intended for trusted local development workflows, not untrusted multi-tenant execution.

Please do not publish:

- API keys, tokens, passwords, or private keys
- raw provider job logs
- customer or personal data
- local absolute paths in public examples
- unsanitized `runs/` directories

If you find a security issue, report it privately to the repository owner. Avoid creating public issues that include exploit details or secrets.

The safety model separates runtime enforcement from prompt and operational discipline. When documenting a safety claim, be explicit about which category it belongs to.
