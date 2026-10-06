# Security Policy

## Reporting a vulnerability

This repository is private. Collaborators can report a suspected vulnerability
by opening a [repository issue](https://github.com/roselller/live-type-translator/issues/new)
and mentioning the maintainer, **@roselller**. Access to this private repository
is required. Reports are visible to all repository collaborators.

Use a title beginning with `Security:` and include:

- The affected app version or commit, macOS version, and source application.
- Reproduction steps using synthetic text and documents you control.
- Expected and observed behavior, security impact, and required permissions.
- Relevant error messages or timing metadata, with personal details removed.
- Any suggested mitigation or fix, if available.

Do not include real clipboard contents, personal documents, credentials, signing
keys, or screenshots containing private information. Do not disclose a suspected
vulnerability in a public issue, pull request, discussion, or other public channel.

Keep this repository private while its issues contain confidential reports.
Before any visibility change, review the reporting history and establish a
confidential reporting channel for the new visibility. This issue-based reporting
process must not be used for vulnerability details in a public repository.

## Maintenance and response

Development and security fixes are maintained on `main`. Include the exact
version or commit in reports so the affected code can be identified. Reports
about older versions are welcome; fixes are made on `main`.

This is a personal project. Reports are handled on a best-effort basis, without
a guaranteed response or remediation deadline. Please coordinate disclosure
with the maintainer so affected users can receive a fix or mitigation first.

## System and security boundaries

TranslateBar is an unsandboxed macOS menu bar application. It uses Accessibility
and clipboard access to capture selected text and paste reviewed translations.
Translation runs on-device. Source text, clipboard representations, document
metadata, and generated translations must be treated as untrusted input.

Report failures of these intended security properties:

- Captured text, translations, and recent results remain in memory; they are not
  sent over a network or written to files or ordinary logs.
- Clipboard snapshots preserve all available representations. Restoration must
  not overwrite a newer clipboard change from outside the operation.
- Permission denial, cancellation, or a changed destination prevents further
  insertion. The original app and available focus/selection data are rechecked
  before pasting; insertion requires an explicit review action.
- Translation output is inserted as plain text. Clipboard markup must not execute
  content or load remote resources. Captured text must not execute system commands.
- Signing keys and local signing configuration are never included in the repository
  or distributed with the app.

Examples of relevant reports include unintended text disclosure, insertion into
the wrong application, permission or cancellation bypasses, unsafe clipboard
parsing, and exposure of signing material.

## Limitations relevant to reports

Clipboard managers may observe the source application's copy operation. Temporary
paste markers are advisory, not an access-control boundary. Clipboard data being
requested does not prove which application consumed it, and editors differ in
the focus and selection information they expose. Include the affected app and
steps in reports involving these limitations; they are not blanket exclusions.

This policy describes intended behavior and how to report problems. It is not a
security audit or a guarantee that every editor interaction is safe.
