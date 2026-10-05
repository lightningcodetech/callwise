/**
 * @description Internal: runs one attempt of an asynchronous send and, when the outcome can be retried, enqueues the
 * next attempt
 * with a delay. Not part of the public API; use CallwiseRequest.sendAsync().
 *
 * Every job is its own transaction with fresh limits. The request travels in the job state, including its
 * Idempotency-Key, so every attempt sends the same key. Callwise.setLogger() and setCachePartition() do not travel:
 * static state does not cross transactions.
 *
 * Delay before the next attempt: CallwiseRetryPolicy.asyncDelayMinutes() (Retry-After, otherwise exponential
 * backoff), at most 10 minutes. When the circuit is open no callout is made, so the attempt is retried whatever the
 * HTTP method, no earlier than the breaker's next trial.
 */
public inherited sharing class CallwiseAsyncJob implements Queueable, Database.AllowsCallouts {
    /** @description Seconds in a minute, to convert the breaker's wait into an enqueue delay. */
    private static final Integer SECONDS_PER_MINUTE = 60;

    /** @description Next attempts enqueued during tests, where Apex does not allow chaining Queueable jobs. */
    @TestVisible
    private static List<CallwiseAsyncJob> chainedInTests = new List<CallwiseAsyncJob>();

    /** @description Request to send; its Idempotency-Key travels with it to every attempt. */
    @TestVisible
    private final CallwiseRequest request;
    /** @description Name of the Callwise.Callback implementation, or null for no callback. */
    @TestVisible
    private final String callbackClassName;
    /** @description Attempt this job makes, starting at 1. */
    @TestVisible
    private final Integer attempt;
    /** @description Minutes this job waits before running, as passed to System.enqueueJob(). */
    @TestVisible
    private Integer delayMinutes;

    /**
     * @description Creates the job for one attempt.
     *
     * @param request `CallwiseRequest` Request to send
     * @param callbackClassName `String` Name of a Callwise.Callback implementation, or null for no callback
     * @param attempt `Integer` Attempt this job makes, starting at 1
     */
    public CallwiseAsyncJob(CallwiseRequest request, String callbackClassName, Integer attempt) {
        this.request = request;
        this.callbackClassName = callbackClassName;
        this.attempt = attempt;
    }

    /**
     * @description Makes the attempt, then either enqueues the next one or reports the final outcome to the callback.
     *
     * @param context `QueueableContext` Queueable context; not used
     */
    public void execute(QueueableContext context) {
        CallwiseRetryPolicy policy = request.getRetryPolicy();
        CallwiseCircuitBreaker breaker = request.isCircuitBreakerEnabled()
            ? new CallwiseCircuitBreaker(request.getNamedCredential())
            : null;
        CallwiseEngine.Outcome outcome;
        Boolean retryable;
        Integer nextDelayMinutes;
        if (breaker != null && !breaker.allowRequest()) {
            outcome = new CallwiseEngine.Outcome();
            outcome.failure = breaker.openCircuitException();
            retryable = true;
            nextDelayMinutes = Math.min(
                Math.max(policy.asyncDelayMinutes(attempt, null), minutesUntil(breaker.secondsUntilTrial())),
                CallwiseRetryPolicy.MAX_ASYNC_DELAY_MINUTES
            );
        } else {
            outcome = CallwiseEngine.attempt(request, breaker, attempt, System.currentTimeMillis());
            retryable = policy.isRetryable(request, outcome.response, outcome.failure);
            nextDelayMinutes = policy.asyncDelayMinutes(attempt, outcome.response);
        }

        if (retryable && attempt < policy.getMaxAttempts() && CallwiseEngine.hasQueueableLeft()) {
            CallwiseAsyncJob next = new CallwiseAsyncJob(request, callbackClassName, attempt + 1);
            next.delayMinutes = nextDelayMinutes;
            enqueue(next);
            return;
        }
        deliver(outcome);
    }

    /**
     * @description Reports the final outcome to the callback, if any: onFailure() for a failure, or for a non-2xx
     * response when throwOnError() is set; onResponse() otherwise.
     *
     * @param outcome `CallwiseEngine.Outcome` Outcome of the last attempt
     */
    private void deliver(CallwiseEngine.Outcome outcome) {
        if (callbackClassName == null) {
            return;
        }
        Callwise.Callback callback = (Callwise.Callback) Type.forName(callbackClassName).newInstance();
        if (outcome.failure != null) {
            callback.onFailure(request, outcome.failure);
        } else if (request.isThrowOnError() && !outcome.response.isSuccess()) {
            callback.onFailure(request, CallwiseException.fromResponse(outcome.response));
        } else {
            callback.onResponse(request, outcome.response);
        }
    }

    /**
     * @description Enqueues the next attempt with its delay. In tests, where Queueable chaining is not allowed, the job
     * is recorded in chainedInTests instead.
     *
     * @param next `CallwiseAsyncJob` Job for the next attempt
     */
    private static void enqueue(CallwiseAsyncJob next) {
        if (Test.isRunningTest()) {
            chainedInTests.add(next);
            return;
        }
        System.enqueueJob(next, next.delayMinutes);
    }

    /**
     * @description Converts a wait in seconds into whole minutes, rounding up.
     *
     * @param seconds `Long` Seconds to wait
     * @return `Integer` Minutes to wait
     */
    private static Integer minutesUntil(Long seconds) {
        return ((seconds + SECONDS_PER_MINUTE - 1) / SECONDS_PER_MINUTE).intValue();
    }
}
