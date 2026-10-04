/**
 * Serializable snapshot of an HTTP response. HttpResponse cannot be serialized, so Callwise copies status,
 * body and headers into this class; that lets async jobs carry responses in their state.
 * Header names are stored in lower case and looked up case-insensitively.
 *
 * @example
 * CallwiseResponse res = Callwise.to('Stripe_API').get('/v1/customers/cus_123').send();
 * if (res.isSuccess()) {
 *     Customer c = (Customer) res.deserialize(Customer.class);
 * }
 */
public inherited sharing class CallwiseResponse {
  private final Integer statusCode;
  private final String status;
  private final String body;
  private final Map<String, String> headersByLowerName = new Map<String, String>();
  private final Integer attempts;
  private final Long elapsedMs;

  /**
   * Copies the relevant parts of a platform HttpResponse.
   *
   * @param response Platform response
   * @param attempts Number of attempts made to obtain this response (1 = no retries)
   * @param elapsedMs Wall-clock time across all attempts, in milliseconds
   * @throws CallwiseException INVALID_REQUEST when response is null
   */
  public CallwiseResponse(HttpResponse response, Integer attempts, Long elapsedMs) {
    if (response == null) {
      throw CallwiseException.create(
        CallwiseException.FailureReason.INVALID_REQUEST,
        'Cannot build a CallwiseResponse from a null HttpResponse.'
      );
    }
    this.statusCode = response.getStatusCode();
    this.status = response.getStatus();
    this.body = response.getBody();
    this.attempts = attempts ?? 1;
    this.elapsedMs = elapsedMs ?? 0;
    for (String name : response.getHeaderKeys()) {
      // getHeaderKeys() can contain a null key (the status line on some stacks).
      if (name != null) {
        this.headersByLowerName.put(name.toLowerCase(), response.getHeader(name));
      }
    }
  }

  /**
   * @return HTTP status code, e.g. 200
   */
  public Integer getStatusCode() {
    return statusCode;
  }

  /**
   * @return HTTP reason phrase, e.g. 'OK'. May be blank.
   */
  public String getStatus() {
    return status;
  }

  /**
   * @return Raw response body. May be null or empty.
   */
  public String getBody() {
    return body;
  }

  /**
   * @param name Header name, any case
   * @return Header value, or null when absent
   */
  public String getHeader(String name) {
    return String.isBlank(name) ? null : headersByLowerName.get(name.toLowerCase());
  }

  /**
   * @return Copy of all headers, keyed by lower-case name
   */
  public Map<String, String> getHeaders() {
    return headersByLowerName.clone();
  }

  /**
   * @return Number of attempts made to obtain this response (1 = no retries)
   */
  public Integer getAttempts() {
    return attempts;
  }

  /**
   * @return Wall-clock time across all attempts, in milliseconds
   */
  public Long getElapsedMs() {
    return elapsedMs;
  }

  /**
   * Parses the Retry-After header. Only the delay-seconds form is supported; HTTP dates return null.
   *
   * @return Seconds to wait, or null when the header is absent or not a non-negative integer
   */
  public Long getRetryAfterSeconds() {
    String value = getHeader('Retry-After')?.trim();
    // 18 digits always fits in a Long.
    if (String.isBlank(value) || !value.isNumeric() || value.length() > 18) {
      return null;
    }
    return Long.valueOf(value);
  }

  /**
   * @return True for 2xx statuses
   */
  public Boolean isSuccess() {
    return statusCode >= 200 && statusCode < 300;
  }

  /**
   * @return True for 4xx statuses
   */
  public Boolean isClientError() {
    return statusCode >= 400 && statusCode < 500;
  }

  /**
   * @return True for 5xx statuses
   */
  public Boolean isServerError() {
    return statusCode >= 500 && statusCode < 600;
  }

  /**
   * Deserializes the JSON body into the given type. Unknown properties are ignored.
   *
   * @param targetType Apex type to deserialize into, e.g. Customer.class
   * @return Deserialized instance, or null when the body is blank
   * @throws CallwiseException INVALID_REQUEST when targetType is null
   * @throws JSONException when the body is not valid JSON for targetType
   */
  public Object deserialize(Type targetType) {
    if (targetType == null) {
      throw CallwiseException.create(
        CallwiseException.FailureReason.INVALID_REQUEST,
        'deserialize() requires a target type.'
      );
    }
    return String.isBlank(body) ? null : JSON.deserialize(body, targetType);
  }

  /**
   * Deserializes the JSON body into maps, lists and primitives.
   *
   * @return Deserialized value, or null when the body is blank
   * @throws JSONException when the body is not valid JSON
   */
  public Object deserializeUntyped() {
    return String.isBlank(body) ? null : JSON.deserializeUntyped(body);
  }
}
