# Callwise

> Resilient REST callouts for Salesforce: idempotency-aware retries, governor-limit budgeting, async backoff,
> a circuit breaker per Named Credential and declarative test mocks. Zero dependencies.

Every org ends up hand-rolling the same wrapper around `Http.send()`: retries that duplicate POSTs, loops that
burn the 100-callout limit, `HttpCalloutMock` classes copied from test to test. Callwise is that wrapper, done once.

> **Status: v0.1 in progress.** The public API is in place. `send()` currently makes a single attempt; retries,
> the circuit breaker and `sendAsync()` are being implemented. See [docs/API.md](docs/API.md).

## Install

Install links for every version are published in [Releases](../../releases).

```bash
sf package install --package <04t...> --wait 10 --target-org <your-org>
```

Or deploy the source directly: `sf project deploy start --source-dir force-app --target-org <your-org>`.

## Setup

1. **Named Credential.** Callwise only calls Named Credentials, never raw URLs. Create the External Credential and
   Named Credential for your API in Setup, and grant the External Credential principal to the users (or the
   integration user) through a permission set.
2. **Platform Cache (optional, recommended).** Create an org cache partition named `Callwise` with a few KB of
   capacity to share circuit breaker state across transactions. Without it, the breaker only lives for the current
   transaction. Use another partition with `Callwise.setCachePartition('local.MyPartition')`.

## Usage

### Send a request

```apex
CallwiseResponse res = Callwise.to('Stripe_API') // Named Credential API name
    .get('/v1/customers')
    .param('email', email) // URL-encoded for you
    .timeout(10000)
    .send();

if (res.isSuccess()) {
    Map<String, Object> page = (Map<String, Object>) res.deserializeUntyped();
}
```

### POST safely with retries

```apex
CallwiseResponse res = Callwise.to('Stripe_API')
    .post('/v1/customers')
    .header('Idempotency-Key', order.Id) // without it, POST is never retried
    .jsonBody(new CustomerRequest(order))
    .retry(CallwiseRetryPolicy.transientErrors().maxAttempts(3))
    .send();

Customer created = res.isSuccess() ? (Customer) res.deserialize(Customer.class) : null;
```

### Handle errors

4xx and 5xx responses are returned, not thrown. Exceptions are reserved for "no answer": transport failures,
timeouts, an open circuit, or not enough limits left for another attempt.

```apex
try {
    CallwiseResponse res = Callwise.to('ERP').del('/orders/' + orderId).throwOnError().send();
} catch (CallwiseException e) {
    switch on e.reason {
        when HTTP_ERROR { /* e.response has status, headers and body */ }
        when UNCOMMITTED_WORK { /* DML ran first in this transaction: use sendAsync() */ }
        when else { /* TRANSPORT, TIMEOUT, CIRCUIT_OPEN, LIMIT_BUDGET... */ }
    }
}
```

### Test without hand-written mocks

```apex
@IsTest
static void createsCustomer() {
    CallwiseMock mock = new CallwiseMock()
        .whenRequest('POST', '/v1/customers')
        .thenRespond(201, '{"id":"cus_123"}')
        .install();

    Test.startTest();
    Customer created = new CustomerService().create(order); // code that uses Callwise
    Test.stopTest();

    Assert.areEqual('cus_123', created.id);
    Assert.areEqual(1, mock.countRequests('POST', '/v1/customers'));
}
```

Routes accept `*` wildcards, play responses in sequence (the last one repeats) and can simulate transport failures
with `thenThrow('Read timed out')`. Full reference, retry semantics and decision log: [docs/API.md](docs/API.md).

## Known limits

- One callout per attempt, from the transaction's 100; each attempt's timeout counts toward the 120 s cumulative limit.
- Synchronous retries are immediate (Apex cannot sleep). Real backoff only in `sendAsync()`, capped at 10 minutes.
- Callouts after uncommitted DML fail with `UNCOMMITTED_WORK`; use `sendAsync()`.
- The circuit breaker uses Platform Cache and is best effort (not atomic across concurrent transactions).
- `jsonBody()` omits null fields of Apex objects, but keeps null values inside a `Map`.
- No SOQL, no DML, negligible CPU.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

BSD-3-Clause. See [LICENSE](LICENSE).
