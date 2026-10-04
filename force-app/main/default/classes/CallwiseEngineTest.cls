@IsTest
private class CallwiseEngineTest {
  private static final String NAMED_CREDENTIAL = 'Test_API';

  @IsTest
  static void shouldReturnResponse_WhenCalloutSucceeds() {
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
  static void shouldReturnErrorResponse_WhenThrowOnErrorIsOff() {
    new CallwiseMock().whenRequest('GET', '/orders/1').thenRespond(404, '').install();

    Test.startTest();
    CallwiseResponse response = Callwise.to(NAMED_CREDENTIAL).get('/orders/1').send();
    Test.stopTest();

    Assert.areEqual(404, response.getStatusCode(), 'HTTP errors are returned, not thrown');
  }

  @IsTest
  static void shouldThrowHttpError_WhenThrowOnErrorIsOn() {
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
  static void shouldLogFailure_WhenCalloutThrows() {
    new CallwiseMock().whenRequest('GET', '/a').thenThrow('Connection reset').install();
    RecordingLogger logger = installLogger();

    Test.startTest();
    try {
      Callwise.to(NAMED_CREDENTIAL).get('/a').send();
      Assert.fail('Expected CallwiseException');
    } catch (CallwiseException e) {
      Assert.areEqual(new List<String>{ 'attempt=1 failure=TRANSPORT' }, logger.entries, 'Failure logged');
    }
    Test.stopTest();
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

  private static CallwiseException assertTranslated(String platformMessage, CallwiseException.FailureReason expected) {
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

  private class RecordingLogger implements Callwise.Logger {
    private final List<String> entries = new List<String>();

    public void log(CallwiseRequest request, CallwiseResponse response, CallwiseException failure, Integer attempt) {
      String outcome = response != null ? 'status=' + response.getStatusCode() : 'failure=' + failure.reason;
      entries.add('attempt=' + attempt + ' ' + outcome);
    }
  }
}
