@IsTest
private class CallwiseExceptionTest {
  @IsTest
  static void shouldSetReasonAndMessage_WhenCreated() {
    CallwiseException failure = CallwiseException.create(CallwiseException.FailureReason.TRANSPORT, 'boom');

    Assert.areEqual(CallwiseException.FailureReason.TRANSPORT, failure.reason, 'Reason should be kept');
    Assert.areEqual('boom', failure.getMessage(), 'Message should be kept');
    Assert.isNull(failure.response, 'Only HTTP errors carry a response');
  }

  @IsTest
  static void shouldPreserveCause_WhenCreatedWithCause() {
    CalloutException cause = new CalloutException('socket closed');

    CallwiseException failure = CallwiseException.create(CallwiseException.FailureReason.TRANSPORT, 'wrapped', cause);

    Assert.areEqual(CallwiseException.FailureReason.TRANSPORT, failure.reason, 'Reason should be kept');
    Assert.areEqual(cause, failure.getCause(), 'Cause should be preserved');
  }

  @IsTest
  static void shouldCarryResponse_WhenBuiltFromResponse() {
    CallwiseResponse response = buildResponse(503, 'Service Unavailable');

    CallwiseException failure = CallwiseException.fromResponse(response);

    Assert.areEqual(CallwiseException.FailureReason.HTTP_ERROR, failure.reason, 'Reason should be HTTP_ERROR');
    Assert.areEqual(response, failure.response, 'Response should be attached');
    Assert.areEqual('HTTP 503 Service Unavailable', failure.getMessage(), 'Message should show status');
  }

  @IsTest
  static void shouldOmitStatusText_WhenStatusIsBlank() {
    CallwiseException failure = CallwiseException.fromResponse(buildResponse(500, null));

    Assert.areEqual('HTTP 500', failure.getMessage(), 'Message should only contain the code');
  }

  @IsTest
  static void shouldThrowInvalidRequest_WhenResponseIsNull() {
    try {
      CallwiseException.fromResponse(null);
      Assert.fail('Expected CallwiseException');
    } catch (CallwiseException e) {
      Assert.areEqual(CallwiseException.FailureReason.INVALID_REQUEST, e.reason, 'Null response is invalid');
    }
  }

  private static CallwiseResponse buildResponse(Integer statusCode, String status) {
    HttpResponse raw = new HttpResponse();
    raw.setStatusCode(statusCode);
    if (status != null) {
      raw.setStatus(status);
    }
    return new CallwiseResponse(raw, 1, 0L);
  }
}
