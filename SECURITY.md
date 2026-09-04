# Security Policy

TelemetryKit handles application-supplied telemetry and ingestion credentials. Security reports deserve a private path and enough detail to reproduce the problem safely.

## Supported versions

Until the first stable release, the latest tagged version (when one exists) and the default development branch receive security fixes. After stable releases begin, this table will list supported release lines explicitly. Older prerelease snapshots should be treated as unsupported.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability.

Use the repository host's private vulnerability-reporting feature from the **Security** tab. If that feature is unavailable, ask the maintainers for an approved private reporting channel without including exploit details in the initial public message.

Include, when possible:

- Affected version, distribution form, OS, device/simulator, and Xcode version.
- A minimal reproduction or clear sequence of events.
- Expected and observed behavior.
- Security impact and any known preconditions.
- Whether the issue could expose queued data, credentials, file paths, URLs, or cross-app information.
- Suggested remediation, if you have one.

Maintainers should acknowledge receipt privately, validate impact, coordinate a fix and advisory, and credit the reporter if requested. Timelines depend on severity and release validation; please avoid public disclosure until users have a reasonable opportunity to update.

## Operational guidance

- Use a narrowly scoped, revocable client ingestion key. An administrative API key does not belong in an app bundle.
- Enforce TLS and authentication at the configured endpoint.
- Treat event names, attributes, network metadata, queued files, and diagnostics as potentially sensitive.
- Keep queue limits and server-side retention finite.
- Give each client and process a dedicated queue directory. The SDK uses an Apple-platform advisory file lock to reject concurrent ownership, but it is not a supported cross-process sharing protocol.
- Treat iOS complete-until-first-user-authentication file protection as defense in depth, not end-to-end or application-level encryption.
- Do not log authorization values, raw payloads, or unredacted user input.
- Verify release checksums and provenance before integrating an XCFramework.

This policy covers vulnerabilities in TelemetryKit itself. Questions about an application's event schema, consent model, or backend configuration should go through that application's normal security and privacy processes.
