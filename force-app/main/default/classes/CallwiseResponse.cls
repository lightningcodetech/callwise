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
    /** IMF-fixdate, the HTTP-date form senders must use (RFC 9110, section 5.6.7). */
    private static final Pattern IMF_FIXDATE = Pattern.compile(
        '^(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun), (\\d{2}) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (\\d{4}) (\\d{2}):(\\d{2}):(\\d{2}) GMT$'
    );
    private static final List<String> MONTHS = new List<String>{
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec'
    };

    /** Replaces the clock in tests. */
    @TestVisible
    private static Long nowOverride;

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
     * Parses the Retry-After header, in either form allowed by RFC 9110: delay-seconds (Retry-After: 120) or an
     * HTTP date in IMF-fixdate format (Retry-After: Wed, 21 Oct 2026 07:28:00 GMT).
     *
     * @return Seconds to wait (0 for a date in the past), or null when the header is absent or cannot be parsed
     */
    public Long getRetryAfterSeconds() {
        String value = getHeader('Retry-After')?.trim();
        if (String.isBlank(value)) {
            return null;
        }
        if (value.isNumeric()) {
            // 18 digits always fits in a Long.
            return value.length() > 18 ? null : Long.valueOf(value);
        }
        return secondsUntil(value);
    }

    private static Long secondsUntil(String httpDate) {
        Matcher parts = IMF_FIXDATE.matcher(httpDate);
        if (!parts.matches()) {
            return null;
        }
        Integer day = Integer.valueOf(parts.group(1));
        Integer month = MONTHS.indexOf(parts.group(2)) + 1;
        Integer year = Integer.valueOf(parts.group(3));
        Integer hour = Integer.valueOf(parts.group(4));
        Integer minute = Integer.valueOf(parts.group(5));
        Integer second = Integer.valueOf(parts.group(6));
        // Datetime rolls invalid values over (31 Feb → 3 Mar): reject anything that does not round-trip.
        Datetime instant = Datetime.newInstanceGmt(year, month, day, hour, minute, second);
        if (
            instant.dayGmt() != day ||
            instant.monthGmt() != month ||
            instant.yearGmt() != year ||
            instant.hourGmt() != hour ||
            instant.minuteGmt() != minute ||
            instant.secondGmt() != second
        ) {
            return null;
        }
        Long remainingMs = instant.getTime() - (nowOverride ?? System.currentTimeMillis());
        return remainingMs <= 0 ? 0 : (remainingMs + 999) / 1000;
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
