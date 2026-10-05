# Callwise

[![CI](https://github.com/lightningcodetech/callwise/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/lightningcodetech/callwise/actions/workflows/ci.yml)
[![Apex coverage](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/lightningcodetech/e88955814d3eda9b2eedfc08e26c5749/raw/callwise-coverage.json)](https://github.com/lightningcodetech/callwise/actions/workflows/ci.yml)
[![License: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](LICENSE)

> Resilient REST callouts for Salesforce: idempotency-aware retries, governor-limit budgeting, async backoff,
> a circuit breaker per Named Credential and declarative test mocks. Zero dependencies.

Every org ends up hand-rolling the same wrapper around `Http.send()`: retries that duplicate POSTs, loops that
burn the 100-callout limit, `HttpCalloutMock` classes copied from test to test. Callwise is that wrapper, done once.

**Before**: retries written by hand, still unaware of limits, `Retry-After` or a failing endpoint.

```apex
HttpRequest req = new HttpRequest();
req.setEndpoint('callout:Stripe_API/v1/customers');
req.setMethod('POST');
req.setHeader('Content-Type', 'application/json');
req.setHeader('Idempotency-Key', order.Id);
req.setBody(JSON.serialize(new CustomerRequest(order), true));
req.setTimeout(10000);
HttpResponse res;
for (Integer attempt = 1; attempt <= 3; attempt++) {
    try {
        res = new Http().send(req);
        if (res.getStatusCode() < 500 && res.getStatusCode() != 429) {
            break;
        }
    } catch (CalloutException e) {
        if (attempt == 3) {
            throw e;
        }
    }
}
// ...and a hand-written HttpCalloutMock class with state for every test.
```

**After**: the same call, with retries bounded by the transaction's limits, a circuit breaker and a declarative mock.

```apex
CallwiseResponse res = Callwise.to('Stripe_API')
    .post('/v1/customers')
    .header('Idempotency-Key', order.Id)
    .jsonBody(new CustomerRequest(order))
    .send();
```

> **Version 0.1.** While Callwise is in `0.x`, minor versions may change the API; every change is listed in the
> [CHANGELOG](CHANGELOG.md). Full reference: [docs/API.md](docs/API.md).

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
3. **Circuit breaker settings (optional).** By default a Named Credential's circuit opens after 5 consecutive failures
   for 60 s. To change that, add a `Callwise Breaker` custom metadata record named after the Named Credential, with
   `FailureThreshold__c` and `OpenSeconds__c`.

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
    .header('Idempotency-Key', order.Id) // or .idempotent(); without a key, POST is never retried
    .jsonBody(new CustomerRequest(order))
    .retry(CallwiseRetryPolicy.transientErrors().maxAttempts(3))
    .send();

Customer created = res.isSuccess() ? (Customer) res.deserialize(Customer.class) : null;
```

### Send after DML, with real backoff

```apex
insert order;
Callwise.to('ERP')
    .post('/orders')
    .idempotent()
    .jsonBody(new OrderRequest(order))
    .sendAsync(OrderSyncCallback.class); // Queueable; waits 1, 2, 4… minutes between attempts

public class OrderSyncCallback implements Callwise.Callback {
    public void onResponse(CallwiseRequest request, CallwiseResponse response) {
        /* final response, any status; DML allowed here */
    }
    public void onFailure(CallwiseRequest request, CallwiseException failure) {
        /* no answer after every attempt */
    }
}
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
- Developer Edition and trial orgs allow at most 5 chained Queueables, so at most 5 async attempts there.
- `jsonBody()` omits null fields of Apex objects, but keeps null values inside a `Map`.
- No SOQL, no DML, negligible CPU.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

BSD-3-Clause. See [LICENSE](LICENSE).
