/**
 * @description Serializable snapshot of an HTTP response. HttpResponse cannot be serialized, so Callwise copies status,
 * body and headers into this class; that lets async jobs carry responses in their state. Header names are stored in
 * lower case and looked up case-insensitively.
 *
 * @example
 * CallwiseResponse res = Callwise.to('Stripe_API').get('/v1/customers/cus_123').send();
 * if (res.isSuccess()) {
 *     Customer c = (Customer) res.deserialize(Customer.class);
 * }
 */
public inherited sharing class CallwiseResponse {
    /** @description IMF-fixdate, the HTTP-date form senders must use (RFC 9110, section 5.6.7). */
    private static final Pattern IMF_FIXDATE = Pattern.compile(
        '^(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun), (\\d{2}) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (\\d{4}) (\\d{2}):(\\d{2}):(\\d{2}) GMT$'
    );
    /** @description Month abbreviations of IMF-fixdate, in calendar order. */
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

    /** @description Replaces the clock in tests. */
    @TestVisible
    private static Long nowOverride;

    /** @description HTTP status code. */
    private final Integer statusCode;
    /** @description HTTP reason phrase; may be blank. */
    private final String status;
    /** @description Response body; may be null or empty. */
    private final String body;
    /** @description Headers keyed by lower-case name. */
    private final Map<String, String> headersByLowerName = new Map<String, String>();
    /** @description Attempts made to obtain this response. */
    private final Integer attempts;
    /** @description Wall-clock time across all attempts, in milliseconds. */
    private final Long elapsedMs;

    /**
     * @description Copies the relevant parts of a platform HttpResponse.
     *
     * @param response `HttpResponse` Platform response
     * @param attempts `Integer` Number of attempts made to obtain this response (1 = no retries)
     * @param elapsedMs `Long` Wall-clock time across all attempts, in milliseconds
     * @throws `CallwiseException` INVALID_REQUEST when response is null
     */
    public CallwiseResponse(HttpResponse response, Integer attempts, Long elapsedMs) {
        if (response == null) {
            throw CallwiseException.invalidRequest('Cannot build a CallwiseResponse from a null HttpResponse.');
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
     * @description Returns the HTTP status code.
     *
     * @return `Integer` HTTP status code, e.g. 200
     */
    public Integer getStatusCode() {
        return this.statusCode;
    }

    /**
     * @description Returns the HTTP reason phrase.
     *
     * @return `String` HTTP reason phrase, e.g. 'OK'. May be blank.
     */
    public String getStatus() {
        return this.status;
    }

    /**
     * @description Returns the response body as received.
     *
     * @return `String` Raw response body. May be null or empty.
     */
    public String getBody() {
        return this.body;
    }

    /**
     * @description Returns one header, looked up case-insensitively.
     *
     * @param name `String` Header name, any case
     * @return `String` Header value, or null when absent
     */
    public String getHeader(String name) {
        return String.isBlank(name) ? null : this.headersByLowerName.get(name.toLowerCase());
    }

    /**
     * @description Returns every response header.
     *
     * @return `Map<String, String>` Copy of all headers, keyed by lower-case name
     */
    public Map<String, String> getHeaders() {
        return this.headersByLowerName.clone();
    }

    /**
     * @description Returns how many attempts were made to obtain this response.
     *
     * @return `Integer` Number of attempts made to obtain this response (1 = no retries)
     */
    public Integer getAttempts() {
        return this.attempts;
    }

    /**
     * @description Returns the wall-clock time spent obtaining this response.
     *
     * @return `Long` Wall-clock time across all attempts, in milliseconds
     */
    public Long getElapsedMs() {
        return this.elapsedMs;
    }

    /**
     * @description Parses the Retry-After header, in either form allowed by RFC 9110: delay-seconds (Retry-After: 120)
     * or an HTTP date in IMF-fixdate format (Retry-After: Wed, 21 Oct 2026 07:28:00 GMT).
     *
     * @return `Long` Seconds to wait (0 for a date in the past), or null when the header is absent or cannot be parsed
     */
    public Long getRetryAfterSeconds() {
        String value = this.getHeader('Retry-After')?.trim();
        if (String.isBlank(value)) {
            return null;
        }
        if (value.isNumeric()) {
            // 18 digits always fits in a Long.
            return value.length() > 18 ? null : Long.valueOf(value);
        }
        return this.secondsUntil(value);
    }

    /**
     * @description Tells whether the status is 2xx.
     *
     * @return `Boolean` True for 2xx statuses
     */
    public Boolean isSuccess() {
        return this.statusCode >= 200 && this.statusCode < 300;
    }

    /**
     * @description Tells whether the status is 4xx.
     *
     * @return `Boolean` True for 4xx statuses
     */
    public Boolean isClientError() {
        return this.statusCode >= 400 && this.statusCode < 500;
    }

    /**
     * @description Tells whether the status is 5xx.
     *
     * @return `Boolean` True for 5xx statuses
     */
    public Boolean isServerError() {
        return this.statusCode >= 500 && this.statusCode < 600;
    }

    /**
     * @description Deserializes the JSON body into the given type. Unknown properties are ignored.
     *
     * @param targetType `Type` Apex type to deserialize into, e.g. Customer.class
     * @return `Object` Deserialized instance, or null when the body is blank
     * @throws `CallwiseException` INVALID_REQUEST when targetType is null
     * @throws `JSONException` when the body is not valid JSON for targetType
     */
    public Object deserialize(Type targetType) {
        if (targetType == null) {
            throw CallwiseException.invalidRequest('deserialize() requires a target type.');
        }
        return String.isBlank(this.body) ? null : JSON.deserialize(this.body, targetType);
    }

    /**
     * @description Deserializes the JSON body into maps, lists and primitives.
     *
     * @return `Object` Deserialized value, or null when the body is blank
     * @throws `JSONException` when the body is not valid JSON
     */
    public Object deserializeUntyped() {
        return String.isBlank(this.body) ? null : JSON.deserializeUntyped(this.body);
    }

    /**
     * @description Parses an IMF-fixdate and returns the time until it. Dates that do not exist (31 February, hour 24)
     * are rejected: Datetime would roll them over silently.
     *
     * @param httpDate `String` Date such as 'Wed, 21 Oct 2026 07:28:00 GMT'
     * @return `Long` Seconds until the date, rounded up; 0 when it has passed; null when it cannot be parsed
     */
    private Long secondsUntil(String httpDate) {
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
        return remainingMs <= 0 ? 0 : Math.ceil((Double) remainingMs / 1000).longValue();
    }
}
