# Callwise API

> Applies to **v0.1.0**. While Callwise is in `0.x`, minor versions may change the API; see the
> [CHANGELOG](../CHANGELOG.md).

## Goals

- Resilient REST callouts over **Named Credentials** with retries that respect idempotency.
- Never waste governor limits: no busy-waits, no retry that cannot fit in the transaction.
- Real backoff where the platform allows it (async), honest immediate retries where it does not (sync).
- Circuit breaker per Named Credential so a dead endpoint stops consuming callouts.
- Declarative HTTP mocks for tests.
- Zero dependencies.

## Non-goals

- Raw URLs or Remote Site Settings. Credentials belong in Named Credentials.
- SOAP, streaming, or Continuation-based callouts.
- Response-to-SObject mapping, pagination helpers (planned for v0.3), or a logging framework (plug in your own).

## Quick start

```apex
CallwiseResponse res = Callwise.to('Stripe_API')
    .post('/v1/customers')
    .header('Idempotency-Key', key)
    .jsonBody(payload)
    .timeout(10000)
    .retry(CallwiseRetryPolicy.transientErrors().maxAttempts(3))
    .send();

if (res.isSuccess()) {
    Customer c = (Customer) res.deserialize(Customer.class);
}
```

4xx and 5xx statuses are **returned**, not thrown. Opt in to exceptions with `.throwOnError()`.

## Classes

### `Callwise`

| Member                                              | Description                                                                                                           |
| --------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `to(String namedCredential)`                        | Starts a `CallwiseRequest`. The name is the Named Credential API name, without `callout:`.                            |
| `setLogger(Logger)` / `getLogger()`                 | Transaction-wide logger. `null` restores `NoOpLogger`. Static state does not travel to async jobs.                    |
| `setCachePartition(String)` / `getCachePartition()` | Org cache partition for breaker state. Default `local.Callwise`.                                                      |
| `interface Logger`                                  | `log(request, response, failure, attempt)`. Called once per attempt. Must not throw.                                  |
| `interface Callback`                                | `onResponse(request, response)` / `onFailure(request, failure)` for `sendAsync()`. Needs a public no-arg constructor. |
| `NoOpLogger`                                        | Default. Does nothing.                                                                                                |
| `DebugLogger`                                       | One `System.debug` line per attempt. `new DebugLogger(LoggingLevel.INFO).includeBodies()` to also log bodies.         |

Bodies are never logged unless you ask for it: they routinely carry PII.

### `CallwiseRequest`

| Member                                     | Description                                                                                                                                                                                                               |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `get/head/post/put/patch/del(path)`        | Sets method and path. `del` because `delete` is reserved. A missing leading `/` is added; absolute URLs are rejected.                                                                                                     |
| `header(name, value)`                      | Replaces any header with the same name (case-insensitive). `null` value → `''`.                                                                                                                                           |
| `idempotent()`                             | Sends an `Idempotency-Key` generated once (UUID v4) and reused on every attempt, so POST/PATCH can be retried. A caller-provided key is kept.                                                                             |
| `param(name, value)`                       | Appends a URL-encoded query parameter. Order and repeats are preserved. `null` value → `''`.                                                                                                                              |
| `body(String)`                             | Raw body. Set `Content-Type` yourself.                                                                                                                                                                                    |
| `jsonBody(Object)`                         | `JSON.serialize(value, true)` and `Content-Type: application/json` unless already set.                                                                                                                                    |
| `timeout(ms)`                              | Per-attempt timeout, 1–120000. Default 10000.                                                                                                                                                                             |
| `retry(policy)`                            | Default `CallwiseRetryPolicy.transientErrors()`. Use `none()` to disable.                                                                                                                                                 |
| `withoutCircuitBreaker()`                  | Ignore and do not update the breaker for this request.                                                                                                                                                                    |
| `throwOnError()`                           | Throw `HTTP_ERROR` when the final status is not 2xx.                                                                                                                                                                      |
| `send()`                                   | Synchronous. Returns `CallwiseResponse`.                                                                                                                                                                                  |
| `sendAsync()` / `sendAsync(Type callback)` | Queueable delivery with real backoff; returns the job Id. The callback type is validated up front. See [Retry semantics](#retry-semantics).                                                                               |
| Getters                                    | `getNamedCredential`, `getMethod`, `getPath`, `getEndpoint`, `getHeaders`, `getBody`, `getTimeoutMs`, `getRetryPolicy`, `isCircuitBreakerEnabled`, `isThrowOnError`, `isIdempotent`, `getIdempotencyKey`, `toHttpRequest` |

### `CallwiseResponse`

Serializable copy of `HttpResponse` (which is not serializable), so async jobs can carry it.

| Member                                              | Description                                                                                                                                                                       |
| --------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `getStatusCode()`, `getStatus()`, `getBody()`       | As received.                                                                                                                                                                      |
| `getHeader(name)`, `getHeaders()`                   | Case-insensitive; names stored in lower case.                                                                                                                                     |
| `getAttempts()`, `getElapsedMs()`                   | Attempts made and total wall-clock time.                                                                                                                                          |
| `getRetryAfterSeconds()`                            | Seconds (`Retry-After: 120`) or the time until an HTTP date in IMF-fixdate form (`Wed, 21 Oct 2026 07:28:00 GMT`), 0 when the date has passed; `null` when absent or unparseable. |
| `isSuccess()`, `isClientError()`, `isServerError()` | 2xx, 4xx, 5xx.                                                                                                                                                                    |
| `deserialize(Type)`, `deserializeUntyped()`         | `null` for a blank body; `JSONException` for invalid JSON.                                                                                                                        |

### `CallwiseRetryPolicy`

| Member                            | Description                                                                  |
| --------------------------------- | ---------------------------------------------------------------------------- |
| `none()`                          | 1 attempt.                                                                   |
| `transientErrors()`               | 3 attempts; 408, 429, 500, 502, 503, 504; retries `TRANSPORT` and `TIMEOUT`. |
| `maxAttempts(n)`                  | 1–10 total attempts.                                                         |
| `retryOn(Set<Integer>)`           | Replaces the retryable status codes.                                         |
| `allowNonIdempotent()`            | Also retry POST/PATCH without `Idempotency-Key`.                             |
| `asyncBaseDelay(minutes)`         | 0–10. Default 1.                                                             |
| `isRetryable(req, res, err)`      | Internal. Policy decision only; the engine adds attempt count and budget.    |
| `asyncDelayMinutes(attempt, res)` | Internal. See [Retry semantics](#retry-semantics).                           |

### `CallwiseException`

`reason` is a `FailureReason`; `response` is set only for `HTTP_ERROR`.

| Reason             | When                                            | Retryable by default    |
| ------------------ | ----------------------------------------------- | ----------------------- |
| `INVALID_REQUEST`  | Bad arguments or configuration                  | No                      |
| `TRANSPORT`        | Connection-level failure                        | Yes (`transientErrors`) |
| `TIMEOUT`          | Callout timed out                               | Yes (`transientErrors`) |
| `CIRCUIT_OPEN`     | Breaker open; no callout made                   | No                      |
| `LIMIT_BUDGET`     | Next attempt would not fit the remaining limits | No                      |
| `UNCOMMITTED_WORK` | DML earlier in the transaction                  | No; use `sendAsync()`   |
| `HTTP_ERROR`       | Non-2xx with `throwOnError()`                   | n/a                     |

Factories: `create(reason, message)`, `create(reason, message, cause)`, `invalidRequest(message)`,
`fromResponse(response)`. `isTransportFailure()` is true for `TRANSPORT` and `TIMEOUT`.

### `CallwiseMock`

See [Testing](#testing).

## Retry semantics

**Idempotency first.** Only GET, HEAD, PUT and DELETE are retried. POST and PATCH are retried only with a
non-blank `Idempotency-Key` header (set it yourself or call `idempotent()`) or `allowNonIdempotent()`: a POST that
timed out may already have succeeded. The same key is sent on every attempt.

**Synchronous.** Apex cannot sleep, and a busy-wait burns CPU time without helping the server.
Sync retries are therefore immediate and only happen if the next attempt fits in the budget:

- `Limits.getCallouts()` must leave room for another callout, and
- the request's timeout must fit in what remains of the 120 s cumulative callout time.

If it does not fit, the engine stops and returns the last response (or throws the last failure). If not even the
first attempt has a callout left, `send()` throws `LIMIT_BUDGET` without calling out. The platform does not expose
the cumulative callout time, so Callwise counts only the time spent in its own callouts during the transaction. A `Retry-After`
greater than 0 disables the sync retry: hammering a server that asked you to wait is worse than failing.

**Asynchronous.** `sendAsync()` runs each attempt in its own Queueable with `Database.AllowsCallouts`, so every
attempt has fresh limits and DML earlier in the caller's transaction does not matter. On a retryable outcome the job
enqueues the next attempt with `System.enqueueJob(job, delayMinutes)`:

- `Retry-After: n` (seconds) or `Retry-After: <HTTP date>` → seconds to wait rounded up to minutes, max 10.
- Otherwise `base * 2^(attempt - 1)` minutes, max 10. With the default base of 1: 1, 2, 4, 8, 10, 10…

The same idempotency rules apply, and the request travels in the job state, so every attempt sends the same
`Idempotency-Key`. When the circuit is open the attempt makes no callout and is retried, whatever the HTTP method,
no earlier than the breaker's next trial.

The callback (`sendAsync(Type)`) receives only the final outcome, in the transaction of the last job:

- `onResponse(request, response)` with the final response, whatever its status;
- `onFailure(request, failure)` when the last attempt failed (`TRANSPORT`, `TIMEOUT`, `CIRCUIT_OPEN`…), or with
  `HTTP_ERROR` when the request used `throwOnError()` and the final status is not 2xx.

Static settings (`Callwise.setLogger()`, `setCachePartition()`) do not travel to the jobs. An exception thrown by the
callback fails that job; it is visible in Setup → Apex Jobs.

## Circuit breaker

One breaker per Named Credential: `CLOSED → OPEN` after 5 consecutive failures, `OPEN` for 60 s, then
`HALF_OPEN` lets one request through; success closes it, failure reopens it.

**Settings per Named Credential.** Create a `Callwise Breaker` custom metadata record (Setup → Custom Metadata
Types) whose **name is the Named Credential API name**:

| Field                 | Range  | Default |
| --------------------- | ------ | ------- |
| `FailureThreshold__c` | 1–100  | 5       |
| `OpenSeconds__c`      | 1–3600 | 60      |

A blank or out-of-range field uses its default. Records are read with `getInstance()`, which does not count against
SOQL limits, and apply to `send()` and `sendAsync()` alike.

- **Failures** are transport errors, timeouts and 5xx, 408 and 429 responses. Any other response (including 4xx such
  as 404 or 409) counts as a success: the endpoint answered. `UNCOMMITTED_WORK` and `LIMIT_BUDGET` are not
  recorded.
- **Every attempt** is recorded, retries included. If the circuit opens during sync retries, the retries stop and the
  last response or failure is returned.
- **While open**, `send()` throws `CIRCUIT_OPEN` without making a callout; the message says when the next trial is
  allowed.
- **A trial that never reports back** (its transaction failed) is replaced by a new one after another 60 s.
- `withoutCircuitBreaker()` skips the check and does not record the outcome.

State lives in Platform Cache (org partition, `local.Callwise` by default) behind a `Store` interface, for up to 24 h
of inactivity; an expired entry simply starts again as `CLOSED`. When the partition is missing or unusable, Callwise
falls back to a store that only lives for the current transaction and writes one `WARN` line to the debug log per
transaction. A cache problem never opens the circuit.

**Best effort:** Platform Cache has no atomic compare-and-set, so concurrent transactions can race on the counter.
The breaker reduces load on a failing endpoint; it does not guarantee an exact threshold.

Create the partition in Setup → Platform Cache with a few KB of org cache. Developer Edition orgs include a small
free allocation.

## Testing

`CallwiseMock` is a regular class (not `@IsTest`) so it can be used from any test in the subscriber org.

```apex
@IsTest
static void retriesTransientFailures() {
    CallwiseMock mock = new CallwiseMock()
        .whenRequest('GET', '/v1/customers/*')
        .thenRespond(503, '')
        .thenRespond(200, '{"id":"cus_123"}', new Map<String, String>{ 'Content-Type' => 'application/json' })
        .install();

    Test.startTest();
    CallwiseResponse res = Callwise.to('Stripe_API').get('/v1/customers/cus_123').send();
    Test.stopTest();

    Assert.areEqual(200, res.getStatusCode());
    Assert.areEqual(2, mock.countRequests('GET', '/v1/customers/*'));
}
```

- `*` matches any characters; method `'*'` matches any method.
- Patterns are matched against the path; include `?` in the pattern to match the query string as well.
- Routes are checked in registration order; the first match wins.
- A route's responses play in order; the last one repeats.
- `thenThrow('Read timed out')` makes the callout throw a `CalloutException`.
- An unmatched request throws `CallwiseMock.MockException` listing the registered routes.
- `getRequests()` returns every `HttpRequest` received, for asserting headers and bodies.
- **`sendAsync()` in tests:** the first attempt runs at `Test.stopTest()`. Apex does not allow chaining Queueable
  jobs in tests, so later attempts are not enqueued; assert on the first attempt or use `send()`.

## Limits

| Resource       | Cost                                                                                                                  |
| -------------- | --------------------------------------------------------------------------------------------------------------------- |
| Callouts       | 1 per attempt. A sync `send()` with `maxAttempts(3)` can use 3 of the 100 per transaction.                            |
| Callout time   | Each attempt can consume up to its timeout from the 120 s cumulative budget.                                          |
| CPU            | Negligible; no busy-waits.                                                                                            |
| Async          | 1 Queueable per attempt for `sendAsync()`, subject to the 50-jobs-per-transaction limit when enqueued from sync code. |
| Platform Cache | One small entry per Named Credential for breaker state.                                                               |
| SOQL / DML     | None.                                                                                                                 |

Known platform constraints:

- Callouts after DML in the same transaction fail (`UNCOMMITTED_WORK`); use `sendAsync()`.
- Developer Edition and trial orgs allow a chain of at most 5 Queueable jobs, so `sendAsync()` can make at most
  5 attempts there.
- `jsonBody()` omits null fields of Apex objects but keeps null values inside a `Map`.
- `Retry-After` dates are only parsed in IMF-fixdate form, the one RFC 9110 requires senders to use; the obsolete
  RFC 850 and asctime forms return `null`.

## Decision log

Summary. Context, alternatives and consequences of each decision: [design.md](design.md).

| Decision                                     | Why                                                                                  |
| -------------------------------------------- | ------------------------------------------------------------------------------------ |
| Named Credentials only                       | Keeps secrets and endpoints out of code and makes Remote Site Settings unnecessary.  |
| HTTP errors are returned, not thrown         | A 404 is a valid answer for many APIs; exceptions are for "no answer".               |
| Idempotency-aware retries                    | Retrying a non-idempotent POST can duplicate side effects.                           |
| Immediate sync retries bounded by budget     | Apex has no sleep; a busy-wait consumes CPU limits for nothing.                      |
| Backoff only in async                        | `System.enqueueJob` with delay is the only real wait the platform offers (0–10 min). |
| Default policy `transientErrors()`           | Safe by default because non-idempotent methods are excluded anyway.                  |
| Response copied into `CallwiseResponse`      | `HttpResponse` is not serializable and cannot live in Queueable state.               |
| Async callbacks by `Type`                    | Callers cannot pass closures; the class name is serializable and validated up front. |
| Breaker state in Platform Cache, best effort | Only shared, low-latency store available without DML; atomicity is not available.    |
| `public`, no namespace                       | Distributed as an unlocked package without namespace; `global` is unnecessary.       |
| `inherited sharing`                          | Callwise does no SOQL/DML; it runs in the caller's sharing context.                  |
