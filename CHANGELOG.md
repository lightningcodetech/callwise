# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
- `docs/API.md`.
- Apex tests (151 tests, 100% coverage except the private `Callwise` constructor).
