# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `Retry-After` in HTTP-date form (IMF-fixdate, e.g. `Wed, 21 Oct 2026 07:28:00 GMT`): `getRetryAfterSeconds()`
  returns the seconds until the date (0 when it has passed), so async backoff and the sync retry rule honour it.
- Circuit breaker settings per Named Credential: a `Callwise_Breaker__mdt` record named after the Named Credential
  sets `Failure_Threshold__c` (1–100, default 5) and `Open_Seconds__c` (1–3600, default 60).

## [0.1.0] - 2026-10-04

First release.

### Added

- Public API surface: `Callwise`, `CallwiseRequest`, `CallwiseResponse`, `CallwiseRetryPolicy`, `CallwiseException`
  and `CallwiseMock`.
- `Callwise.Logger` and `Callwise.Callback` interfaces; `NoOpLogger` and `DebugLogger` (bodies excluded by default).
- `CallwiseMock`: declarative routes with `*` wildcards, response sequences, `thenThrow()` and request counting.
- `send()` with transport-error translation (`TRANSPORT`, `TIMEOUT`, `UNCOMMITTED_WORK`) and immediate synchronous
  retries bounded by the retry policy, `Retry-After` and the transaction's callout budget (`LIMIT_BUDGET` when no
  callout is left for the first attempt).
- `CallwiseRequest.idempotent()`: generates an `Idempotency-Key` once and reuses it on every attempt, so POST and
  PATCH can be retried; `getIdempotencyKey()`.
- Circuit breaker per Named Credential (`CallwiseCircuitBreaker`, internal): opens after 5 consecutive failures
  (transport errors, timeouts, 5xx, 408, 429), rejects with `CIRCUIT_OPEN` for 60 s, then lets one trial through.
  State in Platform Cache with a per-transaction fallback; `withoutCircuitBreaker()` bypasses it.
- `sendAsync()` and `sendAsync(Type callback)`: one Queueable per attempt with real backoff (`Retry-After`, otherwise
  exponential, at most 10 minutes), the same `Idempotency-Key` on every attempt, the circuit breaker respected, and
  the final outcome delivered to `Callwise.Callback`.
- Unlocked package `Callwise` (no namespace), version `0.1.0`.
- `docs/API.md` (reference) and `docs/design.md` (design decisions).
- Apex tests (187 tests, 98% coverage; the uncovered lines are Platform Cache reads and writes, which need a
  partition, and the enqueue of a chained async attempt, which Apex tests cannot run).

[Unreleased]: https://github.com/lightningcodetech/callwise/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/lightningcodetech/callwise/releases/tag/v0.1.0
