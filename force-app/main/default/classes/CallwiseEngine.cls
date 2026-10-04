/**
 * Internal: executes CallwiseRequests. Not part of the public API; call CallwiseRequest.send() / sendAsync().
 *
 * Synchronous sends retry immediately (Apex cannot sleep) while the retry policy allows it and the next attempt
 * fits in the transaction's limits: one callout from the 100 available, and the request's timeout within what
 * remains of the 120 s cumulative callout time. Unless the request opts out, every attempt goes through the circuit
 * breaker of its Named Credential. The async Queueable is implemented in the next iteration.
 */
public inherited sharing class CallwiseEngine {
    /** Cumulative callout time the platform allows per transaction, in milliseconds. */
    public static final Integer MAX_CALLOUT_TIME_MS = 120000;

    private static final String UNCOMMITTED_WORK_MARKER = 'uncommitted work pending';
    private static final String TIMEOUT_MARKER = 'timed out';

    /**
     * Callout time consumed by Callwise in this transaction. The platform does not expose the cumulative callout
     * time, so callouts made outside Callwise are not counted.
     */
    @TestVisible
    private static Long calloutMsUsed = 0;

    /** Replaces Limits.getLimitCallouts() in tests, so the callout budget can be exhausted cheaply. */
    @TestVisible
    private static Integer calloutLimitOverride;

    /**
     * Sends the request synchronously, retrying while the policy and the limits budget allow it.
     *
     * @param request Request to send
     * @return Final response
     * @throws CallwiseException CIRCUIT_OPEN when the breaker rejects the first attempt, LIMIT_BUDGET when no callout
     *         is left for it, the last failure when every permitted attempt failed, or HTTP_ERROR when throwOnError()
     *         is set
     */
    public CallwiseResponse send(CallwiseRequest request) {
        if (request == null) {
            throw CallwiseException.create(
                CallwiseException.FailureReason.INVALID_REQUEST,
                'Request must not be null.'
            );
        }
        CallwiseCircuitBreaker breaker = request.isCircuitBreakerEnabled()
            ? new CallwiseCircuitBreaker(request.getNamedCredential())
            : null;
        if (breaker != null && !breaker.allowRequest()) {
            throw breaker.openCircuitException();
        }
        if (!hasCalloutLeft()) {
            throw CallwiseException.create(
                CallwiseException.FailureReason.LIMIT_BUDGET,
                'No callouts left in this transaction (' + Limits.getCallouts() + ' used). Use sendAsync().'
            );
        }
        Long startedAt = System.currentTimeMillis();
        Integer attempt = 0;
        CallwiseResponse response;
        CallwiseException failure;
        do {
            attempt++;
            response = null;
            failure = null;
            Long attemptStartedAt = System.currentTimeMillis();
            try {
                HttpResponse rawResponse = new Http().send(request.toHttpRequest());
                response = new CallwiseResponse(rawResponse, attempt, System.currentTimeMillis() - startedAt);
            } catch (CalloutException e) {
                failure = translate(e);
            } finally {
                calloutMsUsed += System.currentTimeMillis() - attemptStartedAt;
            }
            breaker?.record(response, failure);
            Callwise.getLogger().log(request, response, failure, attempt);
        } while (shouldRetry(request, response, failure, attempt) && (breaker == null || breaker.allowRequest()));

        if (failure != null) {
            throw failure;
        }
        if (request.isThrowOnError() && !response.isSuccess()) {
            throw CallwiseException.fromResponse(response);
        }
        return response;
    }

    /**
     * Enqueues the request for asynchronous delivery.
     *
     * @param request Request to send
     * @param callbackClassName Name of a Callwise.Callback implementation, or null for no callback
     * @return Id of the enqueued job
     * @throws CallwiseException always, until the async engine ships
     */
    public Id sendAsync(CallwiseRequest request, String callbackClassName) {
        throw CallwiseException.create(
            CallwiseException.FailureReason.INVALID_REQUEST,
            'sendAsync() is not available in this build yet.'
        );
    }

    /**
     * Maps a platform CalloutException to a CallwiseException reason, preserving the cause.
     *
     * @param calloutError Exception thrown by Http.send()
     * @return Translated exception
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

    private static Boolean shouldRetry(
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
        return hasCalloutLeft() && calloutMsUsed + request.getTimeoutMs() <= MAX_CALLOUT_TIME_MS;
    }

    private static Boolean hasCalloutLeft() {
        return Limits.getCallouts() < (calloutLimitOverride ?? Limits.getLimitCallouts());
    }
}
