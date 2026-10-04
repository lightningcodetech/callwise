# Design decisions

Why Callwise works the way it does. Each decision records the problem, what was chosen, the alternatives that were
discarded and what it costs. [API.md](API.md) describes _what_ the API does; this document explains _why_.

Status: **Implemented** (in `main`) or **Planned** (decided, not built yet). Planned decisions are reviewed when they
are implemented.

| #                                                     | Decision                                         | Status      |
| ----------------------------------------------------- | ------------------------------------------------ | ----------- |
| [1](#1-named-credentials-only)                        | Named Credentials only                           | Implemented |
| [2](#2-http-errors-are-returned-not-thrown)           | HTTP errors are returned, not thrown             | Implemented |
| [3](#3-idempotency-aware-retries)                     | Idempotency-aware retries                        | Implemented |
| [4](#4-sync-retries-bounded-by-a-limits-budget)       | Sync retries are immediate and bounded by limits | Implemented |
| [5](#5-no-automatic-fallback-to-async)                | No automatic fallback to async                   | Implemented |
| [6](#6-real-backoff-only-in-async)                    | Real backoff only in async                       | Planned     |
| [7](#7-callwise-generated-idempotency-keys)           | Callwise-generated idempotency keys              | Implemented |
| [8](#8-circuit-breaker-in-platform-cache-best-effort) | Circuit breaker in Platform Cache, best effort   | Planned     |
| [9](#9-responses-are-copied-into-callwiseresponse)    | Responses are copied into `CallwiseResponse`     | Implemented |
| [10](#10-async-callbacks-by-type)                     | Async callbacks by `Type`                        | Planned     |
| [11](#11-declarative-mock-shipped-with-the-library)   | Declarative mock shipped with the library        | Implemented |
| [12](#12-public-no-namespace-inherited-sharing)       | `public`, no namespace, `inherited sharing`      | Implemented |

## 1. Named Credentials only

**Context.** Raw endpoints in Apex need Remote Site Settings and tend to carry credentials in code or custom
settings.

**Decision.** `Callwise.to()` takes the API name of a Named Credential and rejects anything that looks like a URL.
Paths are relative to the credential.

**Alternatives.** Accepting raw URLs as well, for convenience. Discarded: it would make the insecure path as easy as
the secure one, and every org that uses Callwise would need to audit which form is in use.

**Consequences.** Secrets and endpoints live in Setup, per environment, and can be rotated without a deploy. Setting
up a new API takes a few more clicks.

## 2. HTTP errors are returned, not thrown

**Context.** A 404 or 409 is a valid answer for many APIs ("not found", "already exists"). Exceptions make that
control flow awkward and expensive to write.

**Decision.** `send()` returns a `CallwiseResponse` for every status. Exceptions are reserved for "no answer":
transport failures, timeouts, an open circuit, no limits left, uncommitted work. `throwOnError()` opts in to an
`HTTP_ERROR` exception for callers that prefer it.

**Alternatives.** Throwing on every non-2xx status, like some HTTP clients do. Discarded: callers would wrap every
call in `try/catch` just to read a status code.

**Consequences.** Callers must check `isSuccess()`. The README examples always do.

## 3. Idempotency-aware retries

**Context.** A POST that times out may already have been processed: the request reached the server and the response
was lost. Retrying it blindly can create a second order or a second charge.

**Decision.** GET, HEAD, PUT and DELETE are retried. POST and PATCH are retried only when the request carries a
non-blank `Idempotency-Key` header (the server deduplicates with it) or the policy calls `allowNonIdempotent()`. The
default policy, `transientErrors()`, is therefore safe for every method.

**Alternatives.** Retrying every method on transient errors (simple, but unsafe for payments); never retrying POST
(safe, but useless for APIs that support idempotency keys, such as Stripe).

**Consequences.** A POST without a key fails on the first transient error, by design. The caller decides whether the
endpoint is safe to repeat. Decision [7](#7-callwise-generated-idempotency-keys) makes adding a key a one-liner.

## 4. Sync retries bounded by a limits budget

**Context.** Apex cannot sleep. A busy-wait burns CPU time without helping the server. Every attempt consumes one of
the 100 callouts of the transaction and up to its timeout from the 120 s of cumulative callout time; exceeding the
callout limit throws a `LimitException`, which cannot be caught.

**Decision.** Synchronous retries are immediate and only happen when the next attempt fits: one callout left and the
request timeout within the remaining callout time. Otherwise the engine stops and returns the last response (or
throws the last failure). If not even the first attempt has a callout left, `send()` throws `LIMIT_BUDGET` without
calling out. A `Retry-After` greater than 0 also stops sync retries: the server asked to wait and Apex cannot.

The platform does not expose the cumulative callout time, so Callwise counts the time spent in its own callouts.

**Alternatives.** Busy-wait backoff (wastes CPU, can hit the CPU limit); letting the platform fail on the limit
(uncatchable, loses the whole transaction).

**Consequences.** Sync retries help with brief glitches, not with an overloaded server; that is what async backoff is
for. Callouts made outside Callwise are not counted in the time budget.

## 5. No automatic fallback to async

**Context.** When the sync budget runs out, the engine could enqueue the request and retry it later.

**Decision.** It does not. `send()` returns the last response or throws the last failure. Callers that want retries
with real waits use `sendAsync()` explicitly.

**Alternatives.** Falling back to a Queueable automatically. Discarded: `send()` promises a response in the current
transaction; enqueueing silently would return nothing useful and hide the decision from the caller.

**Consequences.** One method, one behaviour. The caller chooses between an answer now (`send()`) and a reliable
answer later (`sendAsync()`).

## 6. Real backoff only in async

**Context.** The only real wait the platform offers is `System.enqueueJob(job, delayMinutes)`, between 0 and 10
minutes.

**Decision.** `sendAsync()` runs the request in a Queueable with `Database.AllowsCallouts`. On a retryable failure it
re-enqueues itself: `Retry-After` in seconds is rounded up to minutes; otherwise `base * 2^(attempt - 1)` minutes,
capped at 10.

**Alternatives.** Scheduled jobs (heavier, limited to 100 scheduled jobs per org); Platform Events with a retry
counter (needs subscribers and more metadata).

**Consequences.** One Queueable per attempt, subject to the async limits. Callbacks receive the final outcome in the
Queueable's transaction.

## 7. Callwise-generated idempotency keys

**Context.** The most common mistake with idempotency keys is generating a new one on every attempt, which defeats
the purpose.

**Decision.** `.idempotent()` generates a UUID v4 once, stores it as the request's `Idempotency-Key` header and
sends the same key on every attempt, sync and async. A non-blank key set by the caller is kept.

**Alternatives.** Leaving key management entirely to callers. Discarded: it is the error-prone part, and Callwise is
the component that knows when an attempt is a retry.

**Consequences.** The key travels with the serialized request into async jobs, so a retry three Queueables later
still uses the original key. It only lives in that request: a user clicking twice creates two requests and two keys.
To deduplicate across transactions, use a business key such as the record Id.

## 8. Circuit breaker in Platform Cache, best effort

**Context.** When an endpoint is down, every transaction keeps spending callouts and timeouts on it. The breaker
state has to be shared across transactions, and Apex has no shared memory.

**Decision.** One breaker per Named Credential: `CLOSED → OPEN` after 5 consecutive failures, `OPEN` for 60 s, then
`HALF_OPEN` lets one request through. State lives in an org Platform Cache partition behind a `Store` interface.

When the cache is unavailable (no partition, no capacity, evicted or expired entries), Callwise falls back to a
transaction-scoped store and warns through the logger. A cache problem never opens the circuit: requests go through.

**Alternatives.** Custom objects or custom settings (DML on every call, row locks, not allowed before callouts in the
same transaction); opening the circuit when the cache fails (blocks healthy endpoints because of a cache problem).

**Consequences.** Platform Cache has no atomic compare-and-set, so concurrent transactions can race on the failure
counter. The breaker reduces load on a failing endpoint; it does not guarantee an exact threshold. Every fallback
path is covered by tests.

## 9. Responses are copied into `CallwiseResponse`

**Context.** `HttpResponse` is not serializable, so it cannot live in the state of a Queueable.

**Decision.** The engine copies status, body and headers into `CallwiseResponse`, with case-insensitive header
lookup and the number of attempts and elapsed time.

**Alternatives.** Exposing `HttpResponse` directly. Discarded: it would make sync and async responses different
types.

**Consequences.** The body is held twice in memory for a moment, which matters only for very large responses.

## 10. Async callbacks by `Type`

**Context.** Apex has no closures, and the callback has to survive serialization into a Queueable.

**Decision.** `sendAsync(Type callbackType)` takes a class implementing `Callwise.Callback` with a public no-argument
constructor. It is validated when the request is sent, not when the job runs.

**Alternatives.** Passing a callback instance (its state would be serialized with the job and could be large or
stale); Platform Events for results (more metadata for a common case).

**Consequences.** Callbacks cannot capture local variables; they read what they need from the request and response.

## 11. Declarative mock shipped with the library

**Context.** Every org copies `HttpCalloutMock` implementations from test to test, and multi-step scenarios (503
then 200) need hand-written state machines.

**Decision.** `CallwiseMock` is a regular class, not `@IsTest`, so tests in the subscriber org can use it. Routes
match method and path with `*` wildcards, play responses in sequence and count requests.

**Alternatives.** Keeping the mock in a test-only class (not visible to subscriber tests in an unlocked package).

**Consequences.** The mock ships in the package and is covered by its own tests. It only works in test context
because it relies on `Test.setMock`.

## 12. `public`, no namespace, `inherited sharing`

**Context.** Callwise is distributed as an unlocked package without a namespace.

**Decision.** Classes are `public` (not `global`) and declared `inherited sharing`.

**Alternatives.** A namespaced managed package with `global` classes. Discarded for v0.x: `global` signatures can
never be removed, which would freeze the API before it has been used.

**Consequences.** Callwise runs in the caller's sharing context. It does no SOQL or DML, so sharing has no effect
today. A namespace can be introduced later as a major version.
