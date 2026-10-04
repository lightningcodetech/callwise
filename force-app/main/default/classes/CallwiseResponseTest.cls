@IsTest
private class CallwiseResponseTest {
    private static final String CUSTOMER_JSON = '{"id":"cus_123","name":"Ada","unknown":true}';

    @IsTest
    static void shouldCopyStatusBodyAndMetrics_WhenBuilt() {
        CallwiseResponse response = new CallwiseResponse(raw(201, 'Created', CUSTOMER_JSON, null), 2, 150L);

        Assert.areEqual(201, response.getStatusCode(), 'Status code should be copied');
        Assert.areEqual('Created', response.getStatus(), 'Status text should be copied');
        Assert.areEqual(CUSTOMER_JSON, response.getBody(), 'Body should be copied');
        Assert.areEqual(2, response.getAttempts(), 'Attempts should be kept');
        Assert.areEqual(150L, response.getElapsedMs(), 'Elapsed time should be kept');
    }

    @IsTest
    static void shouldDefaultMetrics_WhenNull() {
        CallwiseResponse response = new CallwiseResponse(raw(200, 'OK', '', null), null, null);

        Assert.areEqual(1, response.getAttempts(), 'Null attempts should default to 1');
        Assert.areEqual(0L, response.getElapsedMs(), 'Null elapsed should default to 0');
    }

    @IsTest
    static void shouldThrowInvalidRequest_WhenHttpResponseIsNull() {
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
    static void shouldReturnNull_WhenHeaderNameIsBlankOrMissing() {
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
    static void shouldParseRetryAfter_WhenNumeric() {
        CallwiseResponse response = withHeaders(new Map<String, String>{ 'Retry-After' => ' 120 ' });

        Assert.areEqual(120L, response.getRetryAfterSeconds(), 'Numeric Retry-After should be parsed');
    }

    @IsTest
    static void shouldIgnoreRetryAfter_WhenHttpDate() {
        CallwiseResponse response = withHeaders(
            new Map<String, String>{ 'Retry-After' => 'Wed, 21 Oct 2026 07:28:00 GMT' }
        );

        Assert.isNull(response.getRetryAfterSeconds(), 'HTTP-date form is not supported');
    }

    @IsTest
    static void shouldIgnoreRetryAfter_WhenTooLong() {
        CallwiseResponse response = withHeaders(new Map<String, String>{ 'Retry-After' => '1234567890123456789' });

        Assert.isNull(response.getRetryAfterSeconds(), 'Values longer than 18 digits are ignored');
    }

    @IsTest
    static void shouldReturnNullRetryAfter_WhenAbsent() {
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
    static void shouldDeserializeIntoType_IgnoringUnknownFields() {
        CallwiseResponse response = new CallwiseResponse(raw(200, 'OK', CUSTOMER_JSON, null), 1, 0L);

        Customer parsed = (Customer) response.deserialize(Customer.class);

        Assert.areEqual('cus_123', parsed.id, 'id should be mapped');
        Assert.areEqual('Ada', parsed.name, 'name should be mapped');
    }

    @IsTest
    static void shouldReturnNull_WhenDeserializingBlankBody() {
        CallwiseResponse response = new CallwiseResponse(raw(204, null, '', null), 1, 0L);

        Assert.isNull(response.deserialize(Customer.class), 'Blank body should deserialize to null');
        Assert.isNull(response.deserializeUntyped(), 'Blank body should deserialize untyped to null');
    }

    @IsTest
    static void shouldThrowInvalidRequest_WhenDeserializeTypeIsNull() {
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

    public class Customer {
        public String id;
        public String name;
    }
}
