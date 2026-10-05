/**
 * @description Tests for CallwiseEngine.send(): transport-error translation, synchronous retries, idempotency,
 * Retry-After, the limits budget and the circuit breaker.
 */
@IsTest
private class CallwiseEngineTest {
    private static final String NAMED_CREDENTIAL = 'Test_API';

    @IsTest
    static void shouldReturnResponseWhenCalloutSucceeds() {
        CallwiseMock mock = new CallwiseMock().whenRequest('GET', '/orders/1').thenRespond(200, '{"id":1}').install();
        RecordingLogger logger = installLogger();

        Test.startTest();
        CallwiseResponse response = Callwise.to(NAMED_CREDENTIAL).get('/orders/1').send();
        Test.stopTest();

        Assert.areEqual(200, response.getStatusCode(), 'Status should come from the server');
        Assert.areEqual(1, response.getAttempts(), 'Single attempt');
        Assert.areEqual(1, mock.countRequests('GET', '/orders/1'), 'One callout');
        Assert.areEqual(new List<String>{ 'attempt=1 status=200' }, logger.entries, 'Attempt should be logged');
    }

    @IsTest
    static void shouldReturnErrorResponseWhenThrowOnErrorIsOff() {
        new CallwiseMock().whenRequest('GET', '/orders/1').thenRespond(404, '').install();

        Test.startTest();
        CallwiseResponse response = Callwise.to(NAMED_CREDENTIAL).get('/orders/1').send();
        Test.stopTest();

        Assert.areEqual(404, response.getStatusCode(), 'HTTP errors are returned, not thrown');
    }

    @IsTest
    static void shouldThrowHttpErrorWhenThrowOnErrorIsOn() {
        new CallwiseMock().whenRequest('GET', '/orders/1').thenRespond(500, 'oops').install();

        Test.startTest();
        try {
            Callwise.to(NAMED_CREDENTIAL).get('/orders/1').throwOnError().send();
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.HTTP_ERROR, e.reason, 'Reason should be HTTP_ERROR');
            Assert.areEqual('oops', e.response.getBody(), 'Response should be attached');
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldTranslateTimeout() {
        assertTranslated('Read timed out', CallwiseException.FailureReason.TIMEOUT);
    }

    @IsTest
    static void shouldTranslateUncommittedWork() {
        CallwiseException failure = assertTranslated(
            'You have uncommitted work pending. Please commit or rollback before calling out',
            CallwiseException.FailureReason.UNCOMMITTED_WORK
        );

        Assert.isTrue(failure.getMessage().contains('sendAsync()'), 'Message should suggest sendAsync()');
    }

    @IsTest
    static void shouldTranslateOtherFailuresAsTransport() {
        assertTranslated('Unable to tunnel through proxy', CallwiseException.FailureReason.TRANSPORT);
    }

    @IsTest
    static void shouldLogFailureWhenCalloutThrows() {
        new CallwiseMock().whenRequest('GET', '/a').thenThrow('Connection reset').install();
        RecordingLogger logger = installLogger();

        Test.startTest();
        try {
            Callwise.to(NAMED_CREDENTIAL).get('/a').retry(CallwiseRetryPolicy.none()).send();
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(new List<String>{ 'attempt=1 failure=TRANSPORT' }, logger.entries, 'Failure logged');
        }
        Test.stopTest();
    }

    // ---------------------------------------------------------------------------------------------------------
    // Synchronous retries
    // ---------------------------------------------------------------------------------------------------------

    @IsTest
    static void shouldRetryTransientStatusUntilSuccess() {
        CallwiseMock mock = new CallwiseMock()
            .whenRequest('GET', '/a')
            .thenRespond(503, '')
            .thenRespond(200, 'ok')
            .install();
        RecordingLogger logger = installLogger();

        Test.startTest();
        CallwiseResponse response = Callwise.to(NAMED_CREDENTIAL).get('/a').send();
        Test.stopTest();

        Assert.areEqual(200, response.getStatusCode(), 'Second attempt should succeed');
        Assert.areEqual(2, response.getAttempts(), 'Attempts should include the retry');
        Assert.areEqual(2, mock.countRequests('GET', '/a'), 'Two callouts');
        Assert.areEqual(
            new List<String>{ 'attempt=1 status=503', 'attempt=2 status=200' },
            logger.entries,
            'Both logged'
        );
    }

    @IsTest
    static void shouldRetryTransportFailureUntilSuccess() {
        CallwiseMock mock = new CallwiseMock()
            .whenRequest('GET', '/a')
            .thenThrow('Read timed out')
            .thenRespond(200, 'ok')
            .install();

        Test.startTest();
        CallwiseResponse response = Callwise.to(NAMED_CREDENTIAL).get('/a').send();
        Test.stopTest();

        Assert.areEqual(200, response.getStatusCode(), 'Retry should recover from the timeout');
        Assert.areEqual(2, mock.countRequests('GET', '/a'), 'Two callouts');
    }

    @IsTest
    static void shouldReturnLastResponseWhenAttemptsAreExhausted() {
        CallwiseMock mock = new CallwiseMock().whenRequest('GET', '/a').thenRespond(503, '').install();

        Test.startTest();
        CallwiseResponse response = Callwise.to(NAMED_CREDENTIAL)
            .get('/a')
            .retry(CallwiseRetryPolicy.transientErrors().maxAttempts(4))
            .send();
        Test.stopTest();

        Assert.areEqual(503, response.getStatusCode(), 'Last response is returned');
        Assert.areEqual(4, response.getAttempts(), 'Every permitted attempt used');
        Assert.areEqual(4, mock.countRequests('GET', '/a'), 'One callout per attempt');
    }

    @IsTest
    static void shouldThrowHttpErrorWhenAttemptsAreExhaustedWithThrowOnError() {
        new CallwiseMock().whenRequest('GET', '/a').thenRespond(502, '').install();

        Test.startTest();
        try {
            Callwise.to(NAMED_CREDENTIAL).get('/a').throwOnError().send();
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.HTTP_ERROR, e.reason, 'Reason should be HTTP_ERROR');
            Assert.areEqual(3, e.response.getAttempts(), 'Default policy makes 3 attempts');
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldThrowLastFailureWhenAttemptsAreExhausted() {
        CallwiseMock mock = new CallwiseMock()
            .whenRequest('GET', '/a')
            .thenThrow('Connection reset')
            .thenThrow('Read timed out')
            .install();

        Test.startTest();
        try {
            Callwise.to(NAMED_CREDENTIAL).get('/a').send();
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.TIMEOUT, e.reason, 'Last failure is thrown');
        }
        Test.stopTest();

        Assert.areEqual(3, mock.countRequests('GET', '/a'), 'Default policy makes 3 attempts');
    }

    @IsTest
    static void shouldNotRetryWhenStatusIsNotRetryable() {
        CallwiseMock mock = new CallwiseMock().whenRequest('GET', '/a').thenRespond(404, '').install();

        Test.startTest();
        Callwise.to(NAMED_CREDENTIAL).get('/a').send();
        Test.stopTest();

        Assert.areEqual(1, mock.countRequests('GET', '/a'), '404 is not retried');
    }

    @IsTest
    static void shouldNotRetryWhenPolicyIsNone() {
        CallwiseMock mock = new CallwiseMock().whenRequest('GET', '/a').thenRespond(503, '').install();

        Test.startTest();
        Callwise.to(NAMED_CREDENTIAL).get('/a').retry(CallwiseRetryPolicy.none()).send();
        Test.stopTest();

        Assert.areEqual(1, mock.countRequests('GET', '/a'), 'none() makes a single attempt');
    }

    @IsTest
    static void shouldNotRetryPostWithoutIdempotencyKey() {
        CallwiseMock mock = new CallwiseMock().whenRequest('POST', '/a').thenRespond(503, '').install();

        Test.startTest();
        Callwise.to(NAMED_CREDENTIAL).post('/a').send();
        Test.stopTest();

        Assert.areEqual(1, mock.countRequests('POST', '/a'), 'POST without Idempotency-Key is not retried');
    }

    @IsTest
    static void shouldRetryPostWithIdempotencyKey() {
        CallwiseMock mock = new CallwiseMock()
            .whenRequest('POST', '/a')
            .thenRespond(503, '')
            .thenRespond(201, '')
            .install();

        Test.startTest();
        CallwiseResponse response = Callwise.to(NAMED_CREDENTIAL).post('/a').header('Idempotency-Key', 'k-1').send();
        Test.stopTest();

        Assert.areEqual(201, response.getStatusCode(), 'Retry should succeed');
        Assert.areEqual(2, mock.countRequests('POST', '/a'), 'POST with Idempotency-Key is retried');
    }

    @IsTest
    static void shouldSendSameGeneratedKeyOnEveryAttempt() {
        CallwiseMock mock = new CallwiseMock()
            .whenRequest('POST', '/a')
            .thenRespond(503, '')
            .thenThrow('Read timed out')
            .thenRespond(201, '')
            .install();
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).post('/a').idempotent();

        Test.startTest();
        CallwiseResponse response = request.send();
        Test.stopTest();

        Assert.areEqual(201, response.getStatusCode(), 'Third attempt should succeed');
        List<HttpRequest> sent = mock.getRequests();
        Assert.areEqual(3, sent.size(), 'POST with a generated key is retried');
        for (HttpRequest attempt : sent) {
            Assert.areEqual(
                request.getIdempotencyKey(),
                attempt.getHeader('Idempotency-Key'),
                'Every attempt carries the same key'
            );
        }
    }

    @IsTest
    static void shouldNotRetryWhenServerAsksToWait() {
        CallwiseMock mock = new CallwiseMock()
            .whenRequest('GET', '/a')
            .thenRespond(429, '', new Map<String, String>{ 'Retry-After' => '30' })
            .install();

        Test.startTest();
        CallwiseResponse response = Callwise.to(NAMED_CREDENTIAL).get('/a').send();
        Test.stopTest();

        Assert.areEqual(429, response.getStatusCode(), 'Response is returned as is');
        Assert.areEqual(1, mock.countRequests('GET', '/a'), 'Retry-After > 0 disables the sync retry');
    }

    @IsTest
    static void shouldRetryWhenRetryAfterIsZero() {
        CallwiseMock mock = new CallwiseMock()
            .whenRequest('GET', '/a')
            .thenRespond(429, '', new Map<String, String>{ 'Retry-After' => '0' })
            .thenRespond(200, '')
            .install();

        Test.startTest();
        Callwise.to(NAMED_CREDENTIAL).get('/a').send();
        Test.stopTest();

        Assert.areEqual(2, mock.countRequests('GET', '/a'), 'Retry-After: 0 allows an immediate retry');
    }

    // ---------------------------------------------------------------------------------------------------------
    // Limits budget
    // ---------------------------------------------------------------------------------------------------------

    @IsTest
    static void shouldStopRetryingWhenTimeoutDoesNotFitRemainingCalloutTime() {
        CallwiseMock mock = new CallwiseMock().whenRequest('GET', '/a').thenRespond(503, '').install();
        CallwiseEngine.calloutMsUsed = CallwiseEngine.MAX_CALLOUT_TIME_MS - 5000;

        Test.startTest();
        CallwiseResponse response = Callwise.to(NAMED_CREDENTIAL).get('/a').timeout(10000).send();
        Test.stopTest();

        Assert.areEqual(503, response.getStatusCode(), 'Last response is returned');
        Assert.areEqual(1, mock.countRequests('GET', '/a'), 'A 10 s retry does not fit in the 5 s left');
    }

    @IsTest
    static void shouldStopRetryingWhenNoCalloutIsLeft() {
        CallwiseMock mock = new CallwiseMock().whenRequest('GET', '/a').thenRespond(503, '').install();

        Test.startTest();
        CallwiseEngine.calloutLimitOverride = Limits.getCallouts() + 1;
        CallwiseResponse response = Callwise.to(NAMED_CREDENTIAL).get('/a').send();
        Test.stopTest();

        Assert.areEqual(503, response.getStatusCode(), 'Last response is returned');
        Assert.areEqual(1, mock.countRequests('GET', '/a'), 'Only one callout was left');
    }

    @IsTest
    static void shouldThrowLimitBudgetWhenNoCalloutIsLeftForTheFirstAttempt() {
        CallwiseMock mock = new CallwiseMock().whenRequest('GET', '/a').thenRespond(200, '').install();
        RecordingLogger logger = installLogger();

        Test.startTest();
        CallwiseEngine.calloutLimitOverride = Limits.getCallouts();
        try {
            Callwise.to(NAMED_CREDENTIAL).get('/a').send();
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.LIMIT_BUDGET, e.reason, 'Reason should be LIMIT_BUDGET');
        }
        Test.stopTest();

        Assert.areEqual(0, mock.countRequests('GET', '/a'), 'No callout is made');
        Assert.isTrue(logger.entries.isEmpty(), 'Nothing to log without an attempt');
    }

    @IsTest
    static void shouldRejectNullRequest() {
        try {
            new CallwiseEngine().send(null);
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.INVALID_REQUEST, e.reason, 'Null request is invalid');
        }
    }

    @IsTest
    static void shouldTranslateNullMessageAsTransport() {
        CallwiseException failure = CallwiseEngine.translate(new CalloutException());

        Assert.areEqual(CallwiseException.FailureReason.TRANSPORT, failure.reason, 'Null message is TRANSPORT');
    }

    // ---------------------------------------------------------------------------------------------------------
    // Circuit breaker
    // ---------------------------------------------------------------------------------------------------------

    @IsTest
    static void shouldThrowCircuitOpenWithoutCalloutWhenBreakerIsOpen() {
        CallwiseMock mock = new CallwiseMock().whenRequest('GET', '/a').thenRespond(503, '').install();

        Test.startTest();
        for (Integer i = 0; i < CallwiseCircuitBreaker.FAILURE_THRESHOLD; i++) {
            Callwise.to(NAMED_CREDENTIAL).get('/a').retry(CallwiseRetryPolicy.none()).send();
        }
        try {
            Callwise.to(NAMED_CREDENTIAL).get('/a').send();
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.CIRCUIT_OPEN, e.reason, 'Reason should be CIRCUIT_OPEN');
        }
        Test.stopTest();

        Assert.areEqual(
            CallwiseCircuitBreaker.FAILURE_THRESHOLD,
            mock.countRequests('GET', '/a'),
            'No callout while the circuit is open'
        );
    }

    @IsTest
    static void shouldStopRetryingWhenCircuitOpens() {
        CallwiseMock mock = new CallwiseMock().whenRequest('GET', '/a').thenRespond(503, '').install();

        Test.startTest();
        CallwiseResponse response = Callwise.to(NAMED_CREDENTIAL)
            .get('/a')
            .retry(CallwiseRetryPolicy.transientErrors().maxAttempts(10))
            .send();
        Test.stopTest();

        Assert.areEqual(503, response.getStatusCode(), 'Last response is returned');
        Assert.areEqual(
            CallwiseCircuitBreaker.FAILURE_THRESHOLD,
            mock.countRequests('GET', '/a'),
            'Retries stop when the circuit opens'
        );
    }

    @IsTest
    static void shouldBypassBreakerWhenDisabled() {
        CallwiseMock mock = new CallwiseMock()
            .whenRequest('GET', '/a')
            .thenRespond(503, '')
            .whenRequest('GET', '/b')
            .thenRespond(200, '')
            .install();
        CallwiseCircuitBreaker breaker = new CallwiseCircuitBreaker(NAMED_CREDENTIAL);

        Test.startTest();
        for (Integer i = 0; i < CallwiseCircuitBreaker.FAILURE_THRESHOLD; i++) {
            Callwise.to(NAMED_CREDENTIAL).get('/a').retry(CallwiseRetryPolicy.none()).withoutCircuitBreaker().send();
        }
        CallwiseCircuitBreaker.CircuitStatus afterBypassedFailures = breaker.getStatus();
        for (Integer i = 0; i < CallwiseCircuitBreaker.FAILURE_THRESHOLD; i++) {
            Callwise.to(NAMED_CREDENTIAL).get('/a').retry(CallwiseRetryPolicy.none()).send();
        }
        CallwiseResponse bypassing = Callwise.to(NAMED_CREDENTIAL).get('/b').withoutCircuitBreaker().send();
        Test.stopTest();

        Assert.areEqual(
            CallwiseCircuitBreaker.CircuitStatus.CLOSED,
            afterBypassedFailures,
            'Bypassed requests do not update the breaker'
        );
        Assert.areEqual(CallwiseCircuitBreaker.CircuitStatus.OPEN, breaker.getStatus(), 'Normal failures open it');
        Assert.areEqual(200, bypassing.getStatusCode(), 'Bypassed request is sent while the circuit is open');
        Assert.areEqual(1, mock.countRequests('GET', '/b'), 'One callout for the bypassed request');
    }

    @IsTest
    static void shouldCloseBreakerWhenTrialRequestSucceeds() {
        new CallwiseMock()
            .whenRequest('GET', '/a')
            .thenRespond(503, '')
            .whenRequest('GET', '/health')
            .thenRespond(200, '')
            .install();
        CallwiseCircuitBreaker.nowOverride = 1700000000000L;

        Test.startTest();
        for (Integer i = 0; i < CallwiseCircuitBreaker.FAILURE_THRESHOLD; i++) {
            Callwise.to(NAMED_CREDENTIAL).get('/a').retry(CallwiseRetryPolicy.none()).send();
        }
        CallwiseCircuitBreaker.nowOverride += CallwiseCircuitBreaker.OPEN_DURATION_MS;
        CallwiseResponse trial = Callwise.to(NAMED_CREDENTIAL).get('/health').send();
        Test.stopTest();

        Assert.areEqual(200, trial.getStatusCode(), 'Trial request is sent after the open period');
        Assert.areEqual(
            CallwiseCircuitBreaker.CircuitStatus.CLOSED,
            new CallwiseCircuitBreaker(NAMED_CREDENTIAL).getStatus(),
            'Successful trial closes the circuit'
        );
    }

    private static CallwiseException assertTranslated(
        String platformMessage,
        CallwiseException.FailureReason expected
    ) {
        new CallwiseMock().whenRequest('GET', '/a').thenThrow(platformMessage).install();
        CallwiseException failure;

        Test.startTest();
        try {
            Callwise.to(NAMED_CREDENTIAL).get('/a').send();
        } catch (CallwiseException e) {
            failure = e;
        }
        Test.stopTest();

        Assert.isNotNull(failure, 'Expected CallwiseException for "' + platformMessage + '"');
        Assert.areEqual(expected, failure.reason, 'Reason for "' + platformMessage + '"');
        Assert.isInstanceOfType(failure.getCause(), CalloutException.class, 'Platform exception kept as cause');
        return failure;
    }

    private static RecordingLogger installLogger() {
        RecordingLogger logger = new RecordingLogger();
        Callwise.setLogger(logger);
        return logger;
    }

    /**
     * @description Logger that records each attempt as "attempt=n status=x" or "attempt=n failure=reason".
     */
    private class RecordingLogger implements Callwise.Logger {
        private final List<String> entries = new List<String>();

        public void log(
            CallwiseRequest request,
            CallwiseResponse response,
            CallwiseException failure,
            Integer attempt
        ) {
            String outcome = response != null ? 'status=' + response.getStatusCode() : 'failure=' + failure.reason;
            entries.add('attempt=' + attempt + ' ' + outcome);
        }
    }
}
