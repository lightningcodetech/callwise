@IsTest
private class CallwiseMockTest {
  @IsTest
  static void shouldRespond_WhenRouteMatches() {
    CallwiseMock mock = new CallwiseMock()
      .whenRequest('GET', '/v1/customers/*')
      .thenRespond(200, '{"id":"c1"}', new Map<String, String>{ 'X-Request-Id' => 'r1' });

    HttpResponse response = mock.respond(request('GET', 'callout:API/v1/customers/c1'));

    Assert.areEqual(200, response.getStatusCode(), 'Status should come from the route');
    Assert.areEqual('OK', response.getStatus(), 'Known codes get a reason phrase');
    Assert.areEqual('{"id":"c1"}', response.getBody(), 'Body should come from the route');
    Assert.areEqual('r1', response.getHeader('X-Request-Id'), 'Headers should come from the route');
  }

  @IsTest
  static void shouldReturnEmptyBodyAndStatus_WhenNotProvided() {
    CallwiseMock mock = new CallwiseMock().whenRequest('GET', '/a').thenRespond(418, null);

    HttpResponse response = mock.respond(request('GET', 'callout:API/a'));

    Assert.areEqual('', response.getBody(), 'Null body becomes empty');
    Assert.areEqual('', response.getStatus(), 'Unknown codes get no reason phrase');
  }

  @IsTest
  static void shouldPlaySequence_AndRepeatLast() {
    CallwiseMock mock = new CallwiseMock().whenRequest('GET', '/a').thenRespond(503, '').thenRespond(200, 'ok');

    Integer first = mock.respond(request('GET', 'callout:API/a')).getStatusCode();
    Integer second = mock.respond(request('GET', 'callout:API/a')).getStatusCode();
    Integer third = mock.respond(request('GET', 'callout:API/a')).getStatusCode();

    Assert.areEqual(503, first, 'First response first');
    Assert.areEqual(200, second, 'Then the second');
    Assert.areEqual(200, third, 'The last response repeats');
  }

  @IsTest
  static void shouldThrowCalloutException_WhenThenThrow() {
    CallwiseMock mock = new CallwiseMock().whenRequest('GET', '/a').thenThrow('Read timed out');

    try {
      mock.respond(request('GET', 'callout:API/a'));
      Assert.fail('Expected CalloutException');
    } catch (CalloutException e) {
      Assert.areEqual('Read timed out', e.getMessage(), 'Message should come from thenThrow()');
    }
  }

  @IsTest
  static void shouldUseDefaultMessage_WhenThenThrowWithNull() {
    CallwiseMock mock = new CallwiseMock().whenRequest('GET', '/a').thenThrow(null);

    try {
      mock.respond(request('GET', 'callout:API/a'));
      Assert.fail('Expected CalloutException');
    } catch (CalloutException e) {
      Assert.areEqual('Mocked callout failure', e.getMessage(), 'Default message');
    }
  }

  @IsTest
  static void shouldMatchAnyMethod_WhenWildcard() {
    CallwiseMock mock = new CallwiseMock().whenRequest('*', '/a').thenRespond(204, '');

    Assert.areEqual(204, mock.respond(request('DELETE', 'callout:API/a')).getStatusCode(), 'Any method');
  }

  @IsTest
  static void shouldIgnoreQuery_WhenPatternHasNoQuestionMark() {
    CallwiseMock mock = new CallwiseMock().whenRequest('get', '/search').thenRespond(200, '');

    Assert.areEqual(200, mock.respond(request('GET', 'callout:API/search?q=x')).getStatusCode(), 'Query ignored');
  }

  @IsTest
  static void shouldMatchQuery_WhenPatternHasQuestionMark() {
    CallwiseMock mock = new CallwiseMock()
      .whenRequest('GET', '/search?q=a*')
      .thenRespond(200, 'a')
      .whenRequest('GET', '/search?*')
      .thenRespond(200, 'other');

    Assert.areEqual('a', mock.respond(request('GET', 'callout:API/search?q=abc')).getBody(), 'First route');
    Assert.areEqual('other', mock.respond(request('GET', 'callout:API/search?q=zzz')).getBody(), 'Fallback');
  }

  @IsTest
  static void shouldTreatRegexCharactersLiterally() {
    CallwiseMock mock = new CallwiseMock().whenRequest('GET', '/v1.0/items(1)').thenRespond(200, '');

    Assert.areEqual(200, mock.respond(request('GET', 'callout:API/v1.0/items(1)')).getStatusCode(), 'Literal');
    try {
      mock.respond(request('GET', 'callout:API/v1x0/items(1)'));
      Assert.fail('Expected MockException: "." must not match any character');
    } catch (CallwiseMock.MockException e) {
      Assert.isTrue(e.getMessage().contains('/v1x0/items(1)'), 'Unmatched request should be reported');
    }
  }

  @IsTest
  static void shouldUseFirstMatchingRoute() {
    CallwiseMock mock = new CallwiseMock()
      .whenRequest('GET', '/a/*')
      .thenRespond(200, 'first')
      .whenRequest('GET', '/a/b')
      .thenRespond(200, 'second');

    Assert.areEqual('first', mock.respond(request('GET', 'callout:API/a/b')).getBody(), 'First route wins');
  }

  @IsTest
  static void shouldNormalizeEndpointWithoutPath() {
    CallwiseMock mock = new CallwiseMock().whenRequest('GET', '/').thenRespond(200, '');

    Assert.areEqual(200, mock.respond(request('GET', 'callout:API')).getStatusCode(), 'Root endpoint');
    Assert.areEqual(200, mock.respond(request('GET', 'callout:API?x=1')).getStatusCode(), 'Root with query');
    Assert.areEqual(200, mock.respond(request('GET', 'API/')).getStatusCode(), 'Endpoint without prefix');
  }

  @IsTest
  static void shouldThrowClearError_WhenNoRouteMatches() {
    CallwiseMock mock = new CallwiseMock().whenRequest('GET', '/a').thenRespond(200, '');

    try {
      mock.respond(request('POST', 'callout:API/b'));
      Assert.fail('Expected MockException');
    } catch (CallwiseMock.MockException e) {
      Assert.isTrue(e.getMessage().contains('POST /b'), 'Message should show the request');
      Assert.isTrue(e.getMessage().contains('GET /a'), 'Message should list registered routes');
    }
  }

  @IsTest
  static void shouldSayNone_WhenNoRoutesRegistered() {
    try {
      new CallwiseMock().respond(request('GET', 'callout:API/a'));
      Assert.fail('Expected MockException');
    } catch (CallwiseMock.MockException e) {
      Assert.isTrue(e.getMessage().endsWith('Registered routes: none'), 'Message should say none');
    }
  }

  @IsTest
  static void shouldThrow_WhenRouteHasNoResponses() {
    CallwiseMock mock = new CallwiseMock().whenRequest('GET', '/a');

    try {
      mock.respond(request('GET', 'callout:API/a'));
      Assert.fail('Expected MockException');
    } catch (CallwiseMock.MockException e) {
      Assert.isTrue(e.getMessage().contains('has no responses'), 'Message should explain the problem');
    }
  }

  @IsTest
  static void shouldRejectRoute_WhenMethodIsBlank() {
    try {
      new CallwiseMock().whenRequest('', '/a');
      Assert.fail('Expected MockException');
    } catch (CallwiseMock.MockException e) {
      Assert.isTrue(e.getMessage().contains('whenRequest()'), 'Message should name the method');
    }
  }

  @IsTest
  static void shouldRejectResponse_WhenNoRouteStarted() {
    try {
      new CallwiseMock().thenRespond(200, '');
      Assert.fail('Expected MockException');
    } catch (CallwiseMock.MockException e) {
      Assert.isTrue(e.getMessage().contains('before thenRespond()'), 'Message should explain the order');
    }
  }

  @IsTest
  static void shouldRejectResponse_WhenStatusIsNull() {
    try {
      new CallwiseMock().whenRequest('GET', '/a').thenRespond(null, '');
      Assert.fail('Expected MockException');
    } catch (CallwiseMock.MockException e) {
      Assert.isTrue(e.getMessage().contains('status code'), 'Message should ask for a status code');
    }
  }

  @IsTest
  static void shouldRecordAndCountRequests() {
    CallwiseMock mock = new CallwiseMock().whenRequest('*', '*').thenRespond(200, '');
    mock.respond(request('GET', 'callout:API/a'));
    mock.respond(request('GET', 'callout:API/b'));
    mock.respond(request('POST', 'callout:API/a'));

    Assert.areEqual(3, mock.getRequests().size(), 'All requests are recorded');
    Assert.areEqual(2, mock.countRequests('GET', '*'), 'Count by method');
    Assert.areEqual(2, mock.countRequests('*', '/a'), 'Count by path');
    Assert.areEqual(3, mock.countRequests(null, null), 'Null arguments count everything');
  }

  @IsTest
  static void shouldReturnCopyOfRequests() {
    CallwiseMock mock = new CallwiseMock().whenRequest('*', '*').thenRespond(200, '');
    mock.respond(request('GET', 'callout:API/a'));

    mock.getRequests().clear();

    Assert.areEqual(1, mock.getRequests().size(), 'Recorded requests must not be mutable');
  }

  @IsTest
  static void shouldServeRealCallouts_WhenInstalled() {
    CallwiseMock mock = new CallwiseMock().whenRequest('GET', '/a').thenRespond(200, 'ok').install();

    Test.startTest();
    HttpResponse response = new Http().send(request('GET', 'callout:API/a'));
    Test.stopTest();

    Assert.areEqual('ok', response.getBody(), 'Installed mock should answer platform callouts');
    Assert.areEqual(1, mock.countRequests('GET', '/a'), 'Request should be recorded');
  }

  private static HttpRequest request(String method, String endpoint) {
    HttpRequest request = new HttpRequest();
    request.setMethod(method);
    request.setEndpoint(endpoint);
    return request;
  }
}
