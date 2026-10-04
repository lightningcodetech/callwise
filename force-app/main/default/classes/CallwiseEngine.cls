/**
 * Internal: executes CallwiseRequests. Not part of the public API; call CallwiseRequest.send() / sendAsync().
 *
 * Current scope (v0.1 surface iteration): a single synchronous attempt with transport-error translation,
 * logging and throwOnError(). Retries within the limits budget, the circuit breaker and the async Queueable
 * are implemented in the next iteration.
 */
public inherited sharing class CallwiseEngine {
  private static final String UNCOMMITTED_WORK_MARKER = 'uncommitted work pending';
  private static final String TIMEOUT_MARKER = 'timed out';

  /**
   * Sends the request synchronously.
   *
   * @param request Request to send
   * @return Final response
   * @throws CallwiseException on transport failures, or HTTP_ERROR when throwOnError() is set
   */
  public CallwiseResponse send(CallwiseRequest request) {
    if (request == null) {
      throw CallwiseException.create(CallwiseException.FailureReason.INVALID_REQUEST, 'Request must not be null.');
    }
    Integer attempt = 1;
    Long startedAt = System.currentTimeMillis();
    HttpResponse rawResponse;
    try {
      rawResponse = new Http().send(request.toHttpRequest());
    } catch (CalloutException e) {
      CallwiseException failure = translate(e);
      Callwise.getLogger().log(request, null, failure, attempt);
      throw failure;
    }
    CallwiseResponse response = new CallwiseResponse(rawResponse, attempt, System.currentTimeMillis() - startedAt);
    Callwise.getLogger().log(request, response, null, attempt);
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
}
