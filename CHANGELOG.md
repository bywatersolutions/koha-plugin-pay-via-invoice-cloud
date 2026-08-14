# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- The Invoice Cloud API key is now encrypted at rest with `Koha::Encryption` (AES-256-CBC) instead
  of being stored in cleartext in Koha's `plugin_data` table. Existing credentials are migrated
  automatically on upgrade.
- The configuration form now submits via `POST` with a CSRF token, so a newly entered API key no
  longer appears in staff browser URLs, browser history, or the web server access log.
- The configuration page no longer renders the stored API key back into the form. The field is a
  password input and is left blank; leave it blank to keep the existing key.

### Added

- `upgrade()`, which encrypts any credential still held in cleartext. It is idempotent, and never
  throws — an instance with no encryption key keeps working on its existing cleartext credential
  rather than dropping out of Koha's plugin list.
- `t/db_dependent/PayViaInvoiceCloud.t`, covering the migration, its idempotency, the cleartext
  fallback, and the fail-closed paths.

### Fixed

- The `Invoice Type ID` and `Credit Card Service Fee` fields are now HTML-escaped in the
  configuration form.
- CI now runs `prove` recursively, so tests under `t/db_dependent/` are actually collected.

### Notes

- Encryption needs an `encryption_key` in `koha-conf.xml`; Koha does not generate one. Without it
  the plugin behaves as before and the configuration page shows a warning. See the README.
- Encryption requires Koha 22.05 or newer. On older versions the plugin runs unchanged.
- If `encryption_key` changes after a credential has been encrypted, online payments fail with a
  clear error until the API key is re-entered — the credential is never sent in a corrupted form.
