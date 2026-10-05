/**
 * @description Tests for CallwiseResponse: copy of status, body and headers, Retry-After in both forms, status helpers
 * and deserialization.
 */
@IsTest
private class CallwiseResponseTest {
    private static final String CUSTOMER_JSON = '{"id":"cus_123","name":"Ada","unknown":true}';

    @IsTest
    static void shouldCopyStatusBodyAndMetricsWhenBuilt() {
        CallwiseResponse response = new CallwiseResponse(raw(201, 'Created', CUSTOMER_JSON, null), 2, 150L);

        Assert.areEqual(201, response.getStatusCode(), 'Status code should be copied');
        Assert.areEqual('Created', response.getStatus(), 'Status text should be copied');
        Assert.areEqual(CUSTOMER_JSON, response.getBody(), 'Body should be copied');
        Assert.areEqual(2, response.getAttempts(), 'Attempts should be kept');
        Assert.areEqual(150L, response.getElapsedMs(), 'Elapsed time should be kept');
    }

    @IsTest
    static void shouldDefaultMetricsWhenNull() {
        CallwiseResponse response = new CallwiseResponse(raw(200, 'OK', '', null), null, null);

        Assert.areEqual(1, response.getAttempts(), 'Null attempts should default to 1');
        Assert.areEqual(0L, response.getElapsedMs(), 'Null elapsed should default to 0');
    }

    @IsTest
    static void shouldThrowInvalidRequestWhenHttpResponseIsNull() {
        try {
            new CallwiseResponse(null, 1, 0L);
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.INVALID_REQUEST, e.reason, 'Null response is invalid');
        }
    }

    @IsTest
    static void shouldLookUpHeadersCaseInsensitively() {
        CallwiseResponse response = withHeaders(new Map<String, String>{ 'X-Request-Id' => 'req-1' });

        Assert.areEqual('req-1', response.getHeader('x-request-id'), 'Lower-case lookup should match');
        Assert.areEqual('req-1', response.getHeader('X-REQUEST-ID'), 'Upper-case lookup should match');
        Assert.areEqual('req-1', response.getHeaders().get('x-request-id'), 'Header map should use lower case');
    }

    @IsTest
    static void shouldReturnNullWhenHeaderNameIsBlankOrMissing() {
        CallwiseResponse response = withHeaders(new Map<String, String>{ 'X-Request-Id' => 'req-1' });

        Assert.isNull(response.getHeader(''), 'Blank name should return null');
        Assert.isNull(response.getHeader('X-Missing'), 'Missing header should return null');
    }

    @IsTest
    static void shouldReturnCopyOfHeaders() {
        CallwiseResponse response = withHeaders(new Map<String, String>{ 'X-Request-Id' => 'req-1' });

        response.getHeaders().put('x-request-id', 'tampered');

        Assert.areEqual('req-1', response.getHeader('X-Request-Id'), 'Internal headers must not be mutable');
    }

    @IsTest
    static void shouldParseRetryAfterWhenNumeric() {
        CallwiseResponse response = withHeaders(new Map<String, String>{ 'Retry-After' => ' 120 ' });

        Assert.areEqual(120L, response.getRetryAfterSeconds(), 'Numeric Retry-After should be parsed');
    }

    @IsTest
    static void shouldParseRetryAfterWhenHttpDate() {
        CallwiseResponse.nowOverride = Datetime.newInstanceGmt(2026, 10, 21, 7, 26, 0).getTime();

        Assert.areEqual(120L, retryAfter('Wed, 21 Oct 2026 07:28:00 GMT'), 'Seconds from now until the date');
    }

    @IsTest
    static void shouldRoundHttpDateUpToWholeSeconds() {
        CallwiseResponse.nowOverride = Datetime.newInstanceGmt(2026, 10, 21, 7, 27, 59).getTime() + 500;

        Assert.areEqual(1L, retryAfter('Wed, 21 Oct 2026 07:28:00 GMT'), 'Half a second left waits 1 second');
    }

    @IsTest
    static void shouldReturnZeroWhenHttpDateIsInThePast() {
        CallwiseResponse.nowOverride = Datetime.newInstanceGmt(2026, 10, 21, 8, 0, 0).getTime();

        Assert.areEqual(0L, retryAfter('Wed, 21 Oct 2026 07:28:00 GMT'), 'A past date means no wait');
    }

    @IsTest
    static void shouldIgnoreRetryAfterWhenDateIsInvalid() {
        CallwiseResponse.nowOverride = Datetime.newInstanceGmt(2026, 10, 21, 7, 0, 0).getTime();
        List<String> invalid = new List<String>{
            'Wed, 31 Feb 2026 07:28:00 GMT', // no 31 February
            'Wed, 21 Oct 2026 24:00:00 GMT', // no hour 24
            'Wed, 21 Oct 2026 07:28:00 UTC', // must be GMT
            'Wednesday, 21-Oct-26 07:28:00 GMT', // obsolete RFC 850 form
            'Wed Oct 21 07:28:00 2026', // obsolete asctime form
            'Wed, 21 oct 2026 07:28:00 GMT', // month is case-sensitive
            'tomorrow',
            '-5'
        };

        for (String value : invalid) {
            Assert.isNull(retryAfter(value), 'Should not parse "' + value + '"');
        }
    }

    @IsTest
    static void shouldUseHttpDateForAsyncBackoff() {
        CallwiseResponse.nowOverride = Datetime.newInstanceGmt(2026, 10, 21, 7, 25, 30).getTime();
        CallwiseResponse response = withHeaders(
            new Map<String, String>{ 'Retry-After' => 'Wed, 21 Oct 2026 07:28:00 GMT' }
        );

        Assert.areEqual(
            3,
            CallwiseRetryPolicy.transientErrors().asyncDelayMinutes(1, response),
            '150 s until the date is rounded up to 3 minutes'
        );
    }

    @IsTest
    static void shouldIgnoreRetryAfterWhenTooLong() {
        CallwiseResponse response = withHeaders(new Map<String, String>{ 'Retry-After' => '1234567890123456789' });

        Assert.isNull(response.getRetryAfterSeconds(), 'Values longer than 18 digits are ignored');
    }

    @IsTest
    static void shouldReturnNullRetryAfterWhenAbsent() {
        CallwiseResponse response = withHeaders(new Map<String, String>());

        Assert.isNull(response.getRetryAfterSeconds(), 'Missing header should return null');
    }

    @IsTest
    static void shouldClassifySuccess() {
        CallwiseResponse response = new CallwiseResponse(raw(204, null, null, null), 1, 0L);

        Assert.isTrue(response.isSuccess(), '204 is a success');
        Assert.isFalse(response.isClientError(), '204 is not a client error');
        Assert.isFalse(response.isServerError(), '204 is not a server error');
    }

    @IsTest
    static void shouldClassifyClientError() {
        CallwiseResponse response = new CallwiseResponse(raw(404, null, null, null), 1, 0L);

        Assert.isFalse(response.isSuccess(), '404 is not a success');
        Assert.isTrue(response.isClientError(), '404 is a client error');
        Assert.isFalse(response.isServerError(), '404 is not a server error');
    }

    @IsTest
    static void shouldClassifyServerError() {
        CallwiseResponse response = new CallwiseResponse(raw(503, null, null, null), 1, 0L);

        Assert.isFalse(response.isSuccess(), '503 is not a success');
        Assert.isFalse(response.isClientError(), '503 is not a client error');
        Assert.isTrue(response.isServerError(), '503 is a server error');
    }

    @IsTest
    static void shouldDeserializeIntoTypeIgnoringUnknownFields() {
        CallwiseResponse response = new CallwiseResponse(raw(200, 'OK', CUSTOMER_JSON, null), 1, 0L);

        Customer parsed = (Customer) response.deserialize(Customer.class);

        Assert.areEqual('cus_123', parsed.id, 'id should be mapped');
        Assert.areEqual('Ada', parsed.name, 'name should be mapped');
    }

    @IsTest
    static void shouldReturnNullWhenDeserializingBlankBody() {
        CallwiseResponse response = new CallwiseResponse(raw(204, null, '', null), 1, 0L);

        Assert.isNull(response.deserialize(Customer.class), 'Blank body should deserialize to null');
        Assert.isNull(response.deserializeUntyped(), 'Blank body should deserialize untyped to null');
    }

    @IsTest
    static void shouldThrowInvalidRequestWhenDeserializeTypeIsNull() {
        CallwiseResponse response = new CallwiseResponse(raw(200, 'OK', CUSTOMER_JSON, null), 1, 0L);

        try {
            response.deserialize(null);
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.INVALID_REQUEST, e.reason, 'Null type is invalid');
        }
    }

    @IsTest
    static void shouldDeserializeUntyped() {
        CallwiseResponse response = new CallwiseResponse(raw(200, 'OK', CUSTOMER_JSON, null), 1, 0L);

        Map<String, Object> parsed = (Map<String, Object>) response.deserializeUntyped();

        Assert.areEqual('cus_123', parsed.get('id'), 'id should be present');
    }

    private static CallwiseResponse withHeaders(Map<String, String> headers) {
        return new CallwiseResponse(raw(200, 'OK', '', headers), 1, 0L);
    }

    private static Long retryAfter(String value) {
        return withHeaders(new Map<String, String>{ 'Retry-After' => value }).getRetryAfterSeconds();
    }

    private static HttpResponse raw(Integer statusCode, String status, String body, Map<String, String> headers) {
        HttpResponse response = new HttpResponse();
        response.setStatusCode(statusCode);
        if (status != null) {
            response.setStatus(status);
        }
        if (body != null) {
            response.setBody(body);
        }
        if (headers != null) {
            for (String name : headers.keySet()) {
                response.setHeader(name, headers.get(name));
            }
        }
        return response;
    }

    /**
     * @description Target type for deserialize().
     */
    public class Customer {
        public String id;
        public String name;
    }
}
