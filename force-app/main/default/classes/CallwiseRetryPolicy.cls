/**
 * @description Decides whether a failed attempt is retried and, for async sends, how long to wait before the next one.
 *
 * Retries are idempotency-aware: GET, HEAD, PUT and DELETE are retried; POST and PATCH only when the request carries an
 * Idempotency-Key header or the policy calls allowNonIdempotent().
 *
 * Synchronous retries are immediate (Apex cannot sleep) and bounded by the transaction's callout budget. Real backoff
 * only exists in sendAsync(), where the next attempt is re-enqueued with a delay.
 *
 * @example
 * CallwiseRetryPolicy policy = CallwiseRetryPolicy.transientErrors().maxAttempts(5).asyncBaseDelay(2);
 */
public inherited sharing class CallwiseRetryPolicy {
    /** @description Upper bound for maxAttempts(). Keeps a single logical call from draining the 100-callout limit. */
    public static final Integer MAX_ATTEMPTS_LIMIT = 10;
    /** @description Maximum delay System.enqueueJob accepts, in minutes. */
    public static final Integer MAX_ASYNC_DELAY_MINUTES = 10;

    /** @description Statuses that usually mean a temporary problem: 408, 429, 500, 502, 503, 504. */
    private static final Set<Integer> TRANSIENT_STATUS_CODES = new Set<Integer>{ 408, 429, 500, 502, 503, 504 };
    /** @description Seconds in a minute, to convert Retry-After into an enqueue delay. */
    private static final Integer SECONDS_PER_MINUTE = 60;

    /** @description Total attempts, the first one included. */
    private Integer attemptLimit;
    /** @description HTTP status codes that trigger a retry. */
    private Set<Integer> retryableStatusCodes;
    /** @description True when TRANSPORT and TIMEOUT failures are retried. */
    private Boolean retryTransportErrors;
    /** @description True when POST and PATCH are retried without an Idempotency-Key. */
    private Boolean nonIdempotentAllowed = false;
    /** @description Base delay of the async exponential backoff, in minutes. */
    private Integer asyncBaseDelayMinutes = 1;

    /**
     * @description Creates a policy. Use the factories none() and transientErrors().
     *
     * @param attemptLimit `Integer` Total attempts, the first one included
     * @param retryableStatusCodes `Set<Integer>` HTTP status codes that trigger a retry
     * @param retryTransportErrors `Boolean` True to retry TRANSPORT and TIMEOUT failures
     */
    private CallwiseRetryPolicy(Integer attemptLimit, Set<Integer> retryableStatusCodes, Boolean retryTransportErrors) {
        this.attemptLimit = attemptLimit;
        this.retryableStatusCodes = retryableStatusCodes;
        this.retryTransportErrors = retryTransportErrors;
    }

    /**
     * @description Single attempt, never retries.
     *
     * @return `CallwiseRetryPolicy` New policy
     */
    public static CallwiseRetryPolicy none() {
        return new CallwiseRetryPolicy(1, new Set<Integer>(), false);
    }

    /**
     * @description 3 attempts; retries 408, 429, 500, 502, 503, 504 and transport errors (including timeouts).
     *
     * @return `CallwiseRetryPolicy` New policy
     */
    public static CallwiseRetryPolicy transientErrors() {
        return new CallwiseRetryPolicy(3, TRANSIENT_STATUS_CODES.clone(), true);
    }

    /**
     * @description Sets the total number of attempts, the first one included.
     *
     * @param attempts `Integer` Total attempts including the first one, between 1 and MAX_ATTEMPTS_LIMIT
     * @return `CallwiseRetryPolicy` This policy
     * @throws `CallwiseException` INVALID_REQUEST when out of range
     */
    public CallwiseRetryPolicy maxAttempts(Integer attempts) {
        if (attempts == null || attempts < 1 || attempts > MAX_ATTEMPTS_LIMIT) {
            throw CallwiseException.invalidRequest(
                'maxAttempts must be between 1 and ' + MAX_ATTEMPTS_LIMIT + ', got ' + attempts + '.'
            );
        }
        this.attemptLimit = attempts;
        return this;
    }

    /**
     * @description Replaces the set of HTTP status codes that trigger a retry.
     *
     * @param statusCodes `Set<Integer>` Status codes, e.g. new Set<Integer>{ 503 }. Empty means never retry on status.
     * @return `CallwiseRetryPolicy` This policy
     * @throws `CallwiseException` INVALID_REQUEST when statusCodes is null
     */
    public CallwiseRetryPolicy retryOn(Set<Integer> statusCodes) {
        if (statusCodes == null) {
            throw CallwiseException.invalidRequest('retryOn() requires a non-null set of status codes.');
        }
        this.retryableStatusCodes = statusCodes.clone();
        return this;
    }

    /**
     * @description Allows retrying POST and PATCH without an Idempotency-Key header. Only use it when the endpoint is
     * known to be safe to repeat: a retried POST after a timeout can create duplicates.
     *
     * @return `CallwiseRetryPolicy` This policy
     */
    public CallwiseRetryPolicy allowNonIdempotent() {
        this.nonIdempotentAllowed = true;
        return this;
    }

    /**
     * @description Base delay for async retries. Attempt n waits base * 2^(n-1) minutes, capped at
     * MAX_ASYNC_DELAY_MINUTES.
     *
     * @param minutes `Integer` Base delay between 0 and MAX_ASYNC_DELAY_MINUTES. 0 re-enqueues without delay.
     * @return `CallwiseRetryPolicy` This policy
     * @throws `CallwiseException` INVALID_REQUEST when out of range
     */
    public CallwiseRetryPolicy asyncBaseDelay(Integer minutes) {
        if (minutes == null || minutes < 0 || minutes > MAX_ASYNC_DELAY_MINUTES) {
            throw CallwiseException.invalidRequest(
                'asyncBaseDelay must be between 0 and ' + MAX_ASYNC_DELAY_MINUTES + ', got ' + minutes + '.'
            );
        }
        this.asyncBaseDelayMinutes = minutes;
        return this;
    }

    /**
     * @description Returns the total number of attempts, the first one included.
     *
     * @return `Integer` Total attempts including the first one
     */
    public Integer getMaxAttempts() {
        return this.attemptLimit;
    }

    /**
     * @description Returns the HTTP status codes that trigger a retry.
     *
     * @return `Set<Integer>` Copy of the status codes that trigger a retry
     */
    public Set<Integer> getRetryableStatusCodes() {
        return this.retryableStatusCodes.clone();
    }

    /**
     * @description Tells whether transport failures and timeouts are retried.
     *
     * @return `Boolean` True when TRANSPORT and TIMEOUT failures are retried
     */
    public Boolean retriesTransportErrors() {
        return this.retryTransportErrors;
    }

    /**
     * @description Tells whether POST and PATCH are retried without an Idempotency-Key.
     *
     * @return `Boolean` True when POST/PATCH are retried without an Idempotency-Key
     */
    public Boolean allowsNonIdempotent() {
        return this.nonIdempotentAllowed;
    }

    /**
     * @description Returns the base delay of the async exponential backoff.
     *
     * @return `Integer` Base delay for async retries, in minutes
     */
    public Integer getAsyncBaseDelayMinutes() {
        return this.asyncBaseDelayMinutes;
    }

    /**
     * @description Internal: whether the outcome of an attempt qualifies for a retry. Does not consider attempt count
     * or limits budget; the engine checks those.
     *
     * @param request `CallwiseRequest` The request that was sent
     * @param response `CallwiseResponse` Response received, or null when the attempt failed with an exception
     * @param failure `CallwiseException` Exception raised by the attempt, or null when a response was received
     * @return `Boolean` True when the policy allows another attempt
     */
    public Boolean isRetryable(CallwiseRequest request, CallwiseResponse response, CallwiseException failure) {
        if (request == null || (!request.isIdempotent() && !this.nonIdempotentAllowed)) {
            return false;
        }
        if (failure != null) {
            return this.retryTransportErrors && failure.isTransportFailure();
        }
        return response != null && this.retryableStatusCodes.contains(response.getStatusCode());
    }

    /**
     * @description Internal: delay before the next async attempt. A Retry-After header, in seconds or as an HTTP date,
     * wins over exponential backoff: base * 2^(attempt - 1) minutes.
     *
     * @param attempt `Integer` Number of the attempt that just failed, starting at 1
     * @param response `CallwiseResponse` Response of that attempt, or null when it failed with an exception
     * @return `Integer` Minutes to wait, between 0 and MAX_ASYNC_DELAY_MINUTES
     */
    public Integer asyncDelayMinutes(Integer attempt, CallwiseResponse response) {
        Long retryAfterSeconds = response?.getRetryAfterSeconds();
        if (retryAfterSeconds != null) {
            return Math.min(Math.ceil((Double) retryAfterSeconds / SECONDS_PER_MINUTE), MAX_ASYNC_DELAY_MINUTES)
                .intValue();
        }
        // Attempts up to 1 wait the base delay. Double arithmetic cannot overflow for large attempt numbers.
        Integer doublings = Math.max((attempt ?? 1) - 1, 0);
        return Math.min(this.asyncBaseDelayMinutes * Math.pow(2, doublings), MAX_ASYNC_DELAY_MINUTES).intValue();
    }
}
