/**
 * @description Internal: runs one attempt of an asynchronous send and, when the outcome can be retried, enqueues the
 * next attempt with a delay. Not part of the public API; use CallwiseRequest.sendAsync().
 *
 * Every job is its own transaction with fresh limits. The request travels in the job state, including its
 * Idempotency-Key, so every attempt sends the same key. The logger and cache partition in effect when the request was
 * sent also travel in the job state and are restored before each attempt, since static state does not cross
 * transactions. A logger that cannot be serialized is left behind: see submit().
 *
 * Delay before the next attempt: CallwiseRetryPolicy.asyncDelayMinutes() (Retry-After, otherwise exponential backoff),
 * at most 10 minutes. When the circuit is open no callout is made, so the attempt is retried whatever the HTTP method,
 * no earlier than the breaker's next trial.
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
    /** @description Platform Cache partition in effect when the job was created; restored in execute(). */
    @TestVisible
    private final String cachePartition;
    /** @description Logger in effect when the job was created, or null when it could not be serialized. */
    @TestVisible
    private Callwise.Logger logger;
    /** @description Minutes this job waits before running, as passed to System.enqueueJob(). */
    @TestVisible
    private Integer delayMinutes;

    /**
     * @description Creates the job for one attempt, capturing the current logger and cache partition.
     *
     * @param request `CallwiseRequest` Request to send
     * @param callbackClassName `String` Name of a Callwise.Callback implementation, or null for no callback
     * @param attempt `Integer` Attempt this job makes, starting at 1
     */
    public CallwiseAsyncJob(CallwiseRequest request, String callbackClassName, Integer attempt) {
        this.request = request;
        this.callbackClassName = callbackClassName;
        this.attempt = attempt;
        this.cachePartition = Callwise.getCachePartition();
        this.logger = Callwise.getLogger();
    }

    /**
     * @description Enqueues this job as the first attempt. When the logger cannot be serialized as job state,
     * System.enqueueJob() throws and still uses up a Queueable job; the job is then enqueued again without the logger
     * and a warning is written to the debug log. Next attempts are enqueued from execute() with the logger that was
     * serialized successfully.
     *
     * @return `Id` Id of the enqueued job
     * @throws `CallwiseException` LIMIT_BUDGET when the failed attempt used up the last Queueable job
     */
    @SuppressWarnings('PMD.AvoidDebugStatements')
    public Id submit() {
        try {
            return System.enqueueJob(this);
        } catch (SerializationException e) {
            System.debug(
                LoggingLevel.WARN,
                '[Callwise] The logger cannot travel to async jobs (' +
                    e.getMessage() +
                    '). The attempts of this request are not logged.'
            );
            this.logger = null;
        }
        if (!new CallwiseEngine().hasQueueableLeft()) {
            throw CallwiseException.create(
                CallwiseException.FailureReason.LIMIT_BUDGET,
                'No Queueable jobs left in this transaction after the logger failed to serialize.'
            );
        }
        return System.enqueueJob(this);
    }

    /**
     * @description Restores the logger and cache partition, makes the attempt, then either enqueues the next one or
     * reports the final outcome to the callback.
     *
     * @param context `QueueableContext` Queueable context; not used
     */
    public void execute(QueueableContext context) {
        Callwise.setCachePartition(this.cachePartition);
        Callwise.setLogger(this.logger);
        CallwiseRetryPolicy policy = this.request.getRetryPolicy();
        CallwiseEngine engine = new CallwiseEngine();
        CallwiseCircuitBreaker breaker = CallwiseCircuitBreaker.forRequest(this.request);
        CallwiseEngine.Outcome outcome;
        Boolean retryable;
        Integer nextDelayMinutes;
        if (breaker != null && !breaker.allowRequest()) {
            outcome = new CallwiseEngine.Outcome();
            outcome.failure = breaker.openCircuitException();
            retryable = true;
            nextDelayMinutes = Math.min(
                Math.max(policy.asyncDelayMinutes(this.attempt, null), this.minutesUntil(breaker.secondsUntilTrial())),
                CallwiseRetryPolicy.MAX_ASYNC_DELAY_MINUTES
            );
        } else {
            outcome = engine.attempt(this.request, breaker, this.attempt, System.currentTimeMillis());
            retryable = policy.isRetryable(this.request, outcome.response, outcome.failure);
            nextDelayMinutes = policy.asyncDelayMinutes(this.attempt, outcome.response);
        }

        if (retryable && this.attempt < policy.getMaxAttempts() && engine.hasQueueableLeft()) {
            CallwiseAsyncJob next = new CallwiseAsyncJob(this.request, this.callbackClassName, this.attempt + 1);
            next.delayMinutes = nextDelayMinutes;
            this.enqueue(next);
            return;
        }
        this.deliver(outcome);
    }

    /**
     * @description Reports the final outcome to the callback, if any: onFailure() for a failure, or for a non-2xx
     * response when throwOnError() is set; onResponse() otherwise.
     *
     * @param outcome `CallwiseEngine.Outcome` Outcome of the last attempt
     */
    private void deliver(CallwiseEngine.Outcome outcome) {
        if (this.callbackClassName == null) {
            return;
        }
        Callwise.Callback callback = (Callwise.Callback) Type.forName(this.callbackClassName).newInstance();
        if (outcome.failure != null) {
            callback.onFailure(this.request, outcome.failure);
        } else if (this.request.isThrowOnError() && !outcome.response.isSuccess()) {
            callback.onFailure(this.request, CallwiseException.fromResponse(outcome.response));
        } else {
            callback.onResponse(this.request, outcome.response);
        }
    }

    /**
     * @description Enqueues the next attempt with its delay. In tests, where Queueable chaining is not allowed, the job
     * is recorded in chainedInTests instead.
     *
     * @param next `CallwiseAsyncJob` Job for the next attempt
     */
    private void enqueue(CallwiseAsyncJob next) {
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
    private Integer minutesUntil(Long seconds) {
        return Math.ceil((Double) seconds / SECONDS_PER_MINUTE).intValue();
    }
}
