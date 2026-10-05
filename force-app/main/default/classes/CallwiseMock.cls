/**
 * @description Declarative HttpCalloutMock for tests. Routes match on HTTP method and path; '*' matches any sequence of
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
    /** @description Prefix of Named Credential endpoints, removed before matching paths. */
    private static final String CALLOUT_PREFIX = 'callout:';
    /** @description Matches any sequence of characters in a pattern, or any method. */
    private static final String WILDCARD = '*';
    /** @description Reason phrase sent with each status code; unknown codes get an empty phrase. */
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

    /** @description Routes in registration order; the first match wins. */
    private final List<Route> routes = new List<Route>();
    /** @description Every request received, in order. */
    private final List<HttpRequest> receivedRequests = new List<HttpRequest>();
    /** @description Route that thenRespond() and thenThrow() add to. */
    private Route currentRoute;

    /**
     * @description Thrown when the mock is misconfigured or receives a request no route matches.
     */
    public class MockException extends Exception {
    }

    /**
     * @description Starts a route. Follow with one or more thenRespond() / thenThrow() calls.
     *
     * @param method `String` HTTP method, case-insensitive, or '*' for any
     * @param pathPattern `String` Path relative to the Named Credential, e.g. '/v1/customers/*'
     * @return `CallwiseMock` This mock
     * @throws `MockException` when method or pathPattern is blank
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
     * @description Adds a response to the current route's sequence.
     *
     * @param statusCode `Integer` HTTP status code
     * @param body `String` Response body; null is returned as an empty string
     * @return `CallwiseMock` This mock
     * @throws `MockException` when called before whenRequest()
     */
    public CallwiseMock thenRespond(Integer statusCode, String body) {
        return thenRespond(statusCode, body, null);
    }

    /**
     * @description Adds a response with headers to the current route's sequence.
     *
     * @param statusCode `Integer` HTTP status code
     * @param body `String` Response body; null is returned as an empty string
     * @param headers `Map<String, String>` Response headers, may be null
     * @return `CallwiseMock` This mock
     * @throws `MockException` when called before whenRequest() or statusCode is null
     */
    public CallwiseMock thenRespond(Integer statusCode, String body, Map<String, String> headers) {
        if (statusCode == null) {
            throw new MockException('thenRespond() requires a status code.');
        }
        requireRoute().steps.add(new Step(statusCode, body, headers, null));
        return this;
    }

    /**
     * @description Adds a transport failure to the current route's sequence: the callout throws a CalloutException.
     *
     * @param message `String` Exception message, e.g. 'Read timed out'
     * @return `CallwiseMock` This mock
     * @throws `MockException` when called before whenRequest()
     */
    public CallwiseMock thenThrow(String message) {
        requireRoute().steps.add(new Step(null, null, null, message ?? 'Mocked callout failure'));
        return this;
    }

    /**
     * @description Registers this mock with Test.setMock(). Only valid in test context.
     *
     * @return `CallwiseMock` This mock
     */
    public CallwiseMock install() {
        Test.setMock(HttpCalloutMock.class, this);
        return this;
    }

    /**
     * @description HttpCalloutMock implementation. Called by the platform for every callout.
     *
     * @param request `HttpRequest` Outgoing request
     * @return `HttpResponse` Mocked response
     * @throws `CalloutException` when the matched step is a thenThrow()
     * @throws `MockException` when no route matches or the route has no responses
     */
    public HttpResponse respond(HttpRequest request) {
        receivedRequests.add(request);
        String method = request.getMethod();
        String pathAndQuery = extractPathAndQuery(request.getEndpoint());
        Route route = findRoute(method, pathAndQuery);
        if (route == null) {
            throw new MockException(
                'No CallwiseMock route matches ' +
                    method +
                    ' ' +
                    pathAndQuery +
                    '. Registered routes: ' +
                    describeRoutes()
            );
        }
        return route.nextStep().toHttpResponse();
    }

    /**
     * @description Returns the requests received so far, for asserting headers and bodies.
     *
     * @return `List<HttpRequest>` Copy of every request received, in order
     */
    public List<HttpRequest> getRequests() {
        return new List<HttpRequest>(receivedRequests);
    }

    /**
     * @description Counts the received requests that match a method and a path pattern.
     *
     * @param method `String` HTTP method, case-insensitive, or '*' for any; null means any
     * @param pathPattern `String` Same syntax as whenRequest(); null means any
     * @return `Integer` Number of received requests matching method and pattern
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

    /**
     * @description Returns the route being configured.
     *
     * @return `Route` Route started by the last whenRequest()
     * @throws `MockException` when whenRequest() has not been called
     */
    private Route requireRoute() {
        if (currentRoute == null) {
            throw new MockException('Call whenRequest() before thenRespond() or thenThrow().');
        }
        return currentRoute;
    }

    /**
     * @description Finds the first route that matches a request.
     *
     * @param method `String` HTTP method of the request
     * @param pathAndQuery `String` Path and query string of the request
     * @return `Route` Matching route, or null when none matches
     */
    private Route findRoute(String method, String pathAndQuery) {
        for (Route route : routes) {
            if (route.matches(method, pathAndQuery)) {
                return route;
            }
        }
        return null;
    }

    /**
     * @description Lists the registered routes, for the message of an unmatched request.
     *
     * @return `String` Routes as "METHOD pattern", comma-separated, or 'none'
     */
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

    /**
     * @description Removes the callout: prefix and the Named Credential name from an endpoint.
     *
     * @param endpoint `String` Endpoint of the request, e.g. 'callout:Stripe_API/v1/customers?limit=10'
     * @return `String` Path and query string, always starting with '/'
     */
    private static String extractPathAndQuery(String endpoint) {
        String remainder = endpoint ?? '';
        if (remainder.startsWithIgnoreCase(CALLOUT_PREFIX)) {
            remainder = remainder.substring(CALLOUT_PREFIX.length());
        }
        Integer start = firstIndexOfAny(remainder, '/', '?');
        String pathAndQuery = start < 0 ? '' : remainder.substring(start);
        return pathAndQuery.startsWith('/') ? pathAndQuery : '/' + pathAndQuery;
    }

    /**
     * @description Finds the first occurrence of either of two substrings.
     *
     * @param value `String` Text to search
     * @param first `String` First substring
     * @param second `String` Second substring
     * @return `Integer` Index of the earliest occurrence, or -1 when neither occurs
     */
    private static Integer firstIndexOfAny(String value, String first, String second) {
        Integer firstIndex = value.indexOf(first);
        Integer secondIndex = value.indexOf(second);
        if (firstIndex < 0) {
            return secondIndex;
        }
        return secondIndex < 0 ? firstIndex : Math.min(firstIndex, secondIndex);
    }

    /**
     * @description A method and path pattern with the sequence of responses it plays.
     */
    private class Route {
        /** @description HTTP method in upper case, or '*' for any. */
        private final String method;
        /** @description Path pattern as registered, with '*' wildcards. */
        private final String pathPattern;
        /** @description True when the pattern contains '?', so the query string is matched too. */
        private final Boolean matchesQuery;
        /** @description Pattern compiled to a regular expression. */
        private final Pattern compiledPattern;
        /** @description Responses and failures to play, in order. */
        private final List<Step> steps = new List<Step>();
        /** @description Index of the next step; the last step repeats once it is reached. */
        private Integer cursor = 0;

        /**
         * @description Creates a route and compiles its pattern.
         *
         * @param method `String` HTTP method, case-insensitive, or '*' for any
         * @param pathPattern `String` Path pattern with '*' wildcards
         */
        private Route(String method, String pathPattern) {
            this.method = method.toUpperCase();
            this.pathPattern = pathPattern;
            this.matchesQuery = pathPattern.contains('?');
            this.compiledPattern = Pattern.compile(toRegex(pathPattern));
        }

        /**
         * @description Checks whether a request matches this route.
         *
         * @param requestMethod `String` HTTP method of the request
         * @param pathAndQuery `String` Path and query string of the request
         * @return `Boolean` True when method and pattern match
         */
        private Boolean matches(String requestMethod, String pathAndQuery) {
            if (method != WILDCARD && !method.equalsIgnoreCase(requestMethod)) {
                return false;
            }
            String target = matchesQuery ? pathAndQuery : pathAndQuery.substringBefore('?');
            return compiledPattern.matcher(target).matches();
        }

        /**
         * @description Returns the next step and advances; the last step repeats.
         *
         * @return `Step` Step to play for this request
         * @throws `MockException` when the route has no steps
         */
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

        /**
         * @description Converts a '*' wildcard pattern into a regular expression, quoting everything else.
         *
         * @param wildcardPattern `String` Pattern with '*' wildcards
         * @return `String` Equivalent regular expression
         */
        private String toRegex(String wildcardPattern) {
            List<String> quotedParts = new List<String>();
            for (String part : wildcardPattern.split('\\*', -1)) {
                quotedParts.add(part.length() == 0 ? '' : Pattern.quote(part));
            }
            return String.join(quotedParts, '.*');
        }
    }

    /**
     * @description One response, or one transport failure, played by a route.
     */
    private class Step {
        /** @description Status code of the response; null for a failure. */
        private final Integer statusCode;
        /** @description Body of the response. */
        private final String body;
        /** @description Headers of the response. */
        private final Map<String, String> headers;
        /** @description Message of the CalloutException to throw; null for a response. */
        private final String failureMessage;

        /**
         * @description Creates a response step, or a failure step when failureMessage is set.
         *
         * @param statusCode `Integer` Status code of the response
         * @param body `String` Body of the response
         * @param headers `Map<String, String>` Headers of the response; null means none
         * @param failureMessage `String` Message of the CalloutException to throw, or null
         */
        private Step(Integer statusCode, String body, Map<String, String> headers, String failureMessage) {
            this.statusCode = statusCode;
            this.body = body;
            this.headers = headers ?? new Map<String, String>();
            this.failureMessage = failureMessage;
        }

        /**
         * @description Plays the step.
         *
         * @return `HttpResponse` Response with status, reason phrase, body and headers
         * @throws `CalloutException` when the step is a failure
         */
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
