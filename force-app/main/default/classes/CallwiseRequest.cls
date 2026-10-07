/**
 * @description Fluent builder for a callout through a Named Credential. Obtain one with Callwise.to(namedCredential).
 *
 * Defaults: 10 s timeout, CallwiseRetryPolicy.transientErrors() (which only retries idempotent methods), circuit
 * breaker enabled, HTTP errors returned rather than thrown.
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
            throw CallwiseException.invalidRequest(
                String.format(
                    'Expected the API name of a Named Credential (e.g. Stripe_API), got "{0}". ' +
                    'Raw URLs are not supported.',
                    new List<Object>{ namedCredential }
                )
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
        return this.withMethod('GET', path);
    }

    /**
     * @description Sets the HTTP method to HEAD and the path.
     *
     * @param path `String` Path relative to the Named Credential URL
     * @return `CallwiseRequest` This request
     */
    public CallwiseRequest head(String path) {
        return this.withMethod('HEAD', path);
    }

    /**
     * @description Sets the HTTP method to POST and the path. POST is retried only with an Idempotency-Key.
     *
     * @param path `String` Path relative to the Named Credential URL
     * @return `CallwiseRequest` This request
     */
    public CallwiseRequest post(String path) {
        return this.withMethod('POST', path);
    }

    /**
     * @description Sets the HTTP method to PUT and the path.
     *
     * @param path `String` Path relative to the Named Credential URL
     * @return `CallwiseRequest` This request
     */
    public CallwiseRequest put(String path) {
        return this.withMethod('PUT', path);
    }

    /**
     * @description Sets the HTTP method to PATCH and the path. PATCH is retried only with an Idempotency-Key.
     *
     * @param path `String` Path relative to the Named Credential URL
     * @return `CallwiseRequest` This request
     */
    public CallwiseRequest patch(String path) {
        return this.withMethod('PATCH', path);
    }

    /**
     * @description DELETE request. Named del because delete is a reserved word in Apex.
     *
     * @param path `String` Path relative to the Named Credential URL
     * @return `CallwiseRequest` This request
     */
    public CallwiseRequest del(String path) {
        return this.withMethod('DELETE', path);
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
            throw CallwiseException.invalidRequest('Header name must not be blank.');
        }
        this.headers.remove(this.findHeaderName(name));
        this.headers.put(name, value ?? '');
        return this;
    }

    /**
     * @description Sends an Idempotency-Key generated by Callwise, so POST and PATCH can be retried when the server
     * supports idempotency keys. The key is generated once and reused on every attempt, sync and async. A non-blank
     * Idempotency-Key already set by the caller is kept.
     *
     * The key only lives in this request. To deduplicate across transactions (a user clicking twice), set a business
     * key instead, e.g. header('Idempotency-Key', order.Id).
     *
     * @return `CallwiseRequest` This request
     */
    public CallwiseRequest idempotent() {
        if (this.getIdempotencyKey() == null) {
            this.header(IDEMPOTENCY_KEY_HEADER, UUID.randomUUID().toString());
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
            throw CallwiseException.invalidRequest('Query parameter name must not be blank.');
        }
        this.queryParameters.add(EncodingUtil.urlEncode(name, UTF8) + '=' + EncodingUtil.urlEncode(value ?? '', UTF8));
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
     * already set. Null fields of Apex objects are omitted; null values inside a Map are kept (platform behaviour of
     * JSON.serialize(value, true)).
     *
     * @param payload `Object` Any JSON-serializable value
     * @return `CallwiseRequest` This request
     */
    public CallwiseRequest jsonBody(Object payload) {
        this.requestBody = JSON.serialize(payload, true);
        if (this.findHeaderName(CONTENT_TYPE_HEADER) == null) {
            this.headers.put(CONTENT_TYPE_HEADER, JSON_CONTENT_TYPE);
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
            throw CallwiseException.invalidRequest(
                'timeout must be between 1 and ' + MAX_TIMEOUT_MS + ' ms, got ' + milliseconds + '.'
            );
        }
        this.timeoutMs = milliseconds;
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
            throw CallwiseException.invalidRequest(
                'retry() requires a policy. Use CallwiseRetryPolicy.none() to disable retries.'
            );
        }
        this.retryPolicy = policy;
        return this;
    }

    /**
     * @description Bypasses the circuit breaker for this request: it is sent even when the breaker is open, and its
     * outcome does not change the breaker state.
     *
     * @return `CallwiseRequest` This request
     */
    public CallwiseRequest withoutCircuitBreaker() {
        this.circuitBreakerEnabled = false;
        return this;
    }

    /**
     * @description Throw a CallwiseException with reason HTTP_ERROR when the final response is not 2xx.
     *
     * @return `CallwiseRequest` This request
     */
    public CallwiseRequest throwOnError() {
        this.throwOnErrorEnabled = true;
        return this;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Execution
    // ---------------------------------------------------------------------------------------------------------

    /**
     * @description Sends the request synchronously, retrying immediately within the transaction's limits budget.
     *
     * @return `CallwiseResponse` Final response, whatever its status
     * @throws `CallwiseException` TRANSPORT, TIMEOUT, CIRCUIT_OPEN, LIMIT_BUDGET, UNCOMMITTED_WORK, INVALID_REQUEST, or
     * HTTP_ERROR when throwOnError() is set
     */
    public CallwiseResponse send() {
        this.requireMethod();
        return new CallwiseEngine().send(this);
    }

    /**
     * @description Sends the request from a Queueable, with real backoff between attempts. Fire-and-forget: no
     * callback.
     *
     * @return `Id` Id of the enqueued job
     * @throws `CallwiseException` INVALID_REQUEST when the request is incomplete, LIMIT_BUDGET when no Queueable job
     * is left in this transaction
     */
    public Id sendAsync() {
        this.requireMethod();
        return new CallwiseEngine().sendAsync(this, null);
    }

    /**
     * @description Sends the request from a Queueable, with real backoff between attempts, and reports the outcome to a
     * new instance of callbackType.
     *
     * @param callbackType `Type` Class implementing Callwise.Callback with a public no-argument constructor
     * @return `Id` Id of the enqueued job
     * @throws `CallwiseException` INVALID_REQUEST when the request is incomplete or callbackType is not a valid
     * callback, LIMIT_BUDGET when no Queueable job is left in this transaction
     */
    public Id sendAsync(Type callbackType) {
        this.requireMethod();
        this.validateCallbackType(callbackType);
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
        return this.namedCredential;
    }

    /**
     * @description Returns the HTTP method.
     *
     * @return `String` HTTP method in upper case, or null when not set yet
     */
    public String getMethod() {
        return this.method;
    }

    /**
     * @description Returns the path as given to get(), post() and the other method setters.
     *
     * @return `String` Path relative to the Named Credential, without the parameters added through param()
     */
    public String getPath() {
        return this.path;
    }

    /**
     * @description Builds the endpoint used for the callout, with the parameters added through param().
     *
     * @return `String` Full endpoint, e.g. 'callout:Stripe_API/v1/customers?limit=10'
     */
    public String getEndpoint() {
        String endpoint = CALLOUT_PREFIX + this.namedCredential + this.path;
        if (this.queryParameters.isEmpty()) {
            return endpoint;
        }
        return endpoint + (this.path.contains('?') ? '&' : '?') + String.join(this.queryParameters, '&');
    }

    /**
     * @description Returns the request headers.
     *
     * @return `Map<String, String>` Copy of the headers, with names as provided
     */
    public Map<String, String> getHeaders() {
        return this.headers.clone();
    }

    /**
     * @description Returns the request body set with body() or jsonBody().
     *
     * @return `String` Request body, or null
     */
    public String getBody() {
        return this.requestBody;
    }

    /**
     * @description Returns the timeout of each attempt.
     *
     * @return `Integer` Per-attempt timeout, in milliseconds
     */
    public Integer getTimeoutMs() {
        return this.timeoutMs;
    }

    /**
     * @description Returns the retry policy of the request.
     *
     * @return `CallwiseRetryPolicy` Retry policy in effect
     */
    public CallwiseRetryPolicy getRetryPolicy() {
        return this.retryPolicy;
    }

    /**
     * @description Tells whether the request goes through the circuit breaker of its Named Credential.
     *
     * @return `Boolean` False when withoutCircuitBreaker() was called
     */
    public Boolean isCircuitBreakerEnabled() {
        return this.circuitBreakerEnabled;
    }

    /**
     * @description Tells whether a non-2xx final response raises HTTP_ERROR.
     *
     * @return `Boolean` True when throwOnError() was called
     */
    public Boolean isThrowOnError() {
        return this.throwOnErrorEnabled;
    }

    /**
     * @description Tells whether the request can be repeated safely.
     *
     * @return `Boolean` True for GET, HEAD, PUT and DELETE, or when a non-blank Idempotency-Key header is set
     */
    public Boolean isIdempotent() {
        return IDEMPOTENT_METHODS.contains(this.method) || this.getIdempotencyKey() != null;
    }

    /**
     * @description Returns the Idempotency-Key the request sends, set by the caller or by idempotent().
     *
     * @return `String` Value of the Idempotency-Key header, or null when it is absent or blank
     */
    public String getIdempotencyKey() {
        String value = this.headers.get(this.findHeaderName(IDEMPOTENCY_KEY_HEADER));
        return String.isBlank(value) ? null : value;
    }

    /**
     * @description Builds the platform request for a single attempt.
     *
     * @return `HttpRequest` New HttpRequest
     * @throws `CallwiseException` INVALID_REQUEST when no HTTP method was set
     */
    public HttpRequest toHttpRequest() {
        this.requireMethod();
        HttpRequest request = new HttpRequest();
        request.setMethod(this.method);
        request.setEndpoint(this.getEndpoint());
        request.setTimeout(this.timeoutMs);
        for (String name : this.headers.keySet()) {
            request.setHeader(name, this.headers.get(name));
        }
        if (this.requestBody != null) {
            request.setBody(this.requestBody);
        }
        return request;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------

    /**
     * @description Sets the method and normalizes the path: trims it, rejects absolute URLs and adds a missing leading
     * '/'.
     *
     * @param httpMethod `String` HTTP method in upper case
     * @param requestPath `String` Path relative to the Named Credential
     * @return `CallwiseRequest` This request
     * @throws `CallwiseException` INVALID_REQUEST when the path is an absolute URL
     */
    private CallwiseRequest withMethod(String httpMethod, String requestPath) {
        String normalizedPath = requestPath?.trim() ?? '';
        if (normalizedPath.contains('://')) {
            throw CallwiseException.invalidRequest(
                'Path must be relative to the Named Credential, got an absolute URL: ' + normalizedPath
            );
        }
        if (normalizedPath.length() > 0 && !normalizedPath.startsWith('/') && !normalizedPath.startsWith('?')) {
            normalizedPath = '/' + normalizedPath;
        }
        this.method = httpMethod;
        this.path = normalizedPath;
        return this;
    }

    /**
     * @description Finds a header by name, ignoring case.
     *
     * @param name `String` Header name in any case
     * @return `String` Header name as stored, or null when the header is not set
     */
    private String findHeaderName(String name) {
        for (String existingName : this.headers.keySet()) {
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
        if (this.method == null) {
            throw CallwiseException.invalidRequest(
                'No HTTP method set. Call get(), head(), post(), put(), patch() or del() first.'
            );
        }
    }

    /**
     * @description Checks, before enqueueing, that a callback type can be instantiated and implements
     * Callwise.Callback, so a bad callback fails now and not in the Queueable.
     *
     * @param callbackType `Type` Callback class
     * @throws `CallwiseException` INVALID_REQUEST when the type is null, cannot be instantiated or is not a callback
     */
    private void validateCallbackType(Type callbackType) {
        if (callbackType == null) {
            throw CallwiseException.invalidRequest(
                'sendAsync() requires a callback type. Use sendAsync() without arguments for no callback.'
            );
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
            throw CallwiseException.invalidRequest(callbackType.getName() + ' does not implement Callwise.Callback.');
        }
    }
}
