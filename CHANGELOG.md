# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Public API surface: `Callwise`, `CallwiseRequest`, `CallwiseResponse`, `CallwiseRetryPolicy`, `CallwiseException`
  and `CallwiseMock`.
- `Callwise.Logger` and `Callwise.Callback` interfaces; `NoOpLogger` and `DebugLogger` (bodies excluded by default).
- `CallwiseMock`: declarative routes with `*` wildcards, response sequences, `thenThrow()` and request counting.
- `send()` performs a single attempt with transport-error translation (`TRANSPORT`, `TIMEOUT`, `UNCOMMITTED_WORK`).
- `docs/API.md`.
- Apex tests for the public surface (130 tests, 100% coverage except the private `Callwise` constructor).
