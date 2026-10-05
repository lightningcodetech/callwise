/**
 * @description Tests for CallwiseRetryPolicy: factories, validation, retry decisions and async backoff delays.
 */
@IsTest
private class CallwiseRetryPolicyTest {
    private static final Set<Integer> TRANSIENT_CODES = new Set<Integer>{ 408, 429, 500, 502, 503, 504 };

    @IsTest
    static void shouldMakeSingleAttemptWhenNone() {
        CallwiseRetryPolicy policy = CallwiseRetryPolicy.none();

        Assert.areEqual(1, policy.getMaxAttempts(), 'none() makes one attempt');
        Assert.isTrue(policy.getRetryableStatusCodes().isEmpty(), 'none() retries no status');
        Assert.isFalse(policy.retriesTransportErrors(), 'none() does not retry transport errors');
        Assert.isFalse(policy.allowsNonIdempotent(), 'Non-idempotent retries are off by default');
        Assert.areEqual(1, policy.getAsyncBaseDelayMinutes(), 'Default async base delay is 1 minute');
    }

    @IsTest
    static void shouldUseTransientDefaultsWhenTransientErrors() {
        CallwiseRetryPolicy policy = CallwiseRetryPolicy.transientErrors();

        Assert.areEqual(3, policy.getMaxAttempts(), 'transientErrors() makes 3 attempts');
        Assert.areEqual(TRANSIENT_CODES, policy.getRetryableStatusCodes(), 'Transient status codes');
        Assert.isTrue(policy.retriesTransportErrors(), 'transientErrors() retries transport errors');
    }

    @IsTest
    static void shouldSetMaxAttemptsWhenInRange() {
        CallwiseRetryPolicy policy = CallwiseRetryPolicy.none().maxAttempts(CallwiseRetryPolicy.MAX_ATTEMPTS_LIMIT);

        Assert.areEqual(CallwiseRetryPolicy.MAX_ATTEMPTS_LIMIT, policy.getMaxAttempts(), 'Upper bound is allowed');
    }

    @IsTest
    static void shouldRejectMaxAttemptsWhenZero() {
        assertInvalid(CallwiseRetryPolicy.none(), 'maxAttempts', 0);
    }

    @IsTest
    static void shouldRejectMaxAttemptsWhenAboveLimit() {
        assertInvalid(CallwiseRetryPolicy.none(), 'maxAttempts', CallwiseRetryPolicy.MAX_ATTEMPTS_LIMIT + 1);
    }

    @IsTest
    static void shouldRejectMaxAttemptsWhenNull() {
        assertInvalid(CallwiseRetryPolicy.none(), 'maxAttempts', null);
    }

    @IsTest
    static void shouldReplaceStatusCodesWhenRetryOn() {
        Set<Integer> codes = new Set<Integer>{ 503 };
        CallwiseRetryPolicy policy = CallwiseRetryPolicy.transientErrors().retryOn(codes);
        codes.add(500);

        Assert.areEqual(new Set<Integer>{ 503 }, policy.getRetryableStatusCodes(), 'Set should be copied');
    }

    @IsTest
    static void shouldRejectRetryOnWhenNull() {
        try {
            CallwiseRetryPolicy.none().retryOn(null);
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.INVALID_REQUEST, e.reason, 'Null set is invalid');
        }
    }

    @IsTest
    static void shouldRejectAsyncBaseDelayWhenNegative() {
        assertInvalid(CallwiseRetryPolicy.none(), 'asyncBaseDelay', -1);
    }

    @IsTest
    static void shouldRejectAsyncBaseDelayWhenAboveLimit() {
        assertInvalid(CallwiseRetryPolicy.none(), 'asyncBaseDelay', CallwiseRetryPolicy.MAX_ASYNC_DELAY_MINUTES + 1);
    }

    @IsTest
    static void shouldRetryIdempotentRequestWhenStatusIsRetryable() {
        CallwiseRetryPolicy policy = CallwiseRetryPolicy.transientErrors();

        Assert.isTrue(policy.isRetryable(Callwise.to('API').get('/a'), response(503, null), null), '503 GET');
    }

    @IsTest
    static void shouldNotRetryWhenStatusIsNotRetryable() {
        CallwiseRetryPolicy policy = CallwiseRetryPolicy.transientErrors();

        Assert.isFalse(policy.isRetryable(Callwise.to('API').get('/a'), response(404, null), null), '404 GET');
    }

    @IsTest
    static void shouldNotRetryPostWhenNoIdempotencyKey() {
        CallwiseRetryPolicy policy = CallwiseRetryPolicy.transientErrors();

        Assert.isFalse(policy.isRetryable(Callwise.to('API').post('/a'), response(503, null), null), 'Plain POST');
    }

    @IsTest
    static void shouldRetryPostWhenIdempotencyKeyPresent() {
        CallwiseRetryPolicy policy = CallwiseRetryPolicy.transientErrors();
        CallwiseRequest request = Callwise.to('API').post('/a').header('Idempotency-Key', 'k1');

        Assert.isTrue(policy.isRetryable(request, response(503, null), null), 'POST with key');
    }

    @IsTest
    static void shouldRetryPostWhenNonIdempotentAllowed() {
        CallwiseRetryPolicy policy = CallwiseRetryPolicy.transientErrors().allowNonIdempotent();

        Assert.isTrue(policy.isRetryable(Callwise.to('API').patch('/a'), response(503, null), null), 'PATCH allowed');
    }

    @IsTest
    static void shouldRetryTransportAndTimeoutWhenTransientErrors() {
        CallwiseRetryPolicy policy = CallwiseRetryPolicy.transientErrors();
        CallwiseRequest request = Callwise.to('API').get('/a');

        Assert.isTrue(
            policy.isRetryable(request, null, failure(CallwiseException.FailureReason.TRANSPORT)),
            'TRANSPORT'
        );
        Assert.isTrue(policy.isRetryable(request, null, failure(CallwiseException.FailureReason.TIMEOUT)), 'TIMEOUT');
    }

    @IsTest
    static void shouldNotRetryOtherFailures() {
        CallwiseRetryPolicy policy = CallwiseRetryPolicy.transientErrors();
        CallwiseRequest request = Callwise.to('API').get('/a');

        Assert.isFalse(
            policy.isRetryable(request, null, failure(CallwiseException.FailureReason.CIRCUIT_OPEN)),
            'CIRCUIT_OPEN is not retried'
        );
    }

    @IsTest
    static void shouldNotRetryTransportWhenPolicyIsNone() {
        CallwiseRetryPolicy policy = CallwiseRetryPolicy.none();

        Assert.isFalse(
            policy.isRetryable(Callwise.to('API').get('/a'), null, failure(CallwiseException.FailureReason.TRANSPORT)),
            'none() does not retry transport errors'
        );
    }

    @IsTest
    static void shouldNotRetryWhenRequestIsNull() {
        Assert.isFalse(CallwiseRetryPolicy.transientErrors().isRetryable(null, response(503, null), null), 'Null');
    }

    @IsTest
    static void shouldNotRetryWhenNeitherResponseNorFailure() {
        Assert.isFalse(
            CallwiseRetryPolicy.transientErrors().isRetryable(Callwise.to('API').get('/a'), null, null),
            'Nothing to evaluate'
        );
    }

    @IsTest
    static void shouldBackOffExponentially() {
        CallwiseRetryPolicy policy = CallwiseRetryPolicy.transientErrors().asyncBaseDelay(1);

        Assert.areEqual(1, policy.asyncDelayMinutes(1, null), 'Attempt 1 waits base');
        Assert.areEqual(2, policy.asyncDelayMinutes(2, null), 'Attempt 2 waits 2x base');
        Assert.areEqual(4, policy.asyncDelayMinutes(3, null), 'Attempt 3 waits 4x base');
    }

    @IsTest
    static void shouldCapBackoffWhenAttemptIsLarge() {
        CallwiseRetryPolicy policy = CallwiseRetryPolicy.transientErrors().asyncBaseDelay(3);

        Assert.areEqual(10, policy.asyncDelayMinutes(50, null), 'Delay is capped at 10 minutes');
    }

    @IsTest
    static void shouldNotDelayWhenBaseIsZero() {
        CallwiseRetryPolicy policy = CallwiseRetryPolicy.transientErrors().asyncBaseDelay(0);

        Assert.areEqual(0, policy.asyncDelayMinutes(5, null), 'Zero base never waits');
    }

    @IsTest
    static void shouldUseBaseWhenAttemptIsNull() {
        CallwiseRetryPolicy policy = CallwiseRetryPolicy.transientErrors().asyncBaseDelay(2);

        Assert.areEqual(2, policy.asyncDelayMinutes(null, null), 'Null attempt is treated as the first');
    }

    @IsTest
    static void shouldRoundRetryAfterUpToMinutes() {
        CallwiseRetryPolicy policy = CallwiseRetryPolicy.transientErrors();

        Assert.areEqual(2, policy.asyncDelayMinutes(1, response(429, '61')), '61 s rounds up to 2 minutes');
        Assert.areEqual(0, policy.asyncDelayMinutes(1, response(429, '0')), '0 s means no delay');
    }

    @IsTest
    static void shouldCapRetryAfter() {
        CallwiseRetryPolicy policy = CallwiseRetryPolicy.transientErrors();

        Assert.areEqual(10, policy.asyncDelayMinutes(1, response(429, '3600')), 'Retry-After is capped at 10 minutes');
    }

    private static void assertInvalid(CallwiseRetryPolicy policy, String setter, Integer value) {
        try {
            if (setter == 'maxAttempts') {
                policy.maxAttempts(value);
            } else {
                policy.asyncBaseDelay(value);
            }
            Assert.fail('Expected CallwiseException for ' + setter + '(' + value + ')');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.INVALID_REQUEST, e.reason, 'Out of range is invalid');
        }
    }

    private static CallwiseException failure(CallwiseException.FailureReason reason) {
        return CallwiseException.create(reason, 'test');
    }

    private static CallwiseResponse response(Integer statusCode, String retryAfter) {
        HttpResponse raw = new HttpResponse();
        raw.setStatusCode(statusCode);
        if (retryAfter != null) {
            raw.setHeader('Retry-After', retryAfter);
        }
        return new CallwiseResponse(raw, 1, 0L);
    }
}
