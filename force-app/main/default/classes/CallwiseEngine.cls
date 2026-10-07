/**
 * @description Internal: executes CallwiseRequests. Not part of the public API; call CallwiseRequest.send() /
 * sendAsync().
 *
 * Synchronous sends retry immediately (Apex cannot sleep) while the retry policy allows it and the next attempt fits in
 * the transaction's limits: one callout from the 100 available, and the request's timeout within what remains of the
 * 120 s cumulative callout time. Asynchronous sends run one attempt per CallwiseAsyncJob and wait between attempts by
 * re-enqueueing with a delay. Unless the request opts out, every attempt goes through the circuit breaker of its Named
 * Credential.
 */
public inherited sharing class CallwiseEngine {
    /** @description Cumulative callout time the platform allows per transaction, in milliseconds. */
    public static final Integer MAX_CALLOUT_TIME_MS = 120000;

    /** @description Text of the platform error raised when a callout follows uncommitted DML. */
    private static final String UNCOMMITTED_WORK_MARKER = 'uncommitted work pending';
    /** @description Text of the platform error raised when a callout times out. */
    private static final String TIMEOUT_MARKER = 'timed out';

    /**
     * @description Callout time consumed by Callwise in this transaction. The platform does not expose the cumulative
     * callout time, so callouts made outside Callwise are not counted.
     */
    @TestVisible
    private static Long calloutMsUsed = 0;
    /** @description Replaces Limits.getLimitCallouts() in tests, so the callout budget can be exhausted cheaply. */
    @TestVisible
    private static Integer calloutLimitOverride;
    /** @description Replaces Limits.getLimitQueueableJobs() in tests. */
    @TestVisible
    private static Integer queueableLimitOverride;

    /**
     * @description Maps a platform CalloutException to a CallwiseException reason, preserving the cause.
     *
     * @param calloutError `CalloutException` Exception thrown by Http.send()
     * @return `CallwiseException` Translated exception
     */
    public static CallwiseException translate(CalloutException calloutError) {
        String message = calloutError.getMessage() ?? '';
        String normalized = message.toLowerCase();
        if (normalized.contains(UNCOMMITTED_WORK_MARKER)) {
            return CallwiseException.create(
                CallwiseException.FailureReason.UNCOMMITTED_WORK,
                'Callout blocked by uncommitted DML in this transaction. Send it after the commit with sendAsync().',
                calloutError
            );
        }
        if (normalized.contains(TIMEOUT_MARKER)) {
            return CallwiseException.create(CallwiseException.FailureReason.TIMEOUT, message, calloutError);
        }
        return CallwiseException.create(CallwiseException.FailureReason.TRANSPORT, message, calloutError);
    }

    /**
     * @description Sends the request synchronously, retrying while the policy and the limits budget allow it.
     *
     * @param request `CallwiseRequest` Request to send
     * @return `CallwiseResponse` Final response
     * @throws `CallwiseException` CIRCUIT_OPEN when the breaker rejects the first attempt, LIMIT_BUDGET when no callout
     * is left for it, the last failure when every permitted attempt failed, or HTTP_ERROR when throwOnError() is set
     */
    public CallwiseResponse send(CallwiseRequest request) {
        this.requireRequest(request);
        CallwiseCircuitBreaker breaker = CallwiseCircuitBreaker.forRequest(request);
        if (breaker != null && !breaker.allowRequest()) {
            throw breaker.openCircuitException();
        }
        if (!this.hasCalloutLeft()) {
            throw this.limitBudget(
                'No callouts left in this transaction (' + Limits.getCallouts() + ' used). Use sendAsync().'
            );
        }
        Long startedAt = System.currentTimeMillis();
        Integer attempt = 0;
        Outcome outcome;
        do {
            attempt++;
            outcome = this.attempt(request, breaker, attempt, startedAt);
        } while (
            this.shouldRetry(request, outcome.response, outcome.failure, attempt) &&
            (breaker == null || breaker.allowRequest())
        );

        if (outcome.failure != null) {
            throw outcome.failure;
        }
        if (request.isThrowOnError() && !outcome.response.isSuccess()) {
            throw CallwiseException.fromResponse(outcome.response);
        }
        return outcome.response;
    }

    /**
     * @description Enqueues the request for asynchronous delivery. Each attempt runs in its own CallwiseAsyncJob.
     *
     * @param request `CallwiseRequest` Request to send
     * @param callbackClassName `String` Name of a Callwise.Callback implementation, or null for no callback
     * @return `Id` Id of the enqueued job
     * @throws `CallwiseException` INVALID_REQUEST when request is null, LIMIT_BUDGET when no Queueable job can be added
     * in this transaction
     */
    public Id sendAsync(CallwiseRequest request, String callbackClassName) {
        this.requireRequest(request);
        if (!this.hasQueueableLeft()) {
            throw this.limitBudget(
                'No Queueable jobs left in this transaction (' + Limits.getQueueableJobs() + ' enqueued).'
            );
        }
        return new CallwiseAsyncJob(request, callbackClassName, 1).submit();
    }

    /**
     * @description Makes one attempt: one callout, recorded in the breaker (when given) and logged.
     *
     * @param request `CallwiseRequest` Request to send
     * @param breaker `CallwiseCircuitBreaker` Breaker of the request's Named Credential, or null when it is bypassed
     * @param attempt `Integer` Attempt number, starting at 1
     * @param startedAt `Long` When the first attempt of this send started, for CallwiseResponse.getElapsedMs()
     * @return `Outcome` Response or failure of the attempt
     */
    public Outcome attempt(CallwiseRequest request, CallwiseCircuitBreaker breaker, Integer attempt, Long startedAt) {
        Outcome outcome = new Outcome();
        Long attemptStartedAt = System.currentTimeMillis();
        try {
            HttpResponse rawResponse = new Http().send(request.toHttpRequest());
            outcome.response = new CallwiseResponse(rawResponse, attempt, System.currentTimeMillis() - startedAt);
        } catch (CalloutException e) {
            outcome.failure = translate(e);
        } finally {
            calloutMsUsed += System.currentTimeMillis() - attemptStartedAt;
        }
        breaker?.record(outcome.response, outcome.failure);
        Callwise.getLogger().log(request, outcome.response, outcome.failure, attempt);
        return outcome;
    }

    /**
     * @description Checks the Queueable limit of the transaction: 50 from synchronous code, 1 from a Queueable.
     *
     * @return `Boolean` True when another Queueable job can be enqueued in this transaction
     */
    public Boolean hasQueueableLeft() {
        return Limits.getQueueableJobs() < (queueableLimitOverride ?? Limits.getLimitQueueableJobs());
    }

    /**
     * @description Decides whether a synchronous send makes another attempt: the policy allows it, the server did not
     * ask to wait (Retry-After greater than 0), and the attempt fits in the transaction: one callout left and the
     * request timeout within the remaining callout time.
     *
     * @param request `CallwiseRequest` Request being sent
     * @param response `CallwiseResponse` Response of the last attempt, or null
     * @param failure `CallwiseException` Failure of the last attempt, or null
     * @param attempt `Integer` Number of the last attempt
     * @return `Boolean` True when another attempt should be made now
     */
    private Boolean shouldRetry(
        CallwiseRequest request,
        CallwiseResponse response,
        CallwiseException failure,
        Integer attempt
    ) {
        CallwiseRetryPolicy policy = request.getRetryPolicy();
        if (attempt >= policy.getMaxAttempts() || !policy.isRetryable(request, response, failure)) {
            return false;
        }
        // The server asked us to wait and Apex cannot: retrying now would only add load.
        Long retryAfterSeconds = response?.getRetryAfterSeconds();
        if (retryAfterSeconds != null && retryAfterSeconds > 0) {
            return false;
        }
        return this.hasCalloutLeft() && calloutMsUsed + request.getTimeoutMs() <= MAX_CALLOUT_TIME_MS;
    }

    /**
     * @description Checks the callout limit of the transaction.
     *
     * @return `Boolean` True when another callout can be made
     */
    private Boolean hasCalloutLeft() {
        return Limits.getCallouts() < (calloutLimitOverride ?? Limits.getLimitCallouts());
    }

    /**
     * @description Rejects a null request.
     *
     * @param request `CallwiseRequest` Request to check
     * @throws `CallwiseException` INVALID_REQUEST when request is null
     */
    private void requireRequest(CallwiseRequest request) {
        if (request == null) {
            throw CallwiseException.invalidRequest('Request must not be null.');
        }
    }

    /**
     * @description Builds a LIMIT_BUDGET exception.
     *
     * @param message `String` Which limit is exhausted
     * @return `CallwiseException` Exception, ready to throw
     */
    private CallwiseException limitBudget(String message) {
        return CallwiseException.create(CallwiseException.FailureReason.LIMIT_BUDGET, message);
    }

    /**
     * @description Result of a single attempt: exactly one of response and failure is set.
     */
    public class Outcome {
        /** @description Response of the attempt, or null when it failed. */
        public CallwiseResponse response;
        /** @description Failure of the attempt, or null when a response was received. */
        public CallwiseException failure;
    }
}
