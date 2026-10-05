/**
 * @description Tests for CallwiseCircuitBreaker: state transitions, failure classification, per-credential state,
 * CallwiseBreaker__mdt settings and the Platform Cache fallback.
 */
@IsTest
private class CallwiseCircuitBreakerTest {
    private static final String NAMED_CREDENTIAL = 'Test_API';
    private static final Long T0 = 1700000000000L;

    @IsTest
    static void shouldStayClosedBelowThreshold() {
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
    static void shouldOpenAtThreshold() {
        CallwiseCircuitBreaker breaker = newBreaker();

        fail(breaker, CallwiseCircuitBreaker.FAILURE_THRESHOLD);

        Assert.areEqual(CallwiseCircuitBreaker.CircuitStatus.OPEN, breaker.getStatus(), 'Threshold opens the circuit');
        Assert.isFalse(breaker.allowRequest(), 'Open circuit rejects requests');
        Assert.areEqual(60, breaker.secondsUntilTrial(), 'Full open period remains');
    }

    @IsTest
    static void shouldResetFailureCountOnSuccess() {
        CallwiseCircuitBreaker breaker = newBreaker();

        fail(breaker, CallwiseCircuitBreaker.FAILURE_THRESHOLD - 1);
        breaker.record(CallwiseTestData.response(200), null);
        fail(breaker, CallwiseCircuitBreaker.FAILURE_THRESHOLD - 1);

        Assert.areEqual(
            CallwiseCircuitBreaker.CircuitStatus.CLOSED,
            breaker.getStatus(),
            'Failures must be consecutive'
        );
    }

    @IsTest
    static void shouldRejectRequestsUntilOpenPeriodEnds() {
        CallwiseCircuitBreaker breaker = openBreaker();

        CallwiseCircuitBreaker.nowOverride = T0 + CallwiseCircuitBreaker.OPEN_DURATION_MS - 500;

        Assert.isFalse(breaker.allowRequest(), 'Still open just before the end of the period');
        Assert.areEqual(1, breaker.secondsUntilTrial(), 'Remaining time is rounded up to whole seconds');
    }

    @IsTest
    static void shouldAllowOneTrialAfterOpenPeriod() {
        CallwiseCircuitBreaker breaker = openBreaker();

        CallwiseCircuitBreaker.nowOverride = T0 + CallwiseCircuitBreaker.OPEN_DURATION_MS;

        Assert.isTrue(breaker.allowRequest(), 'First request after the period is the trial');
        Assert.areEqual(CallwiseCircuitBreaker.CircuitStatus.HALF_OPEN, breaker.getStatus(), 'Trial in progress');
        Assert.isFalse(breaker.allowRequest(), 'Only one trial at a time');
        Assert.areEqual(0, breaker.secondsUntilTrial(), 'No open wait while half-open');
    }

    @IsTest
    static void shouldCloseWhenTrialSucceeds() {
        CallwiseCircuitBreaker breaker = openBreaker();
        CallwiseCircuitBreaker.nowOverride = T0 + CallwiseCircuitBreaker.OPEN_DURATION_MS;
        breaker.allowRequest();

        breaker.record(CallwiseTestData.response(204), null);

        Assert.areEqual(CallwiseCircuitBreaker.CircuitStatus.CLOSED, breaker.getStatus(), 'Successful trial closes');
        Assert.isTrue(breaker.allowRequest(), 'Closed circuit allows requests');
    }

    @IsTest
    static void shouldReopenWhenTrialFails() {
        CallwiseCircuitBreaker breaker = openBreaker();
        Long trialAt = T0 + CallwiseCircuitBreaker.OPEN_DURATION_MS;
        CallwiseCircuitBreaker.nowOverride = trialAt;
        breaker.allowRequest();

        breaker.record(CallwiseTestData.response(503), null);

        Assert.areEqual(CallwiseCircuitBreaker.CircuitStatus.OPEN, breaker.getStatus(), 'Failed trial reopens');
        Assert.isFalse(breaker.allowRequest(), 'Reopened circuit rejects requests');
        Assert.areEqual(60, breaker.secondsUntilTrial(), 'A new open period starts at the failed trial');
    }

    @IsTest
    static void shouldAllowNewTrialWhenPreviousTrialNeverReported() {
        CallwiseCircuitBreaker breaker = openBreaker();
        Long trialAt = T0 + CallwiseCircuitBreaker.OPEN_DURATION_MS;
        CallwiseCircuitBreaker.nowOverride = trialAt;
        breaker.allowRequest();

        CallwiseCircuitBreaker.nowOverride = trialAt + CallwiseCircuitBreaker.OPEN_DURATION_MS;

        Assert.isTrue(breaker.allowRequest(), 'A lost trial is replaced after the same wait');
    }

    @IsTest
    static void shouldCountServerErrorsAsFailures() {
        for (Integer statusCode : new List<Integer>{ 500, 502, 503, 504, 408, 429 }) {
            CallwiseCircuitBreaker breaker = new CallwiseCircuitBreaker('Status_' + statusCode);
            for (Integer i = 0; i < CallwiseCircuitBreaker.FAILURE_THRESHOLD; i++) {
                breaker.record(CallwiseTestData.response(statusCode), null);
            }
            Assert.areEqual(
                CallwiseCircuitBreaker.CircuitStatus.OPEN,
                breaker.getStatus(),
                statusCode + ' is a failure'
            );
        }
    }

    @IsTest
    static void shouldCountClientErrorsAsSuccess() {
        CallwiseCircuitBreaker breaker = newBreaker();
        fail(breaker, CallwiseCircuitBreaker.FAILURE_THRESHOLD - 1);

        breaker.record(CallwiseTestData.response(404), null);
        fail(breaker, 1);

        Assert.areEqual(
            CallwiseCircuitBreaker.CircuitStatus.CLOSED,
            breaker.getStatus(),
            '404 means the endpoint answered'
        );
    }

    @IsTest
    static void shouldCountTimeoutsAsFailures() {
        CallwiseCircuitBreaker breaker = newBreaker();

        for (Integer i = 0; i < CallwiseCircuitBreaker.FAILURE_THRESHOLD; i++) {
            breaker.record(null, CallwiseTestData.failure(CallwiseException.FailureReason.TIMEOUT));
        }

        Assert.areEqual(CallwiseCircuitBreaker.CircuitStatus.OPEN, breaker.getStatus(), 'Timeouts open the circuit');
    }

    @IsTest
    static void shouldIgnoreFailuresUnrelatedToEndpointHealth() {
        CallwiseCircuitBreaker breaker = newBreaker();

        for (Integer i = 0; i < CallwiseCircuitBreaker.FAILURE_THRESHOLD; i++) {
            breaker.record(null, CallwiseTestData.failure(CallwiseException.FailureReason.UNCOMMITTED_WORK));
            breaker.record(null, CallwiseTestData.failure(CallwiseException.FailureReason.LIMIT_BUDGET));
            breaker.record(null, null);
        }

        Assert.areEqual(CallwiseCircuitBreaker.CircuitStatus.CLOSED, breaker.getStatus(), 'Not the endpoint failing');
    }

    @IsTest
    static void shouldKeepSeparateStatePerNamedCredential() {
        CallwiseCircuitBreaker failing = openBreaker();
        CallwiseCircuitBreaker healthy = new CallwiseCircuitBreaker('Other_API');

        Assert.areEqual(CallwiseCircuitBreaker.CircuitStatus.OPEN, failing.getStatus(), 'Failing credential is open');
        Assert.isTrue(healthy.allowRequest(), 'Other credentials are not affected');
    }

    @IsTest
    static void shouldShareStateBetweenInstancesOfSameCredential() {
        openBreaker();

        Assert.isFalse(newBreaker().allowRequest(), 'State is per credential, not per instance');
    }

    @IsTest
    static void shouldDescribeOpenCircuit() {
        CallwiseException failure = openBreaker().openCircuitException();

        Assert.areEqual(CallwiseException.FailureReason.CIRCUIT_OPEN, failure.reason, 'Reason should be CIRCUIT_OPEN');
        Assert.isTrue(failure.getMessage().contains(NAMED_CREDENTIAL), 'Message names the credential');
        Assert.areEqual(
            'Circuit open for Test_API after repeated failures; no callout was made. Next trial in about 60 s.',
            failure.getMessage(),
            'Exact message'
        );
    }

    @IsTest
    static void shouldWriteLongWaitsWithoutThousandsSeparator() {
        configure(NAMED_CREDENTIAL, null, CallwiseCircuitBreaker.MAX_OPEN_SECONDS);

        CallwiseException failure = openBreaker().openCircuitException();

        Assert.isTrue(failure.getMessage().endsWith('Next trial in about 3600 s.'), 'Got: ' + failure.getMessage());
    }

    @IsTest
    static void shouldNeverOpenWhenStoreLosesState() {
        CallwiseCircuitBreaker.storeOverride = new EvictingStore();
        CallwiseCircuitBreaker breaker = newBreaker();

        fail(breaker, CallwiseCircuitBreaker.FAILURE_THRESHOLD * 2);

        Assert.isTrue(breaker.allowRequest(), 'A store that loses entries never opens the circuit');
    }

    @IsTest
    static void shouldFallBackToTransactionStoreWhenPartitionIsMissing() {
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
    static void shouldKeepWorkingWhenSwitchingToAnotherMissingPartition() {
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

    // ---------------------------------------------------------------------------------------------------------
    // Settings (CallwiseBreaker__mdt)
    // ---------------------------------------------------------------------------------------------------------

    @IsTest
    static void shouldUseDefaultsWhenNoSettingsRecordExists() {
        CallwiseCircuitBreaker breaker = new CallwiseCircuitBreaker('No_Record_For_This_Credential');

        Assert.areEqual(CallwiseCircuitBreaker.FAILURE_THRESHOLD, breaker.getFailureThreshold(), 'Default threshold');
        Assert.areEqual(
            (Long) CallwiseCircuitBreaker.OPEN_DURATION_MS,
            breaker.getOpenDurationMs(),
            'Default open period'
        );
    }

    @IsTest
    static void shouldOpenAtConfiguredThreshold() {
        configure(NAMED_CREDENTIAL, 2, null);
        CallwiseCircuitBreaker breaker = newBreaker();

        fail(breaker, 1);
        CallwiseCircuitBreaker.CircuitStatus afterOne = breaker.getStatus();
        fail(breaker, 1);

        Assert.areEqual(CallwiseCircuitBreaker.CircuitStatus.CLOSED, afterOne, 'One failure is below the threshold');
        Assert.areEqual(CallwiseCircuitBreaker.CircuitStatus.OPEN, breaker.getStatus(), 'Two failures open it');
        Assert.areEqual(60, breaker.secondsUntilTrial(), 'Open period keeps its default');
    }

    @IsTest
    static void shouldStayOpenForConfiguredSeconds() {
        configure(NAMED_CREDENTIAL, null, 120);
        CallwiseCircuitBreaker breaker = openBreaker();

        CallwiseCircuitBreaker.nowOverride = T0 + 119000;
        Boolean allowedBefore = breaker.allowRequest();
        CallwiseCircuitBreaker.nowOverride = T0 + 120000;

        Assert.isFalse(allowedBefore, 'Still open at 119 s');
        Assert.isTrue(breaker.allowRequest(), 'Trial allowed at 120 s');
        Assert.areEqual(
            CallwiseCircuitBreaker.FAILURE_THRESHOLD,
            breaker.getFailureThreshold(),
            'Threshold keeps its default'
        );
    }

    @IsTest
    static void shouldIgnoreOutOfRangeSettings() {
        Map<Decimal, Decimal> thresholdAndSeconds = new Map<Decimal, Decimal>{
            0 => 0,
            -1 => -60,
            101 => 3601,
            2.5 => 90.5
        };

        for (Decimal threshold : thresholdAndSeconds.keySet()) {
            configure(NAMED_CREDENTIAL, threshold, thresholdAndSeconds.get(threshold));
            CallwiseCircuitBreaker breaker = newBreaker();

            Assert.areEqual(
                CallwiseCircuitBreaker.FAILURE_THRESHOLD,
                breaker.getFailureThreshold(),
                'Threshold ' + threshold + ' falls back to the default'
            );
            Assert.areEqual(
                (Long) CallwiseCircuitBreaker.OPEN_DURATION_MS,
                breaker.getOpenDurationMs(),
                'Open seconds ' + thresholdAndSeconds.get(threshold) + ' fall back to the default'
            );
        }
    }

    @IsTest
    static void shouldAcceptLimitValues() {
        configure(
            NAMED_CREDENTIAL,
            CallwiseCircuitBreaker.MAX_FAILURE_THRESHOLD,
            CallwiseCircuitBreaker.MAX_OPEN_SECONDS
        );
        CallwiseCircuitBreaker breaker = newBreaker();

        Assert.areEqual(100, breaker.getFailureThreshold(), 'Largest threshold accepted');
        Assert.areEqual(3600000L, breaker.getOpenDurationMs(), 'Largest open period accepted');
    }

    @IsTest
    static void shouldApplySettingsOnlyToTheirNamedCredential() {
        configure('Payments_API', 1, 300);

        Assert.areEqual(1, new CallwiseCircuitBreaker('Payments_API').getFailureThreshold(), 'Configured credential');
        Assert.areEqual(
            CallwiseCircuitBreaker.FAILURE_THRESHOLD,
            newBreaker().getFailureThreshold(),
            'Other credentials keep the defaults'
        );
    }

    private static void configure(String namedCredential, Decimal threshold, Decimal openSeconds) {
        Map<String, Object> fields = new Map<String, Object>{
            'DeveloperName' => namedCredential,
            'FailureThreshold__c' => threshold,
            'OpenSeconds__c' => openSeconds
        };
        CallwiseCircuitBreaker.settingsOverride = new Map<String, CallwiseBreaker__mdt>{
            namedCredential => (CallwiseBreaker__mdt) JSON.deserialize(
                JSON.serialize(fields),
                CallwiseBreaker__mdt.class
            )
        };
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
            breaker.record(null, CallwiseTestData.failure(CallwiseException.FailureReason.TRANSPORT));
        }
    }

    /**
     * @description Store that loses every entry, like a cache that evicts immediately.
     */
    private class EvictingStore implements CallwiseCircuitBreaker.Store {
        public CallwiseCircuitBreaker.State get(String key) {
            return null;
        }

        public void put(String key, CallwiseCircuitBreaker.State state) {
            return;
        }
    }
}
