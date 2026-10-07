/**
 * @description Tests for sendAsync() and CallwiseAsyncJob: enqueueing, backoff between attempts, Retry-After,
 * idempotency keys across jobs, the circuit breaker, Queueable limits, the logger and cache partition carried to
 * every job, and the callback contract. Apex does not allow
 * chaining Queueables in tests, so each attempt is run directly.
 *
 * Not parallel: tests call sendAsync(), which runs System.enqueueJob(), and parallel tests cannot enqueue jobs.
 */
@IsTest(IsParallel=false)
public class CallwiseAsyncJobTest {
    private static final String NAMED_CREDENTIAL = 'Test_API';
    private static final String CALLBACK = RecordingCallback.class.getName();

    private static List<CallwiseResponse> responses = new List<CallwiseResponse>();
    private static List<CallwiseException> failures = new List<CallwiseException>();
    private static List<Integer> loggedAttempts = new List<Integer>();

    @IsTest
    static void shouldEnqueueJobAndDeliverResponse() {
        CallwiseMock mock = new CallwiseMock().whenRequest('GET', '/a').thenRespond(200, '{"ok":true}').install();

        Test.startTest();
        Id jobId = Callwise.to(NAMED_CREDENTIAL).get('/a').sendAsync(RecordingCallback.class);
        Test.stopTest();

        Assert.isNotNull(jobId, 'sendAsync() returns the job Id');
        Assert.areEqual(1, mock.countRequests('GET', '/a'), 'The job made the callout');
        Assert.areEqual(1, responses.size(), 'Callback received the response');
        Assert.areEqual(200, responses[0].getStatusCode(), 'Response from the server');
        Assert.areEqual(1, responses[0].getAttempts(), 'First attempt');
    }

    @IsTest
    static void shouldSendWithoutCallback() {
        CallwiseMock mock = new CallwiseMock().whenRequest('GET', '/a').thenRespond(200, '').install();

        Test.startTest();
        Id jobId = Callwise.to(NAMED_CREDENTIAL).get('/a').sendAsync();
        Test.stopTest();

        Assert.isNotNull(jobId, 'Job enqueued');
        Assert.areEqual(1, mock.countRequests('GET', '/a'), 'The job made the callout');
    }

    @IsTest
    static void shouldEnqueueNextAttemptWithBackoffUntilSuccess() {
        new CallwiseMock().whenRequest('GET', '/a').thenRespond(503, '').thenRespond(200, '').install();

        Test.startTest();
        new CallwiseAsyncJob(Callwise.to(NAMED_CREDENTIAL).get('/a'), CALLBACK, 1).execute(null);
        CallwiseAsyncJob next = takeChained();
        next.execute(null);
        Test.stopTest();

        Assert.areEqual(2, next.attempt, 'Second attempt');
        Assert.areEqual(1, next.delayMinutes, 'Default base delay of 1 minute');
        Assert.areEqual(1, responses.size(), 'Only the final outcome reaches the callback');
        Assert.areEqual(200, responses[0].getStatusCode(), 'Second attempt succeeded');
        Assert.areEqual(2, responses[0].getAttempts(), 'Attempts are counted across jobs');
        Assert.isTrue(CallwiseAsyncJob.chainedInTests.isEmpty(), 'No more attempts after success');
    }

    @IsTest
    static void shouldDoubleDelayOnEachAttemptAndDeliverLastResponse() {
        CallwiseMock mock = new CallwiseMock().whenRequest('GET', '/a').thenRespond(503, '').install();
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL)
            .get('/a')
            .retry(CallwiseRetryPolicy.transientErrors().maxAttempts(4))
            .withoutCircuitBreaker();
        List<Integer> delays = new List<Integer>();

        Test.startTest();
        CallwiseAsyncJob job = new CallwiseAsyncJob(request, CALLBACK, 1);
        job.execute(null);
        while (!CallwiseAsyncJob.chainedInTests.isEmpty()) {
            job = takeChained();
            delays.add(job.delayMinutes);
            job.execute(null);
        }
        Test.stopTest();

        Assert.areEqual(new List<Integer>{ 1, 2, 4 }, delays, 'base * 2^(attempt - 1)');
        Assert.areEqual(4, mock.countRequests('GET', '/a'), 'One callout per attempt');
        Assert.areEqual(503, responses[0].getStatusCode(), 'Last response is delivered');
        Assert.areEqual(4, responses[0].getAttempts(), 'Every attempt was used');
    }

    @IsTest
    static void shouldWaitForRetryAfter() {
        new CallwiseMock()
            .whenRequest('GET', '/a')
            .thenRespond(429, '', new Map<String, String>{ 'Retry-After' => '120' })
            .install();

        Test.startTest();
        new CallwiseAsyncJob(Callwise.to(NAMED_CREDENTIAL).get('/a'), CALLBACK, 1).execute(null);
        Test.stopTest();

        Assert.areEqual(2, takeChained().delayMinutes, 'Retry-After: 120 waits 2 minutes');
    }

    @IsTest
    static void shouldReportHttpErrorWhenThrowOnErrorAndAttemptsAreExhausted() {
        new CallwiseMock().whenRequest('GET', '/a').thenRespond(500, 'down').install();
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL)
            .get('/a')
            .retry(CallwiseRetryPolicy.none())
            .throwOnError();

        Test.startTest();
        new CallwiseAsyncJob(request, CALLBACK, 1).execute(null);
        Test.stopTest();

        Assert.isTrue(responses.isEmpty(), 'onResponse is not called');
        Assert.areEqual(CallwiseException.FailureReason.HTTP_ERROR, failures[0].reason, 'onFailure with HTTP_ERROR');
        Assert.areEqual('down', failures[0].response.getBody(), 'Response attached to the failure');
    }

    @IsTest
    static void shouldReportLastFailureWhenTransportFailuresExhaustAttempts() {
        new CallwiseMock().whenRequest('GET', '/a').thenThrow('Read timed out').install();
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL)
            .get('/a')
            .retry(CallwiseRetryPolicy.transientErrors().maxAttempts(2));

        Test.startTest();
        new CallwiseAsyncJob(request, CALLBACK, 1).execute(null);
        takeChained().execute(null);
        Test.stopTest();

        Assert.areEqual(1, failures.size(), 'onFailure called once');
        Assert.areEqual(CallwiseException.FailureReason.TIMEOUT, failures[0].reason, 'Last failure is reported');
    }

    @IsTest
    static void shouldNotRetryPostWithoutIdempotencyKey() {
        new CallwiseMock().whenRequest('POST', '/a').thenRespond(503, '').install();

        Test.startTest();
        new CallwiseAsyncJob(Callwise.to(NAMED_CREDENTIAL).post('/a'), CALLBACK, 1).execute(null);
        Test.stopTest();

        Assert.isTrue(CallwiseAsyncJob.chainedInTests.isEmpty(), 'POST without a key is not retried');
        Assert.areEqual(503, responses[0].getStatusCode(), 'Response delivered as is');
    }

    @IsTest
    static void shouldSendSameIdempotencyKeyOnEveryAsyncAttempt() {
        CallwiseMock mock = new CallwiseMock()
            .whenRequest('POST', '/a')
            .thenRespond(503, '')
            .thenRespond(201, '')
            .install();
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).post('/a').idempotent();

        Test.startTest();
        new CallwiseAsyncJob(request, CALLBACK, 1).execute(null);
        takeChained().execute(null);
        Test.stopTest();

        List<HttpRequest> sent = mock.getRequests();
        Assert.areEqual(2, sent.size(), 'POST with a key is retried');
        Assert.areEqual(
            sent[0].getHeader('Idempotency-Key'),
            sent[1].getHeader('Idempotency-Key'),
            'Same key on every attempt'
        );
        Assert.areEqual(201, responses[0].getStatusCode(), 'Second attempt succeeded');
    }

    @IsTest
    static void shouldWaitForBreakerTrialWithoutCalloutWhenCircuitIsOpen() {
        CallwiseMock mock = new CallwiseMock().whenRequest('POST', '/a').thenRespond(201, '').install();
        openCircuit();

        Test.startTest();
        new CallwiseAsyncJob(Callwise.to(NAMED_CREDENTIAL).post('/a'), CALLBACK, 1).execute(null);
        Test.stopTest();

        Assert.areEqual(0, mock.countRequests('POST', '/a'), 'No callout while the circuit is open');
        CallwiseAsyncJob next = takeChained();
        Assert.areEqual(1, next.delayMinutes, 'Waits until the trial, 60 s → 1 minute');
        Assert.isTrue(responses.isEmpty() && failures.isEmpty(), 'No outcome yet');
    }

    @IsTest
    static void shouldReportCircuitOpenOnLastAttempt() {
        openCircuit();
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).get('/a').retry(CallwiseRetryPolicy.none());

        Test.startTest();
        new CallwiseAsyncJob(request, CALLBACK, 1).execute(null);
        Test.stopTest();

        Assert.areEqual(
            CallwiseException.FailureReason.CIRCUIT_OPEN,
            failures[0].reason,
            'onFailure with CIRCUIT_OPEN'
        );
    }

    @IsTest
    static void shouldDeliverLastOutcomeWhenNoQueueableIsLeft() {
        new CallwiseMock().whenRequest('GET', '/a').thenRespond(503, '').install();

        Test.startTest();
        CallwiseEngine.queueableLimitOverride = Limits.getQueueableJobs();
        new CallwiseAsyncJob(Callwise.to(NAMED_CREDENTIAL).get('/a'), CALLBACK, 1).execute(null);
        Test.stopTest();

        Assert.isTrue(CallwiseAsyncJob.chainedInTests.isEmpty(), 'No job can be enqueued');
        Assert.areEqual(503, responses[0].getStatusCode(), 'Last response delivered instead');
    }

    @IsTest
    static void shouldThrowLimitBudgetWhenNoQueueableIsLeftForSendAsync() {
        CallwiseEngine.queueableLimitOverride = Limits.getQueueableJobs();

        try {
            Callwise.to(NAMED_CREDENTIAL).get('/a').sendAsync();
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.LIMIT_BUDGET, e.reason, 'Reason should be LIMIT_BUDGET');
        }
    }

    @IsTest
    static void shouldRejectNullRequest() {
        try {
            new CallwiseEngine().sendAsync(null, null);
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.INVALID_REQUEST, e.reason, 'Null request is invalid');
        }
    }

    @IsTest
    static void shouldRestoreLoggerAndCachePartitionInEveryAttempt() {
        new CallwiseMock().whenRequest('GET', '/a').thenRespond(503, '').thenRespond(200, '').install();
        Callwise.setLogger(new RecordingLogger());
        Callwise.setCachePartition('local.Other');
        CallwiseAsyncJob job = new CallwiseAsyncJob(Callwise.to(NAMED_CREDENTIAL).get('/a'), CALLBACK, 1);

        Test.startTest();
        resetStaticSettings();
        job.execute(null);
        CallwiseAsyncJob next = takeChained();
        resetStaticSettings();
        next.execute(null);
        Test.stopTest();

        Assert.areEqual('local.Other', next.cachePartition, 'The next attempt carries the partition');
        Assert.areEqual('local.Other', Callwise.getCachePartition(), 'The job restores the partition');
        Assert.areEqual(new List<Integer>{ 1, 2 }, loggedAttempts, 'Both attempts are logged');
    }

    @IsTest
    static void shouldSendWithoutLoggerWhenLoggerCannotBeSerialized() {
        CallwiseMock mock = new CallwiseMock().whenRequest('GET', '/a').thenRespond(200, '').install();
        Callwise.setLogger(new UnserializableLogger());

        Test.startTest();
        Id jobId = Callwise.to(NAMED_CREDENTIAL).get('/a').sendAsync(RecordingCallback.class);
        Integer queueableJobsUsed = Limits.getQueueableJobs();
        Test.stopTest();

        Assert.isNotNull(jobId, 'The job is enqueued without the logger');
        Assert.areEqual(2, queueableJobsUsed, 'The failed serialization uses up one Queueable job');
        Assert.areEqual(1, mock.countRequests('GET', '/a'), 'The job made the callout');
        Assert.areEqual(200, responses[0].getStatusCode(), 'Callback received the response');
        Assert.isTrue(loggedAttempts.isEmpty(), 'The attempt is not logged');
    }

    @IsTest
    static void shouldThrowLimitBudgetWhenFailedSerializationUsesLastQueueable() {
        Callwise.setLogger(new UnserializableLogger());
        CallwiseEngine.queueableLimitOverride = Limits.getQueueableJobs() + 1;

        try {
            Callwise.to(NAMED_CREDENTIAL).get('/a').sendAsync();
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.LIMIT_BUDGET, e.reason, 'Reason should be LIMIT_BUDGET');
        }
    }

    private static CallwiseAsyncJob takeChained() {
        Assert.areEqual(1, CallwiseAsyncJob.chainedInTests.size(), 'Exactly one next attempt is enqueued');
        return CallwiseAsyncJob.chainedInTests.remove(0);
    }

    /**
     * @description Puts the static settings back to their defaults, as in the new transaction a job runs in.
     */
    private static void resetStaticSettings() {
        Callwise.setLogger(null);
        Callwise.setCachePartition(Callwise.DEFAULT_CACHE_PARTITION);
    }

    private static void openCircuit() {
        CallwiseCircuitBreaker breaker = new CallwiseCircuitBreaker(NAMED_CREDENTIAL);
        for (Integer i = 0; i < CallwiseCircuitBreaker.FAILURE_THRESHOLD; i++) {
            breaker.record(null, CallwiseException.create(CallwiseException.FailureReason.TRANSPORT, 'down'));
        }
    }

    /**
     * @description Callback that records every outcome in the test class, so tests can assert what reached it.
     */
    public class RecordingCallback implements Callwise.Callback {
        public void onResponse(CallwiseRequest request, CallwiseResponse response) {
            responses.add(response);
        }

        public void onFailure(CallwiseRequest request, CallwiseException failure) {
            failures.add(failure);
        }
    }

    /**
     * @description Logger that records the attempt numbers in the test class.
     */
    public virtual class RecordingLogger implements Callwise.Logger {
        public void log(
            CallwiseRequest request,
            CallwiseResponse response,
            CallwiseException failure,
            Integer attempt
        ) {
            loggedAttempts.add(attempt);
        }
    }

    /**
     * @description Recording logger that cannot be serialized as Queueable state, because it holds an HttpRequest.
     */
    public class UnserializableLogger extends RecordingLogger {
        public final HttpRequest unserializable = new HttpRequest();
    }
}
