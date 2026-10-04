/**
 * Decides whether a failed attempt is retried and, for async sends, how long to wait before the next one.
 *
 * Retries are idempotency-aware: GET, HEAD, PUT and DELETE are retried; POST and PATCH only when the request
 * carries an Idempotency-Key header or the policy calls allowNonIdempotent().
 *
 * Synchronous retries are immediate (Apex cannot sleep) and bounded by the transaction's callout budget.
 * Real backoff only exists in sendAsync(), where the next attempt is re-enqueued with a delay.
 *
 * @example
 * CallwiseRetryPolicy policy = CallwiseRetryPolicy.transientErrors().maxAttempts(5).asyncBaseDelay(2);
 */
public inherited sharing class CallwiseRetryPolicy {
  /** Upper bound for maxAttempts(). Keeps a single logical call from draining the 100-callout limit. */
  public static final Integer MAX_ATTEMPTS_LIMIT = 10;
  /** Maximum delay System.enqueueJob accepts, in minutes. */
  public static final Integer MAX_ASYNC_DELAY_MINUTES = 10;

  private static final Set<Integer> TRANSIENT_STATUS_CODES = new Set<Integer>{ 408, 429, 500, 502, 503, 504 };
  private static final Integer SECONDS_PER_MINUTE = 60;

  private Integer attemptLimit;
  private Set<Integer> retryableStatusCodes;
  private Boolean retryTransportErrors;
  private Boolean nonIdempotentAllowed = false;
  private Integer asyncBaseDelayMinutes = 1;

  private CallwiseRetryPolicy(Integer attemptLimit, Set<Integer> retryableStatusCodes, Boolean retryTransportErrors) {
    this.attemptLimit = attemptLimit;
    this.retryableStatusCodes = retryableStatusCodes;
    this.retryTransportErrors = retryTransportErrors;
  }

  /**
   * Single attempt, never retries.
   *
   * @return New policy
   */
  public static CallwiseRetryPolicy none() {
    return new CallwiseRetryPolicy(1, new Set<Integer>(), false);
  }

  /**
   * 3 attempts; retries 408, 429, 500, 502, 503, 504 and transport errors (including timeouts).
   *
   * @return New policy
   */
  public static CallwiseRetryPolicy transientErrors() {
    return new CallwiseRetryPolicy(3, TRANSIENT_STATUS_CODES.clone(), true);
  }

  /**
   * @param attempts Total attempts including the first one, between 1 and MAX_ATTEMPTS_LIMIT
   * @return This policy
   * @throws CallwiseException INVALID_REQUEST when out of range
   */
  public CallwiseRetryPolicy maxAttempts(Integer attempts) {
    if (attempts == null || attempts < 1 || attempts > MAX_ATTEMPTS_LIMIT) {
      throw invalid('maxAttempts must be between 1 and ' + MAX_ATTEMPTS_LIMIT + ', got ' + attempts + '.');
    }
    attemptLimit = attempts;
    return this;
  }

  /**
   * Replaces the set of HTTP status codes that trigger a retry.
   *
   * @param statusCodes Status codes, e.g. new Set<Integer>{ 503 }. Empty means never retry on status.
   * @return This policy
   * @throws CallwiseException INVALID_REQUEST when statusCodes is null
   */
  public CallwiseRetryPolicy retryOn(Set<Integer> statusCodes) {
    if (statusCodes == null) {
      throw invalid('retryOn() requires a non-null set of status codes.');
    }
    retryableStatusCodes = statusCodes.clone();
    return this;
  }

  /**
   * Allows retrying POST and PATCH without an Idempotency-Key header. Only use it when the endpoint is known
   * to be safe to repeat: a retried POST after a timeout can create duplicates.
   *
   * @return This policy
   */
  public CallwiseRetryPolicy allowNonIdempotent() {
    nonIdempotentAllowed = true;
    return this;
  }

  /**
   * Base delay for async retries. Attempt n waits base * 2^(n-1) minutes, capped at MAX_ASYNC_DELAY_MINUTES.
   *
   * @param minutes Base delay between 0 and MAX_ASYNC_DELAY_MINUTES. 0 re-enqueues without delay.
   * @return This policy
   * @throws CallwiseException INVALID_REQUEST when out of range
   */
  public CallwiseRetryPolicy asyncBaseDelay(Integer minutes) {
    if (minutes == null || minutes < 0 || minutes > MAX_ASYNC_DELAY_MINUTES) {
      throw invalid('asyncBaseDelay must be between 0 and ' + MAX_ASYNC_DELAY_MINUTES + ', got ' + minutes + '.');
    }
    asyncBaseDelayMinutes = minutes;
    return this;
  }

  /**
   * @return Total attempts including the first one
   */
  public Integer getMaxAttempts() {
    return attemptLimit;
  }

  /**
   * @return Copy of the status codes that trigger a retry
   */
  public Set<Integer> getRetryableStatusCodes() {
    return retryableStatusCodes.clone();
  }

  /**
   * @return True when TRANSPORT and TIMEOUT failures are retried
   */
  public Boolean retriesTransportErrors() {
    return retryTransportErrors;
  }

  /**
   * @return True when POST/PATCH are retried without an Idempotency-Key
   */
  public Boolean allowsNonIdempotent() {
    return nonIdempotentAllowed;
  }

  /**
   * @return Base delay for async retries, in minutes
   */
  public Integer getAsyncBaseDelayMinutes() {
    return asyncBaseDelayMinutes;
  }

  /**
   * Internal: whether the outcome of an attempt qualifies for a retry. Does not consider attempt count or
   * limits budget; the engine checks those.
   *
   * @param request The request that was sent
   * @param response Response received, or null when the attempt failed with an exception
   * @param failure Exception raised by the attempt, or null when a response was received
   * @return True when the policy allows another attempt
   */
  public Boolean isRetryable(CallwiseRequest request, CallwiseResponse response, CallwiseException failure) {
    if (request == null || (!request.isIdempotent() && !nonIdempotentAllowed)) {
      return false;
    }
    if (failure != null) {
      return retryTransportErrors &&
        (failure.reason == CallwiseException.FailureReason.TRANSPORT ||
        failure.reason == CallwiseException.FailureReason.TIMEOUT);
    }
    return response != null && retryableStatusCodes.contains(response.getStatusCode());
  }

  /**
   * Internal: delay before the next async attempt. A numeric Retry-After header wins over exponential backoff.
   *
   * @param attempt Number of the attempt that just failed, starting at 1
   * @param response Response of that attempt, or null when it failed with an exception
   * @return Minutes to wait, between 0 and MAX_ASYNC_DELAY_MINUTES
   */
  public Integer asyncDelayMinutes(Integer attempt, CallwiseResponse response) {
    Long retryAfterSeconds = response?.getRetryAfterSeconds();
    if (retryAfterSeconds != null) {
      Long minutes = (retryAfterSeconds + SECONDS_PER_MINUTE - 1) / SECONDS_PER_MINUTE;
      return Math.min(minutes, (Long) MAX_ASYNC_DELAY_MINUTES).intValue();
    }
    Integer delay = asyncBaseDelayMinutes;
    // Doubling with an early exit avoids overflow for large attempt numbers.
    for (Integer i = 1; i < (attempt ?? 1) && delay < MAX_ASYNC_DELAY_MINUTES; i++) {
      delay *= 2;
    }
    return Math.min(delay, MAX_ASYNC_DELAY_MINUTES);
  }

  private static CallwiseException invalid(String message) {
    return CallwiseException.create(CallwiseException.FailureReason.INVALID_REQUEST, message);
  }
}
