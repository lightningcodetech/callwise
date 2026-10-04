/**
 * Fluent builder for a callout through a Named Credential. Obtain one with Callwise.to(namedCredential).
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
  /** Default per-attempt timeout, in milliseconds. Matches the platform default. */
  public static final Integer DEFAULT_TIMEOUT_MS = 10000;
  /** Maximum per-attempt timeout the platform allows, in milliseconds. */
  public static final Integer MAX_TIMEOUT_MS = 120000;

  private static final String CALLOUT_PREFIX = 'callout:';
  private static final String IDEMPOTENCY_KEY_HEADER = 'Idempotency-Key';
  private static final String CONTENT_TYPE_HEADER = 'Content-Type';
  private static final String JSON_CONTENT_TYPE = 'application/json';
  private static final String UTF8 = 'UTF-8';
  private static final Set<String> IDEMPOTENT_METHODS = new Set<String>{ 'GET', 'HEAD', 'PUT', 'DELETE' };
  private static final Pattern NAMED_CREDENTIAL_NAME = Pattern.compile('^[A-Za-z][A-Za-z0-9_]*$');

  private final String namedCredential;
  private String method;
  private String path = '';
  private final List<String> queryParameters = new List<String>();
  private final Map<String, String> headers = new Map<String, String>();
  private String requestBody;
  private Integer timeoutMs = DEFAULT_TIMEOUT_MS;
  private CallwiseRetryPolicy retryPolicy = CallwiseRetryPolicy.transientErrors();
  private Boolean circuitBreakerEnabled = true;
  private Boolean throwOnErrorEnabled = false;

  /**
   * Prefer Callwise.to(namedCredential).
   *
   * @param namedCredential API name of the Named Credential, without the 'callout:' prefix
   * @throws CallwiseException INVALID_REQUEST when the name is blank or not a valid API name
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
   * @param path Path relative to the Named Credential URL, e.g. '/v1/customers'. May include a query string.
   * @return This request
   */
  public CallwiseRequest get(String path) {
    return withMethod('GET', path);
  }

  /**
   * @param path Path relative to the Named Credential URL
   * @return This request
   */
  public CallwiseRequest head(String path) {
    return withMethod('HEAD', path);
  }

  /**
   * @param path Path relative to the Named Credential URL
   * @return This request
   */
  public CallwiseRequest post(String path) {
    return withMethod('POST', path);
  }

  /**
   * @param path Path relative to the Named Credential URL
   * @return This request
   */
  public CallwiseRequest put(String path) {
    return withMethod('PUT', path);
  }

  /**
   * @param path Path relative to the Named Credential URL
   * @return This request
   */
  public CallwiseRequest patch(String path) {
    return withMethod('PATCH', path);
  }

  /**
   * DELETE request. Named del because delete is a reserved word in Apex.
   *
   * @param path Path relative to the Named Credential URL
   * @return This request
   */
  public CallwiseRequest del(String path) {
    return withMethod('DELETE', path);
  }

  // ---------------------------------------------------------------------------------------------------------
  // Headers, parameters, body
  // ---------------------------------------------------------------------------------------------------------

  /**
   * Sets a header, replacing any existing header with the same name (case-insensitive).
   *
   * @param name Header name
   * @param value Header value; null is sent as an empty string
   * @return This request
   * @throws CallwiseException INVALID_REQUEST when name is blank
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
   * Appends a URL-encoded query parameter. Repeated names are kept, in call order.
   *
   * @param name Parameter name
   * @param value Parameter value; null is sent as an empty string
   * @return This request
   * @throws CallwiseException INVALID_REQUEST when name is blank
   */
  public CallwiseRequest param(String name, String value) {
    if (String.isBlank(name)) {
      throw invalid('Query parameter name must not be blank.');
    }
    queryParameters.add(EncodingUtil.urlEncode(name, UTF8) + '=' + EncodingUtil.urlEncode(value ?? '', UTF8));
    return this;
  }

  /**
   * Sets a raw body. Set the Content-Type header yourself.
   *
   * @param body Request body
   * @return This request
   */
  public CallwiseRequest body(String body) {
    this.requestBody = body;
    return this;
  }

  /**
   * Serializes the payload as JSON and sets Content-Type: application/json unless a Content-Type was already set.
   * Null fields of Apex objects are omitted; null values inside a Map are kept (platform behaviour of
   * JSON.serialize(value, true)).
   *
   * @param payload Any JSON-serializable value
   * @return This request
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
   * Per-attempt timeout. All attempts in a transaction share the platform's 120 s cumulative callout budget.
   *
   * @param milliseconds Between 1 and MAX_TIMEOUT_MS
   * @return This request
   * @throws CallwiseException INVALID_REQUEST when out of range
   */
  public CallwiseRequest timeout(Integer milliseconds) {
    if (milliseconds == null || milliseconds < 1 || milliseconds > MAX_TIMEOUT_MS) {
      throw invalid('timeout must be between 1 and ' + MAX_TIMEOUT_MS + ' ms, got ' + milliseconds + '.');
    }
    timeoutMs = milliseconds;
    return this;
  }

  /**
   * @param policy Retry policy; use CallwiseRetryPolicy.none() to disable retries
   * @return This request
   * @throws CallwiseException INVALID_REQUEST when policy is null
   */
  public CallwiseRequest retry(CallwiseRetryPolicy policy) {
    if (policy == null) {
      throw invalid('retry() requires a policy. Use CallwiseRetryPolicy.none() to disable retries.');
    }
    retryPolicy = policy;
    return this;
  }

  /**
   * Bypasses the circuit breaker for this request: it is sent even when the breaker is open, and its outcome
   * does not change the breaker state.
   *
   * @return This request
   */
  public CallwiseRequest withoutCircuitBreaker() {
    circuitBreakerEnabled = false;
    return this;
  }

  /**
   * Throw a CallwiseException with reason HTTP_ERROR when the final response is not 2xx.
   *
   * @return This request
   */
  public CallwiseRequest throwOnError() {
    throwOnErrorEnabled = true;
    return this;
  }

  // ---------------------------------------------------------------------------------------------------------
  // Execution
  // ---------------------------------------------------------------------------------------------------------

  /**
   * Sends the request synchronously, retrying immediately within the transaction's limits budget.
   *
   * @return Final response, whatever its status
   * @throws CallwiseException TRANSPORT, TIMEOUT, CIRCUIT_OPEN, LIMIT_BUDGET, UNCOMMITTED_WORK, INVALID_REQUEST,
   *         or HTTP_ERROR when throwOnError() is set
   */
  public CallwiseResponse send() {
    requireMethod();
    return new CallwiseEngine().send(this);
  }

  /**
   * Sends the request from a Queueable, with real backoff between attempts. Fire-and-forget: no callback.
   *
   * @return Id of the enqueued job
   * @throws CallwiseException INVALID_REQUEST when the request is incomplete
   */
  public Id sendAsync() {
    requireMethod();
    return new CallwiseEngine().sendAsync(this, null);
  }

  /**
   * Sends the request from a Queueable, with real backoff between attempts, and reports the outcome to a new
   * instance of callbackType.
   *
   * @param callbackType Class implementing Callwise.Callback with a public no-argument constructor
   * @return Id of the enqueued job
   * @throws CallwiseException INVALID_REQUEST when the request is incomplete or callbackType is not a valid callback
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
   * @return API name of the Named Credential
   */
  public String getNamedCredential() {
    return namedCredential;
  }

  /**
   * @return HTTP method in upper case, or null when not set yet
   */
  public String getMethod() {
    return method;
  }

  /**
   * @return Path relative to the Named Credential, without the parameters added through param()
   */
  public String getPath() {
    return path;
  }

  /**
   * @return Full endpoint, e.g. 'callout:Stripe_API/v1/customers?limit=10'
   */
  public String getEndpoint() {
    String endpoint = CALLOUT_PREFIX + namedCredential + path;
    if (queryParameters.isEmpty()) {
      return endpoint;
    }
    return endpoint + (path.contains('?') ? '&' : '?') + String.join(queryParameters, '&');
  }

  /**
   * @return Copy of the headers, with names as provided
   */
  public Map<String, String> getHeaders() {
    return headers.clone();
  }

  /**
   * @return Request body, or null
   */
  public String getBody() {
    return requestBody;
  }

  /**
   * @return Per-attempt timeout, in milliseconds
   */
  public Integer getTimeoutMs() {
    return timeoutMs;
  }

  /**
   * @return Retry policy in effect
   */
  public CallwiseRetryPolicy getRetryPolicy() {
    return retryPolicy;
  }

  /**
   * @return False when withoutCircuitBreaker() was called
   */
  public Boolean isCircuitBreakerEnabled() {
    return circuitBreakerEnabled;
  }

  /**
   * @return True when throwOnError() was called
   */
  public Boolean isThrowOnError() {
    return throwOnErrorEnabled;
  }

  /**
   * @return True for GET, HEAD, PUT and DELETE, or when a non-blank Idempotency-Key header is set
   */
  public Boolean isIdempotent() {
    if (IDEMPOTENT_METHODS.contains(method)) {
      return true;
    }
    String keyHeader = findHeaderName(IDEMPOTENCY_KEY_HEADER);
    return keyHeader != null && String.isNotBlank(headers.get(keyHeader));
  }

  /**
   * Builds the platform request for a single attempt.
   *
   * @return New HttpRequest
   * @throws CallwiseException INVALID_REQUEST when no HTTP method was set
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

  private String findHeaderName(String name) {
    for (String existingName : headers.keySet()) {
      if (existingName.equalsIgnoreCase(name)) {
        return existingName;
      }
    }
    return null;
  }

  private void requireMethod() {
    if (method == null) {
      throw invalid('No HTTP method set. Call get(), head(), post(), put(), patch() or del() first.');
    }
  }

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

  private static CallwiseException invalid(String message) {
    return CallwiseException.create(CallwiseException.FailureReason.INVALID_REQUEST, message);
  }
}
