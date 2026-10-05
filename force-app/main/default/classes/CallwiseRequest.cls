/**
 * @description Fluent builder for a callout through a Named Credential. Obtain one with Callwise.to(namedCredential).
 *
 * Defaults: 10 s timeout, CallwiseRetryPolicy.transientErrors() (which only retries idempotent methods),
 * circuit breaker enabled, HTTP errors returned rather than thrown.
 *
 * @example
 * CallwiseResponse res = Callwise.to('Stripe_API')
 *     .post('/v1/customers')
 *     .header('Idempotency-Key', key)
 *     .jsonBody(payload)
 *     .timeout(10000)
 *     .send();
 */
public inherited sharing class CallwiseRequest {
    /** @description Default per-attempt timeout, in milliseconds. Matches the platform default. */
    public static final Integer DEFAULT_TIMEOUT_MS = 10000;
    /** @description Maximum per-attempt timeout the platform allows, in milliseconds. */
    public static final Integer MAX_TIMEOUT_MS = 120000;

    /** @description Prefix that makes the platform resolve an endpoint through a Named Credential. */
    private static final String CALLOUT_PREFIX = 'callout:';
    /** @description Header that lets the server deduplicate repeated POST and PATCH requests. */
    private static final String IDEMPOTENCY_KEY_HEADER = 'Idempotency-Key';
    /** @description Header jsonBody() sets when the caller has not set one. */
    private static final String CONTENT_TYPE_HEADER = 'Content-Type';
    /** @description Content type jsonBody() sets. */
    private static final String JSON_CONTENT_TYPE = 'application/json';
    /** @description Encoding of query parameters. */
    private static final String UTF8 = 'UTF-8';
    /** @description Methods that can be repeated without side effects, so they are always retryable. */
    private static final Set<String> IDEMPOTENT_METHODS = new Set<String>{ 'GET', 'HEAD', 'PUT', 'DELETE' };
    /** @description Valid Named Credential API name: a letter followed by letters, digits or underscores. */
    private static final Pattern NAMED_CREDENTIAL_NAME = Pattern.compile('^[A-Za-z][A-Za-z0-9_]*$');

    /** @description API name of the Named Credential. */
    private final String namedCredential;
    /** @description HTTP method in upper case; null until get(), post() or another setter is called. */
    private String method;
    /** @description Path relative to the Named Credential, starting with '/' or '?'. */
    private String path = '';
    /** @description URL-encoded query parameters as name=value, in call order. */
    private final List<String> queryParameters = new List<String>();
    /** @description Headers with names as provided; looked up case-insensitively. */
    private final Map<String, String> headers = new Map<String, String>();
    /** @description Request body, or null. */
    private String requestBody;
    /** @description Timeout of each attempt, in milliseconds. */
    private Integer timeoutMs = DEFAULT_TIMEOUT_MS;
    /** @description Retry policy of the request. */
    private CallwiseRetryPolicy retryPolicy = CallwiseRetryPolicy.transientErrors();
    /** @description False when withoutCircuitBreaker() was called. */
    private Boolean circuitBreakerEnabled = true;
    /** @description True when throwOnError() was called. */
    private Boolean throwOnErrorEnabled = false;

    /**
     * @description Prefer Callwise.to(namedCredential).
     *
     * @param namedCredential `String` API name of the Named Credential, without the 'callout:' prefix
     * @throws `CallwiseException` INVALID_REQUEST when the name is blank or not a valid API name
     */
    public CallwiseRequest(String namedCredential) {
        if (String.isBlank(namedCredential) || !NAMED_CREDENTIAL_NAME.matcher(namedCredential).matches()) {
            throw invalid(
                'Expected the API name of a Named Credential (e.g. Stripe_API), got "' +
                    namedCredential +
                    '". ' +
                    'Raw URLs are not supported.'
            );
        }
        this.namedCredential = namedCredential;
    }

    // ---------------------------------------------------------------------------------------------------------
    // HTTP method + path
    // ---------------------------------------------------------------------------------------------------------

    /**
     * @description Sets the HTTP method to GET and the path.
     *
     * @param path `String` Path relative to the Named Credential URL, e.g. '/v1/customers'. May include a query string.
     * @return `CallwiseRequest` This request
     */
    public CallwiseRequest get(String path) {
        return withMethod('GET', path);
    }

    /**
     * @description Sets the HTTP method to HEAD and the path.
     *
     * @param path `String` Path relative to the Named Credential URL
     * @return `CallwiseRequest` This request
     */
    public CallwiseRequest head(String path) {
        return withMethod('HEAD', path);
    }

    /**
     * @description Sets the HTTP method to POST and the path. POST is retried only with an Idempotency-Key.
     *
     * @param path `String` Path relative to the Named Credential URL
     * @return `CallwiseRequest` This request
     */
    public CallwiseRequest post(String path) {
        return withMethod('POST', path);
    }

    /**
     * @description Sets the HTTP method to PUT and the path.
     *
     * @param path `String` Path relative to the Named Credential URL
     * @return `CallwiseRequest` This request
     */
    public CallwiseRequest put(String path) {
        return withMethod('PUT', path);
    }

    /**
     * @description Sets the HTTP method to PATCH and the path. PATCH is retried only with an Idempotency-Key.
     *
     * @param path `String` Path relative to the Named Credential URL
     * @return `CallwiseRequest` This request
     */
    public CallwiseRequest patch(String path) {
        return withMethod('PATCH', path);
    }

    /**
     * @description DELETE request. Named del because delete is a reserved word in Apex.
     *
     * @param path `String` Path relative to the Named Credential URL
     * @return `CallwiseRequest` This request
     */
    public CallwiseRequest del(String path) {
        return withMethod('DELETE', path);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Headers, parameters, body
    // ---------------------------------------------------------------------------------------------------------

    /**
     * @description Sets a header, replacing any existing header with the same name (case-insensitive).
     *
     * @param name `String` Header name
     * @param value `String` Header value; null is sent as an empty string
     * @return `CallwiseRequest` This request
     * @throws `CallwiseException` INVALID_REQUEST when name is blank
     */
    public CallwiseRequest header(String name, String value) {
        if (String.isBlank(name)) {
            throw invalid('Header name must not be blank.');
        }
        String existingName = findHeaderName(name);
        if (existingName != null) {
            headers.remove(existingName);
        }
        headers.put(name, value ?? '');
        return this;
    }

    /**
     * @description Sends an Idempotency-Key generated by Callwise, so POST and PATCH can be retried when the server
     * supports
     * idempotency keys. The key is generated once and reused on every attempt, sync and async. A non-blank
     * Idempotency-Key already set by the caller is kept.
     *
     * The key only lives in this request. To deduplicate across transactions (a user clicking twice), set a
     * business key instead, e.g. header('Idempotency-Key', order.Id).
     *
     * @return `CallwiseRequest` This request
     */
    public CallwiseRequest idempotent() {
        if (getIdempotencyKey() == null) {
            header(IDEMPOTENCY_KEY_HEADER, UUID.randomUUID().toString());
        }
        return this;
    }

    /**
     * @description Appends a URL-encoded query parameter. Repeated names are kept, in call order.
     *
     * @param name `String` Parameter name
     * @param value `String` Parameter value; null is sent as an empty string
     * @return `CallwiseRequest` This request
     * @throws `CallwiseException` INVALID_REQUEST when name is blank
     */
    public CallwiseRequest param(String name, String value) {
        if (String.isBlank(name)) {
            throw invalid('Query parameter name must not be blank.');
        }
        queryParameters.add(EncodingUtil.urlEncode(name, UTF8) + '=' + EncodingUtil.urlEncode(value ?? '', UTF8));
        return this;
    }

    /**
     * @description Sets a raw body. Set the Content-Type header yourself.
     *
     * @param body `String` Request body
     * @return `CallwiseRequest` This request
     */
    public CallwiseRequest body(String body) {
        this.requestBody = body;
        return this;
    }

    /**
     * @description Serializes the payload as JSON and sets Content-Type: application/json unless a Content-Type was
     * already set.
     * Null fields of Apex objects are omitted; null values inside a Map are kept (platform behaviour of
     * JSON.serialize(value, true)).
     *
     * @param payload `Object` Any JSON-serializable value
     * @return `CallwiseRequest` This request
     */
    public CallwiseRequest jsonBody(Object payload) {
        this.requestBody = JSON.serialize(payload, true);
        if (findHeaderName(CONTENT_TYPE_HEADER) == null) {
            headers.put(CONTENT_TYPE_HEADER, JSON_CONTENT_TYPE);
        }
        return this;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Behaviour
    // ---------------------------------------------------------------------------------------------------------

    /**
     * @description Per-attempt timeout. All attempts in a transaction share the platform's 120 s cumulative callout
     * budget.
     *
     * @param milliseconds `Integer` Between 1 and MAX_TIMEOUT_MS
     * @return `CallwiseRequest` This request
     * @throws `CallwiseException` INVALID_REQUEST when out of range
     */
    public CallwiseRequest timeout(Integer milliseconds) {
        if (milliseconds == null || milliseconds < 1 || milliseconds > MAX_TIMEOUT_MS) {
            throw invalid('timeout must be between 1 and ' + MAX_TIMEOUT_MS + ' ms, got ' + milliseconds + '.');
        }
        timeoutMs = milliseconds;
        return this;
    }

    /**
     * @description Sets the retry policy. The default is CallwiseRetryPolicy.transientErrors().
     *
     * @param policy `CallwiseRetryPolicy` Retry policy; use CallwiseRetryPolicy.none() to disable retries
     * @return `CallwiseRequest` This request
     * @throws `CallwiseException` INVALID_REQUEST when policy is null
     */
    public CallwiseRequest retry(CallwiseRetryPolicy policy) {
        if (policy == null) {
            throw invalid('retry() requires a policy. Use CallwiseRetryPolicy.none() to disable retries.');
        }
        retryPolicy = policy;
        return this;
    }

    /**
     * @description Bypasses the circuit breaker for this request: it is sent even when the breaker is open, and its
     * outcome
     * does not change the breaker state.
     *
     * @return `CallwiseRequest` This request
     */
    public CallwiseRequest withoutCircuitBreaker() {
        circuitBreakerEnabled = false;
        return this;
    }

    /**
     * @description Throw a CallwiseException with reason HTTP_ERROR when the final response is not 2xx.
     *
     * @return `CallwiseRequest` This request
     */
    public CallwiseRequest throwOnError() {
        throwOnErrorEnabled = true;
        return this;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Execution
    // ---------------------------------------------------------------------------------------------------------

    /**
     * @description Sends the request synchronously, retrying immediately within the transaction's limits budget.
     *
     * @return `CallwiseResponse` Final response, whatever its status
     * @throws `CallwiseException` TRANSPORT, TIMEOUT, CIRCUIT_OPEN, LIMIT_BUDGET, UNCOMMITTED_WORK, INVALID_REQUEST,
     *         or HTTP_ERROR when throwOnError() is set
     */
    public CallwiseResponse send() {
        requireMethod();
        return new CallwiseEngine().send(this);
    }

    /**
     * @description Sends the request from a Queueable, with real backoff between attempts. Fire-and-forget: no
     * callback.
     *
     * @return `Id` Id of the enqueued job
     * @throws `CallwiseException` INVALID_REQUEST when the request is incomplete
     */
    public Id sendAsync() {
        requireMethod();
        return new CallwiseEngine().sendAsync(this, null);
    }

    /**
     * @description Sends the request from a Queueable, with real backoff between attempts, and reports the outcome to
     * a new
     * instance of callbackType.
     *
     * @param callbackType `Type` Class implementing Callwise.Callback with a public no-argument constructor
     * @return `Id` Id of the enqueued job
     * @throws `CallwiseException` INVALID_REQUEST when the request is incomplete or callbackType is not a valid
     * callback
     */
    public Id sendAsync(Type callbackType) {
        requireMethod();
        validateCallbackType(callbackType);
        return new CallwiseEngine().sendAsync(this, callbackType.getName());
    }

    // ---------------------------------------------------------------------------------------------------------
    // Getters
    // ---------------------------------------------------------------------------------------------------------

    /**
     * @description Returns the Named Credential the request is sent through.
     *
     * @return `String` API name of the Named Credential
     */
    public String getNamedCredential() {
        return namedCredential;
    }

    /**
     * @description Returns the HTTP method.
     *
     * @return `String` HTTP method in upper case, or null when not set yet
     */
    public String getMethod() {
        return method;
    }

    /**
     * @description Returns the path as given to get(), post() and the other method setters.
     *
     * @return `String` Path relative to the Named Credential, without the parameters added through param()
     */
    public String getPath() {
        return path;
    }

    /**
     * @description Builds the endpoint used for the callout, with the parameters added through param().
     *
     * @return `String` Full endpoint, e.g. 'callout:Stripe_API/v1/customers?limit=10'
     */
    public String getEndpoint() {
        String endpoint = CALLOUT_PREFIX + namedCredential + path;
        if (queryParameters.isEmpty()) {
            return endpoint;
        }
        return endpoint + (path.contains('?') ? '&' : '?') + String.join(queryParameters, '&');
    }

    /**
     * @description Returns the request headers.
     *
     * @return `Map<String, String>` Copy of the headers, with names as provided
     */
    public Map<String, String> getHeaders() {
        return headers.clone();
    }

    /**
     * @description Returns the request body set with body() or jsonBody().
     *
     * @return `String` Request body, or null
     */
    public String getBody() {
        return requestBody;
    }

    /**
     * @description Returns the timeout of each attempt.
     *
     * @return `Integer` Per-attempt timeout, in milliseconds
     */
    public Integer getTimeoutMs() {
        return timeoutMs;
    }

    /**
     * @description Returns the retry policy of the request.
     *
     * @return `CallwiseRetryPolicy` Retry policy in effect
     */
    public CallwiseRetryPolicy getRetryPolicy() {
        return retryPolicy;
    }

    /**
     * @description Tells whether the request goes through the circuit breaker of its Named Credential.
     *
     * @return `Boolean` False when withoutCircuitBreaker() was called
     */
    public Boolean isCircuitBreakerEnabled() {
        return circuitBreakerEnabled;
    }

    /**
     * @description Tells whether a non-2xx final response raises HTTP_ERROR.
     *
     * @return `Boolean` True when throwOnError() was called
     */
    public Boolean isThrowOnError() {
        return throwOnErrorEnabled;
    }

    /**
     * @description Tells whether the request can be repeated safely.
     *
     * @return `Boolean` True for GET, HEAD, PUT and DELETE, or when a non-blank Idempotency-Key header is set
     */
    public Boolean isIdempotent() {
        return IDEMPOTENT_METHODS.contains(method) || getIdempotencyKey() != null;
    }

    /**
     * @description Returns the Idempotency-Key the request sends, set by the caller or by idempotent().
     *
     * @return `String` Value of the Idempotency-Key header, or null when it is absent or blank
     */
    public String getIdempotencyKey() {
        String keyHeader = findHeaderName(IDEMPOTENCY_KEY_HEADER);
        String value = keyHeader == null ? null : headers.get(keyHeader);
        return String.isBlank(value) ? null : value;
    }

    /**
     * @description Builds the platform request for a single attempt.
     *
     * @return `HttpRequest` New HttpRequest
     * @throws `CallwiseException` INVALID_REQUEST when no HTTP method was set
     */
    public HttpRequest toHttpRequest() {
        requireMethod();
        HttpRequest request = new HttpRequest();
        request.setMethod(method);
        request.setEndpoint(getEndpoint());
        request.setTimeout(timeoutMs);
        for (String name : headers.keySet()) {
            request.setHeader(name, headers.get(name));
        }
        if (requestBody != null) {
            request.setBody(requestBody);
        }
        return request;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------

    /**
     * @description Sets the method and normalizes the path: trims it, rejects absolute URLs and adds a missing
     * leading '/'.
     *
     * @param httpMethod `String` HTTP method in upper case
     * @param requestPath `String` Path relative to the Named Credential
     * @return `CallwiseRequest` This request
     * @throws `CallwiseException` INVALID_REQUEST when the path is an absolute URL
     */
    private CallwiseRequest withMethod(String httpMethod, String requestPath) {
        String normalizedPath = String.isBlank(requestPath) ? '' : requestPath.trim();
        if (normalizedPath.contains('://')) {
            throw invalid('Path must be relative to the Named Credential, got an absolute URL: ' + normalizedPath);
        }
        if (normalizedPath.length() > 0 && !normalizedPath.startsWith('/') && !normalizedPath.startsWith('?')) {
            normalizedPath = '/' + normalizedPath;
        }
        method = httpMethod;
        path = normalizedPath;
        return this;
    }

    /**
     * @description Finds a header by name, ignoring case.
     *
     * @param name `String` Header name in any case
     * @return `String` Header name as stored, or null when the header is not set
     */
    private String findHeaderName(String name) {
        for (String existingName : headers.keySet()) {
            if (existingName.equalsIgnoreCase(name)) {
                return existingName;
            }
        }
        return null;
    }

    /**
     * @description Checks that an HTTP method was set before sending.
     *
     * @throws `CallwiseException` INVALID_REQUEST when no method was set
     */
    private void requireMethod() {
        if (method == null) {
            throw invalid('No HTTP method set. Call get(), head(), post(), put(), patch() or del() first.');
        }
    }

    /**
     * @description Checks, before enqueueing, that a callback type can be instantiated and implements
     * Callwise.Callback, so a bad callback fails now and not in the Queueable.
     *
     * @param callbackType `Type` Callback class
     * @throws `CallwiseException` INVALID_REQUEST when the type is null, cannot be instantiated or is not a callback
     */
    private static void validateCallbackType(Type callbackType) {
        if (callbackType == null) {
            throw invalid('sendAsync() requires a callback type. Use sendAsync() without arguments for no callback.');
        }
        Object instance;
        try {
            instance = callbackType.newInstance();
        } catch (Exception e) {
            throw CallwiseException.create(
                CallwiseException.FailureReason.INVALID_REQUEST,
                callbackType.getName() + ' cannot be instantiated; it needs a public no-argument constructor.',
                e
            );
        }
        if (!(instance instanceof Callwise.Callback)) {
            throw invalid(callbackType.getName() + ' does not implement Callwise.Callback.');
        }
    }

    /**
     * @description Builds an INVALID_REQUEST exception.
     *
     * @param message `String` Description of the invalid argument
     * @return `CallwiseException` Exception, ready to throw
     */
    private static CallwiseException invalid(String message) {
        return CallwiseException.create(CallwiseException.FailureReason.INVALID_REQUEST, message);
    }
}
