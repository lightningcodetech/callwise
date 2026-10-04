@IsTest
private class CallwiseCircuitBreakerTest {
    private static final String NAMED_CREDENTIAL = 'Test_API';
    private static final Long T0 = 1700000000000L;

    @IsTest
    static void shouldStayClosed_BelowThreshold() {
        CallwiseCircuitBreaker breaker = newBreaker();

        fail(breaker, CallwiseCircuitBreaker.FAILURE_THRESHOLD - 1);

        Assert.areEqual(
            CallwiseCircuitBreaker.CircuitStatus.CLOSED,
            breaker.getStatus(),
            'Below threshold stays closed'
        );
        Assert.isTrue(breaker.allowRequest(), 'Closed circuit allows requests');
        Assert.areEqual(0, breaker.secondsUntilTrial(), 'No trial wait while closed');
    }

    @IsTest
    static void shouldOpen_AtThreshold() {
        CallwiseCircuitBreaker breaker = newBreaker();

        fail(breaker, CallwiseCircuitBreaker.FAILURE_THRESHOLD);

        Assert.areEqual(CallwiseCircuitBreaker.CircuitStatus.OPEN, breaker.getStatus(), 'Threshold opens the circuit');
        Assert.isFalse(breaker.allowRequest(), 'Open circuit rejects requests');
        Assert.areEqual(60, breaker.secondsUntilTrial(), 'Full open period remains');
    }

    @IsTest
    static void shouldResetFailureCount_OnSuccess() {
        CallwiseCircuitBreaker breaker = newBreaker();

        fail(breaker, CallwiseCircuitBreaker.FAILURE_THRESHOLD - 1);
        breaker.record(response(200), null);
        fail(breaker, CallwiseCircuitBreaker.FAILURE_THRESHOLD - 1);

        Assert.areEqual(
            CallwiseCircuitBreaker.CircuitStatus.CLOSED,
            breaker.getStatus(),
            'Failures must be consecutive'
        );
    }

    @IsTest
    static void shouldRejectRequests_UntilOpenPeriodEnds() {
        CallwiseCircuitBreaker breaker = openBreaker();

        CallwiseCircuitBreaker.nowOverride = T0 + CallwiseCircuitBreaker.OPEN_DURATION_MS - 500;

        Assert.isFalse(breaker.allowRequest(), 'Still open just before the end of the period');
        Assert.areEqual(1, breaker.secondsUntilTrial(), 'Remaining time is rounded up to whole seconds');
    }

    @IsTest
    static void shouldAllowOneTrial_AfterOpenPeriod() {
        CallwiseCircuitBreaker breaker = openBreaker();

        CallwiseCircuitBreaker.nowOverride = T0 + CallwiseCircuitBreaker.OPEN_DURATION_MS;

        Assert.isTrue(breaker.allowRequest(), 'First request after the period is the trial');
        Assert.areEqual(CallwiseCircuitBreaker.CircuitStatus.HALF_OPEN, breaker.getStatus(), 'Trial in progress');
        Assert.isFalse(breaker.allowRequest(), 'Only one trial at a time');
        Assert.areEqual(0, breaker.secondsUntilTrial(), 'No open wait while half-open');
    }

    @IsTest
    static void shouldClose_WhenTrialSucceeds() {
        CallwiseCircuitBreaker breaker = openBreaker();
        CallwiseCircuitBreaker.nowOverride = T0 + CallwiseCircuitBreaker.OPEN_DURATION_MS;
        breaker.allowRequest();

        breaker.record(response(204), null);

        Assert.areEqual(CallwiseCircuitBreaker.CircuitStatus.CLOSED, breaker.getStatus(), 'Successful trial closes');
        Assert.isTrue(breaker.allowRequest(), 'Closed circuit allows requests');
    }

    @IsTest
    static void shouldReopen_WhenTrialFails() {
        CallwiseCircuitBreaker breaker = openBreaker();
        Long trialAt = T0 + CallwiseCircuitBreaker.OPEN_DURATION_MS;
        CallwiseCircuitBreaker.nowOverride = trialAt;
        breaker.allowRequest();

        breaker.record(response(503), null);

        Assert.areEqual(CallwiseCircuitBreaker.CircuitStatus.OPEN, breaker.getStatus(), 'Failed trial reopens');
        Assert.isFalse(breaker.allowRequest(), 'Reopened circuit rejects requests');
        Assert.areEqual(60, breaker.secondsUntilTrial(), 'A new open period starts at the failed trial');
    }

    @IsTest
    static void shouldAllowNewTrial_WhenPreviousTrialNeverReported() {
        CallwiseCircuitBreaker breaker = openBreaker();
        Long trialAt = T0 + CallwiseCircuitBreaker.OPEN_DURATION_MS;
        CallwiseCircuitBreaker.nowOverride = trialAt;
        breaker.allowRequest();

        CallwiseCircuitBreaker.nowOverride = trialAt + CallwiseCircuitBreaker.OPEN_DURATION_MS;

        Assert.isTrue(breaker.allowRequest(), 'A lost trial is replaced after the same wait');
    }

    @IsTest
    static void shouldCountServerErrors_AsFailures() {
        for (Integer statusCode : new List<Integer>{ 500, 502, 503, 504, 408, 429 }) {
            CallwiseCircuitBreaker breaker = new CallwiseCircuitBreaker('Status_' + statusCode);
            for (Integer i = 0; i < CallwiseCircuitBreaker.FAILURE_THRESHOLD; i++) {
                breaker.record(response(statusCode), null);
            }
            Assert.areEqual(
                CallwiseCircuitBreaker.CircuitStatus.OPEN,
                breaker.getStatus(),
                statusCode + ' is a failure'
            );
        }
    }

    @IsTest
    static void shouldCountClientErrors_AsSuccess() {
        CallwiseCircuitBreaker breaker = newBreaker();
        fail(breaker, CallwiseCircuitBreaker.FAILURE_THRESHOLD - 1);

        breaker.record(response(404), null);
        fail(breaker, 1);

        Assert.areEqual(
            CallwiseCircuitBreaker.CircuitStatus.CLOSED,
            breaker.getStatus(),
            '404 means the endpoint answered'
        );
    }

    @IsTest
    static void shouldCountTimeouts_AsFailures() {
        CallwiseCircuitBreaker breaker = newBreaker();

        for (Integer i = 0; i < CallwiseCircuitBreaker.FAILURE_THRESHOLD; i++) {
            breaker.record(null, failure(CallwiseException.FailureReason.TIMEOUT));
        }

        Assert.areEqual(CallwiseCircuitBreaker.CircuitStatus.OPEN, breaker.getStatus(), 'Timeouts open the circuit');
    }

    @IsTest
    static void shouldIgnoreFailures_UnrelatedToEndpointHealth() {
        CallwiseCircuitBreaker breaker = newBreaker();

        for (Integer i = 0; i < CallwiseCircuitBreaker.FAILURE_THRESHOLD; i++) {
            breaker.record(null, failure(CallwiseException.FailureReason.UNCOMMITTED_WORK));
            breaker.record(null, failure(CallwiseException.FailureReason.LIMIT_BUDGET));
            breaker.record(null, null);
        }

        Assert.areEqual(CallwiseCircuitBreaker.CircuitStatus.CLOSED, breaker.getStatus(), 'Not the endpoint failing');
    }

    @IsTest
    static void shouldKeepSeparateState_PerNamedCredential() {
        CallwiseCircuitBreaker failing = openBreaker();
        CallwiseCircuitBreaker healthy = new CallwiseCircuitBreaker('Other_API');

        Assert.areEqual(CallwiseCircuitBreaker.CircuitStatus.OPEN, failing.getStatus(), 'Failing credential is open');
        Assert.isTrue(healthy.allowRequest(), 'Other credentials are not affected');
    }

    @IsTest
    static void shouldShareState_BetweenInstancesOfSameCredential() {
        openBreaker();

        Assert.isFalse(newBreaker().allowRequest(), 'State is per credential, not per instance');
    }

    @IsTest
    static void shouldDescribeOpenCircuit() {
        CallwiseException failure = openBreaker().openCircuitException();

        Assert.areEqual(CallwiseException.FailureReason.CIRCUIT_OPEN, failure.reason, 'Reason should be CIRCUIT_OPEN');
        Assert.isTrue(failure.getMessage().contains(NAMED_CREDENTIAL), 'Message names the credential');
        Assert.isTrue(failure.getMessage().contains('60 s'), 'Message gives the wait: ' + failure.getMessage());
    }

    @IsTest
    static void shouldNeverOpen_WhenStoreLosesState() {
        CallwiseCircuitBreaker.storeOverride = new EvictingStore();
        CallwiseCircuitBreaker breaker = newBreaker();

        fail(breaker, CallwiseCircuitBreaker.FAILURE_THRESHOLD * 2);

        Assert.isTrue(breaker.allowRequest(), 'A store that loses entries never opens the circuit');
    }

    @IsTest
    static void shouldFallBackToTransactionStore_WhenPartitionIsMissing() {
        CallwiseCircuitBreaker.usePlatformCacheInTests = true;
        Callwise.setCachePartition('local.CallwiseMissingPartition');
        CallwiseCircuitBreaker breaker = newBreaker();

        fail(breaker, CallwiseCircuitBreaker.FAILURE_THRESHOLD);

        Assert.isTrue(CallwiseCircuitBreaker.warned, 'A warning is written once');
        Assert.areEqual(
            CallwiseCircuitBreaker.CircuitStatus.OPEN,
            breaker.getStatus(),
            'Breaker works for the transaction'
        );
        Assert.isFalse(newBreaker().allowRequest(), 'State is shared within the transaction');
    }

    @IsTest
    static void shouldKeepWorking_WhenSwitchingToAnotherMissingPartition() {
        CallwiseCircuitBreaker.usePlatformCacheInTests = true;
        Callwise.setCachePartition('local.CallwiseMissingPartition');
        fail(newBreaker(), CallwiseCircuitBreaker.FAILURE_THRESHOLD - 1);

        Callwise.setCachePartition('local.AnotherMissingPartition');
        fail(newBreaker(), 1);

        Assert.isTrue(CallwiseCircuitBreaker.warned, 'The warning is written once per transaction');
        Assert.areEqual(
            CallwiseCircuitBreaker.CircuitStatus.OPEN,
            newBreaker().getStatus(),
            'Both fallbacks share the transaction store'
        );
    }

    private static CallwiseCircuitBreaker newBreaker() {
        return new CallwiseCircuitBreaker(NAMED_CREDENTIAL);
    }

    private static CallwiseCircuitBreaker openBreaker() {
        CallwiseCircuitBreaker.nowOverride = T0;
        CallwiseCircuitBreaker breaker = newBreaker();
        fail(breaker, CallwiseCircuitBreaker.FAILURE_THRESHOLD);
        return breaker;
    }

    private static void fail(CallwiseCircuitBreaker breaker, Integer times) {
        for (Integer i = 0; i < times; i++) {
            breaker.record(null, failure(CallwiseException.FailureReason.TRANSPORT));
        }
    }

    private static CallwiseException failure(CallwiseException.FailureReason reason) {
        return CallwiseException.create(reason, 'test');
    }

    private static CallwiseResponse response(Integer statusCode) {
        HttpResponse raw = new HttpResponse();
        raw.setStatusCode(statusCode);
        return new CallwiseResponse(raw, 1, 0L);
    }

    private class EvictingStore implements CallwiseCircuitBreaker.Store {
        public CallwiseCircuitBreaker.State get(String key) {
            return null;
        }

        public void put(String key, CallwiseCircuitBreaker.State state) {
            return;
        }
    }
}
