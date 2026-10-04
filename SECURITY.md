# Security policy

Callwise sits between Salesforce and external APIs, often payment or ERP APIs, so security reports are taken
seriously.

## Supported versions

Only the latest release receives security fixes. While Callwise is in `0.x`, fixes ship as a new patch or minor
release; older versions are not patched.

## Reporting a vulnerability

**Do not open a public issue.** Report it privately through
[GitHub private vulnerability reporting](https://github.com/lightningcodetech/callwise/security/advisories/new).

Include, if you can:

- the affected version or commit;
- what an attacker could do (for example duplicate a payment, leak a credential or a response body, bypass the
  circuit breaker);
- the steps or Apex code to reproduce it.

Once the report is confirmed, the fix is developed in a private advisory, released, and the advisory is published
with credit to the reporter unless you prefer to stay anonymous.

## Scope

In scope: the code in this repository and the packages built from it.

Out of scope: the configuration of the subscriber org (Named Credentials, External Credentials, permission sets,
Platform Cache partitions) and vulnerabilities in the external APIs called through Callwise.

## Design notes relevant to security

- Callwise only calls Named Credentials, so endpoints and secrets stay out of code.
- Request and response bodies are never logged unless the caller enables it with `DebugLogger.includeBodies()`.
- POST and PATCH are never retried without an `Idempotency-Key`, to avoid duplicating side effects such as charges.
