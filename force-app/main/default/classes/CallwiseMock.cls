/**
 * Declarative HttpCalloutMock for tests. Routes match on HTTP method and path; '*' matches any sequence of
 * characters. Patterns containing '?' are matched against path + query string, others against the path only.
 * Routes are evaluated in registration order and the first match wins.
 *
 * Each route answers with a sequence of responses; once exhausted, the last one repeats.
 *
 * @example
 * CallwiseMock mock = new CallwiseMock()
 *     .whenRequest('GET', '/v1/customers/*')
 *     .thenRespond(503, '')
 *     .thenRespond(200, '{"id":"cus_123"}')
 *     .install();
 * // ... code under test ...
 * Assert.areEqual(2, mock.countRequests('GET', '/v1/customers/*'));
 */
public inherited sharing class CallwiseMock implements HttpCalloutMock {
  private static final String CALLOUT_PREFIX = 'callout:';
  private static final String WILDCARD = '*';
  private static final Map<Integer, String> REASON_PHRASES = new Map<Integer, String>{
    200 => 'OK',
    201 => 'Created',
    202 => 'Accepted',
    204 => 'No Content',
    400 => 'Bad Request',
    401 => 'Unauthorized',
    403 => 'Forbidden',
    404 => 'Not Found',
    408 => 'Request Timeout',
    409 => 'Conflict',
    422 => 'Unprocessable Entity',
    429 => 'Too Many Requests',
    500 => 'Internal Server Error',
    502 => 'Bad Gateway',
    503 => 'Service Unavailable',
    504 => 'Gateway Timeout'
  };

  private final List<Route> routes = new List<Route>();
  private final List<HttpRequest> receivedRequests = new List<HttpRequest>();
  private Route currentRoute;

  /**
   * Thrown when the mock is misconfigured or receives a request no route matches.
   */
  public class MockException extends Exception {
  }

  /**
   * Starts a route. Follow with one or more thenRespond() / thenThrow() calls.
   *
   * @param method HTTP method, case-insensitive, or '*' for any
   * @param pathPattern Path relative to the Named Credential, e.g. '/v1/customers/*'
   * @return This mock
   * @throws MockException when method or pathPattern is blank
   */
  public CallwiseMock whenRequest(String method, String pathPattern) {
    if (String.isBlank(method) || String.isBlank(pathPattern)) {
      throw new MockException('whenRequest() requires a method and a path pattern.');
    }
    currentRoute = new Route(method, pathPattern);
    routes.add(currentRoute);
    return this;
  }

  /**
   * Adds a response to the current route's sequence.
   *
   * @param statusCode HTTP status code
   * @param body Response body; null is returned as an empty string
   * @return This mock
   * @throws MockException when called before whenRequest()
   */
  public CallwiseMock thenRespond(Integer statusCode, String body) {
    return thenRespond(statusCode, body, null);
  }

  /**
   * Adds a response with headers to the current route's sequence.
   *
   * @param statusCode HTTP status code
   * @param body Response body; null is returned as an empty string
   * @param headers Response headers, may be null
   * @return This mock
   * @throws MockException when called before whenRequest() or statusCode is null
   */
  public CallwiseMock thenRespond(Integer statusCode, String body, Map<String, String> headers) {
    if (statusCode == null) {
      throw new MockException('thenRespond() requires a status code.');
    }
    requireRoute().steps.add(new Step(statusCode, body, headers, null));
    return this;
  }

  /**
   * Adds a transport failure to the current route's sequence: the callout throws a CalloutException.
   *
   * @param message Exception message, e.g. 'Read timed out'
   * @return This mock
   * @throws MockException when called before whenRequest()
   */
  public CallwiseMock thenThrow(String message) {
    requireRoute().steps.add(new Step(null, null, null, message ?? 'Mocked callout failure'));
    return this;
  }

  /**
   * Registers this mock with Test.setMock(). Only valid in test context.
   *
   * @return This mock
   */
  public CallwiseMock install() {
    Test.setMock(HttpCalloutMock.class, this);
    return this;
  }

  /**
   * HttpCalloutMock implementation. Called by the platform for every callout.
   *
   * @param request Outgoing request
   * @return Mocked response
   * @throws CalloutException when the matched step is a thenThrow()
   * @throws MockException when no route matches or the route has no responses
   */
  public HttpResponse respond(HttpRequest request) {
    receivedRequests.add(request);
    String method = request.getMethod();
    String pathAndQuery = extractPathAndQuery(request.getEndpoint());
    Route route = findRoute(method, pathAndQuery);
    if (route == null) {
      throw new MockException(
        'No CallwiseMock route matches ' + method + ' ' + pathAndQuery + '. Registered routes: ' + describeRoutes()
      );
    }
    return route.nextStep().toHttpResponse();
  }

  /**
   * @return Every request received, in order
   */
  public List<HttpRequest> getRequests() {
    return new List<HttpRequest>(receivedRequests);
  }

  /**
   * @param method HTTP method, case-insensitive, or '*' for any
   * @param pathPattern Same syntax as whenRequest()
   * @return Number of received requests matching method and pattern
   */
  public Integer countRequests(String method, String pathPattern) {
    Route matcher = new Route(method ?? WILDCARD, pathPattern ?? WILDCARD);
    Integer count = 0;
    for (HttpRequest request : receivedRequests) {
      if (matcher.matches(request.getMethod(), extractPathAndQuery(request.getEndpoint()))) {
        count++;
      }
    }
    return count;
  }

  private Route requireRoute() {
    if (currentRoute == null) {
      throw new MockException('Call whenRequest() before thenRespond() or thenThrow().');
    }
    return currentRoute;
  }

  private Route findRoute(String method, String pathAndQuery) {
    for (Route route : routes) {
      if (route.matches(method, pathAndQuery)) {
        return route;
      }
    }
    return null;
  }

  private String describeRoutes() {
    if (routes.isEmpty()) {
      return 'none';
    }
    List<String> descriptions = new List<String>();
    for (Route route : routes) {
      descriptions.add(route.method + ' ' + route.pathPattern);
    }
    return String.join(descriptions, ', ');
  }

  private static String extractPathAndQuery(String endpoint) {
    String remainder = endpoint ?? '';
    if (remainder.startsWithIgnoreCase(CALLOUT_PREFIX)) {
      remainder = remainder.substring(CALLOUT_PREFIX.length());
    }
    Integer start = firstIndexOfAny(remainder, '/', '?');
    String pathAndQuery = start < 0 ? '' : remainder.substring(start);
    return pathAndQuery.startsWith('/') ? pathAndQuery : '/' + pathAndQuery;
  }

  private static Integer firstIndexOfAny(String value, String first, String second) {
    Integer firstIndex = value.indexOf(first);
    Integer secondIndex = value.indexOf(second);
    if (firstIndex < 0) {
      return secondIndex;
    }
    return secondIndex < 0 ? firstIndex : Math.min(firstIndex, secondIndex);
  }

  private class Route {
    private final String method;
    private final String pathPattern;
    private final Boolean matchesQuery;
    private final Pattern compiledPattern;
    private final List<Step> steps = new List<Step>();
    private Integer cursor = 0;

    private Route(String method, String pathPattern) {
      this.method = method.toUpperCase();
      this.pathPattern = pathPattern;
      this.matchesQuery = pathPattern.contains('?');
      this.compiledPattern = Pattern.compile(toRegex(pathPattern));
    }

    private Boolean matches(String requestMethod, String pathAndQuery) {
      if (method != WILDCARD && !method.equalsIgnoreCase(requestMethod)) {
        return false;
      }
      String target = matchesQuery ? pathAndQuery : pathAndQuery.substringBefore('?');
      return compiledPattern.matcher(target).matches();
    }

    private Step nextStep() {
      if (steps.isEmpty()) {
        throw new MockException(
          'Route ' + method + ' ' + pathPattern + ' has no responses; add thenRespond() or thenThrow().'
        );
      }
      Step step = steps[Math.min(cursor, steps.size() - 1)];
      cursor++;
      return step;
    }

    private String toRegex(String wildcardPattern) {
      List<String> quotedParts = new List<String>();
      for (String part : wildcardPattern.split('\\*', -1)) {
        quotedParts.add(part.length() == 0 ? '' : Pattern.quote(part));
      }
      return String.join(quotedParts, '.*');
    }
  }

  private class Step {
    private final Integer statusCode;
    private final String body;
    private final Map<String, String> headers;
    private final String failureMessage;

    private Step(Integer statusCode, String body, Map<String, String> headers, String failureMessage) {
      this.statusCode = statusCode;
      this.body = body;
      this.headers = headers ?? new Map<String, String>();
      this.failureMessage = failureMessage;
    }

    private HttpResponse toHttpResponse() {
      if (failureMessage != null) {
        throw new CalloutException(failureMessage);
      }
      HttpResponse response = new HttpResponse();
      response.setStatusCode(statusCode);
      response.setStatus(REASON_PHRASES.get(statusCode) ?? '');
      response.setBody(body ?? '');
      for (String name : headers.keySet()) {
        response.setHeader(name, headers.get(name));
      }
      return response;
    }
  }
}
