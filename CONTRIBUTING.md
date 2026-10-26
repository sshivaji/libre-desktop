# Contributing

Open an issue describing the behavior or a pull request with a focused change. Include your macOS version and app version. Keep account emails, passwords, tokens, report URLs, glucose exports, and patient identifiers out of issues, screenshots, logs, and fixtures.

Run `bash scripts/test.sh` and `bash scripts/build.sh` before submitting. Add meaningful regression coverage for parsing, authentication, retry, date/time, and storage changes. Tests must use synthetic data and mock transports, without live accounts or network calls.

Preserve measurement timestamps, missing-data states, account/person isolation, host allowlists, and credential redaction. Do not automatically accept service terms or silently switch the person being displayed. UI previews can be generated with `bash scripts/render-previews.sh`.

Do not commit built apps, local databases, credentials, or signing certificates. Contributions are made under the project's existing AGPL-3.0 license.
