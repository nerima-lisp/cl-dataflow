# Security Policy

`cl-dataflow` is a small Common Lisp library, but any bug that causes
incorrect graph execution, state corruption, or unsafe effect handling should
be treated seriously.

## Supported versions

The current stable line and `main` receive security fixes. Pre-1.0 releases
are no longer maintained. Upgrade to the newest tag before reporting an issue.

| Version | Supported |
| --- | --- |
| 1.0.x   | Yes |
| < 1.0.0 | No  |

## Reporting a vulnerability

Please report vulnerabilities privately using GitHub's private vulnerability
reporting:

1. Open the [new advisory form](https://github.com/nerima-lisp/cl-dataflow/security/advisories/new).
2. Or go to the repository's **Security** tab and choose **Report a
   vulnerability**.

!!! warning "Do not open a public issue for a suspected vulnerability."

Include:

- What you observed
- The affected file or API
- A minimal reproduction if possible
- Whether the issue affects runtime behavior, data integrity, or availability

## What to avoid in public reports

- Full exploit details before maintainers have a chance to respond
- Sensitive data or secrets
- Unnecessary public proof-of-concept material

## Expected response

Maintainers aim to acknowledge a report within a few days, validate the
impact, and coordinate a fix or mitigation before public disclosure where
possible. Once a fix ships, the advisory is published with credit to the
reporter unless anonymity is requested.
