@IsTest
public class CallwiseRequestTest {
    private static final String NAMED_CREDENTIAL = 'Test_API';

    @IsTest
    static void shouldApplyDefaults_WhenCreated() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL);

        Assert.areEqual(NAMED_CREDENTIAL, request.getNamedCredential(), 'Named Credential should be kept');
        Assert.isNull(request.getMethod(), 'No method until one is chosen');
        Assert.areEqual(CallwiseRequest.DEFAULT_TIMEOUT_MS, request.getTimeoutMs(), 'Default timeout');
        Assert.areEqual(3, request.getRetryPolicy().getMaxAttempts(), 'Default policy is transientErrors()');
        Assert.isTrue(request.isCircuitBreakerEnabled(), 'Breaker is on by default');
        Assert.isFalse(request.isThrowOnError(), 'HTTP errors are returned by default');
        Assert.isNull(request.getBody(), 'No body by default');
    }

    @IsTest
    static void shouldRejectNamedCredential_WhenBlank() {
        assertInvalidNamedCredential(' ');
    }

    @IsTest
    static void shouldRejectNamedCredential_WhenNull() {
        assertInvalidNamedCredential(null);
    }

    @IsTest
    static void shouldRejectNamedCredential_WhenCalloutPrefixUsed() {
        assertInvalidNamedCredential('callout:Test_API');
    }

    @IsTest
    static void shouldRejectNamedCredential_WhenRawUrl() {
        assertInvalidNamedCredential('https://api.example.com');
    }

    @IsTest
    static void shouldSetMethodForEachVerb() {
        Map<String, CallwiseRequest> requestsByMethod = new Map<String, CallwiseRequest>{
            'GET' => Callwise.to(NAMED_CREDENTIAL).get('/r'),
            'HEAD' => Callwise.to(NAMED_CREDENTIAL).head('/r'),
            'POST' => Callwise.to(NAMED_CREDENTIAL).post('/r'),
            'PUT' => Callwise.to(NAMED_CREDENTIAL).put('/r'),
            'PATCH' => Callwise.to(NAMED_CREDENTIAL).patch('/r'),
            'DELETE' => Callwise.to(NAMED_CREDENTIAL).del('/r')
        };

        for (String method : requestsByMethod.keySet()) {
            Assert.areEqual(method, requestsByMethod.get(method).getMethod(), 'Method should be ' + method);
        }
    }

    @IsTest
    static void shouldAddLeadingSlash_WhenPathIsRelative() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).get('v1/customers');

        Assert.areEqual('/v1/customers', request.getPath(), 'Leading slash should be added');
        Assert.areEqual('callout:Test_API/v1/customers', request.getEndpoint(), 'Endpoint should be built');
    }

    @IsTest
    static void shouldUseCredentialRoot_WhenPathIsBlank() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).get(null);

        Assert.areEqual('', request.getPath(), 'Blank path stays empty');
        Assert.areEqual('callout:Test_API', request.getEndpoint(), 'Endpoint is the credential root');
    }

    @IsTest
    static void shouldKeepQueryOnlyPath() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).get('?q=1');

        Assert.areEqual('callout:Test_API?q=1', request.getEndpoint(), 'Query-only path should not get a slash');
    }

    @IsTest
    static void shouldRejectPath_WhenAbsoluteUrl() {
        try {
            Callwise.to(NAMED_CREDENTIAL).get('https://evil.example.com/steal');
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.INVALID_REQUEST, e.reason, 'Absolute URLs are invalid');
        }
    }

    @IsTest
    static void shouldEncodeParams_InCallOrder() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL)
            .get('/search')
            .param('q', 'a b&c')
            .param('tag', 'x')
            .param('tag', null);

        Assert.areEqual(
            'callout:Test_API/search?q=a+b%26c&tag=x&tag=',
            request.getEndpoint(),
            'Params should be URL-encoded, ordered and repeatable'
        );
        Assert.areEqual('/search', request.getPath(), 'getPath() excludes params');
    }

    @IsTest
    static void shouldAppendParams_WhenPathHasQuery() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).get('/search?limit=10').param('q', 'x');

        Assert.areEqual('callout:Test_API/search?limit=10&q=x', request.getEndpoint(), 'Params join with &');
    }

    @IsTest
    static void shouldRejectParam_WhenNameIsBlank() {
        try {
            Callwise.to(NAMED_CREDENTIAL).get('/a').param('', 'x');
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.INVALID_REQUEST, e.reason, 'Blank name is invalid');
        }
    }

    @IsTest
    static void shouldReplaceHeader_CaseInsensitively() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL)
            .get('/a')
            .header('X-Trace', 'one')
            .header('x-trace', 'two');

        Map<String, String> headers = request.getHeaders();
        Assert.areEqual(1, headers.size(), 'Header should be replaced, not duplicated');
        Assert.areEqual('two', headers.get('x-trace'), 'Latest value wins with latest name');
    }

    @IsTest
    static void shouldSendEmptyString_WhenHeaderValueIsNull() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).get('/a').header('X-Empty', null);

        Assert.areEqual('', request.getHeaders().get('X-Empty'), 'Null header value becomes empty string');
    }

    @IsTest
    static void shouldRejectHeader_WhenNameIsBlank() {
        try {
            Callwise.to(NAMED_CREDENTIAL).get('/a').header(null, 'x');
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.INVALID_REQUEST, e.reason, 'Blank name is invalid');
        }
    }

    @IsTest
    static void shouldReturnCopyOfHeaders() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).get('/a').header('X-Trace', 'one');

        request.getHeaders().put('X-Trace', 'tampered');

        Assert.areEqual('one', request.getHeaders().get('X-Trace'), 'Internal headers must not be mutable');
    }

    @IsTest
    static void shouldSetRawBody() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).post('/a').body('<xml/>');

        Assert.areEqual('<xml/>', request.getBody(), 'Raw body should be kept');
        Assert.isTrue(request.getHeaders().isEmpty(), 'Raw body sets no Content-Type');
    }

    @IsTest
    static void shouldSerializeJsonAndSetContentType() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).post('/a').jsonBody(new Payload('Ada', null));

        Assert.areEqual('{"name":"Ada"}', request.getBody(), 'Null fields of Apex objects are omitted');
        Assert.areEqual('application/json', request.getHeaders().get('Content-Type'), 'JSON Content-Type is set');
    }

    @IsTest
    static void shouldKeepExistingContentType_WhenJsonBody() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL)
            .post('/a')
            .header('content-type', 'application/vnd.api+json')
            .jsonBody(new Payload('Ada', 'x'));

        Map<String, String> headers = request.getHeaders();
        Assert.areEqual(1, headers.size(), 'No second Content-Type header');
        Assert.areEqual('application/vnd.api+json', headers.get('content-type'), 'Custom Content-Type is kept');
    }

    @IsTest
    static void shouldSetTimeout_WhenInRange() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).timeout(CallwiseRequest.MAX_TIMEOUT_MS);

        Assert.areEqual(CallwiseRequest.MAX_TIMEOUT_MS, request.getTimeoutMs(), 'Upper bound is allowed');
    }

    @IsTest
    static void shouldRejectTimeout_WhenZero() {
        assertInvalidTimeout(0);
    }

    @IsTest
    static void shouldRejectTimeout_WhenAboveMax() {
        assertInvalidTimeout(CallwiseRequest.MAX_TIMEOUT_MS + 1);
    }

    @IsTest
    static void shouldRejectTimeout_WhenNull() {
        assertInvalidTimeout(null);
    }

    @IsTest
    static void shouldSetRetryPolicy() {
        CallwiseRetryPolicy policy = CallwiseRetryPolicy.none();

        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).retry(policy);

        Assert.areEqual(policy, request.getRetryPolicy(), 'Policy should be kept');
    }

    @IsTest
    static void shouldRejectRetryPolicy_WhenNull() {
        try {
            Callwise.to(NAMED_CREDENTIAL).retry(null);
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.INVALID_REQUEST, e.reason, 'Null policy is invalid');
        }
    }

    @IsTest
    static void shouldToggleBreakerAndThrowOnError() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).withoutCircuitBreaker().throwOnError();

        Assert.isFalse(request.isCircuitBreakerEnabled(), 'Breaker should be disabled');
        Assert.isTrue(request.isThrowOnError(), 'throwOnError should be enabled');
    }

    @IsTest
    static void shouldTreatSafeMethodsAsIdempotent() {
        Assert.isTrue(Callwise.to(NAMED_CREDENTIAL).get('/a').isIdempotent(), 'GET');
        Assert.isTrue(Callwise.to(NAMED_CREDENTIAL).head('/a').isIdempotent(), 'HEAD');
        Assert.isTrue(Callwise.to(NAMED_CREDENTIAL).put('/a').isIdempotent(), 'PUT');
        Assert.isTrue(Callwise.to(NAMED_CREDENTIAL).del('/a').isIdempotent(), 'DELETE');
    }

    @IsTest
    static void shouldTreatPostAsNonIdempotent_WithoutKey() {
        Assert.isFalse(Callwise.to(NAMED_CREDENTIAL).post('/a').isIdempotent(), 'POST');
        Assert.isFalse(Callwise.to(NAMED_CREDENTIAL).patch('/a').isIdempotent(), 'PATCH');
    }

    @IsTest
    static void shouldTreatPostAsIdempotent_WithKey() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).post('/a').header('idempotency-key', 'k1');

        Assert.isTrue(request.isIdempotent(), 'POST with Idempotency-Key is idempotent');
    }

    @IsTest
    static void shouldTreatPostAsNonIdempotent_WithBlankKey() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).post('/a').header('Idempotency-Key', ' ');

        Assert.isFalse(request.isIdempotent(), 'Blank Idempotency-Key does not count');
    }

    @IsTest
    static void shouldBuildHttpRequest() {
        HttpRequest built = Callwise.to(NAMED_CREDENTIAL)
            .put('/items/1')
            .param('v', '2')
            .header('X-Trace', 't1')
            .body('{}')
            .timeout(5000)
            .toHttpRequest();

        Assert.areEqual('PUT', built.getMethod(), 'Method should be set');
        Assert.areEqual('callout:Test_API/items/1?v=2', built.getEndpoint(), 'Endpoint should be set');
        Assert.areEqual('t1', built.getHeader('X-Trace'), 'Headers should be set');
        Assert.areEqual('{}', built.getBody(), 'Body should be set');
    }

    @IsTest
    static void shouldNotSetBody_WhenNoBody() {
        HttpRequest built = Callwise.to(NAMED_CREDENTIAL).get('/a').toHttpRequest();

        Assert.isTrue(String.isBlank(built.getBody()), 'GET without body sends no body');
    }

    @IsTest
    static void shouldRejectHttpRequest_WhenNoMethod() {
        try {
            Callwise.to(NAMED_CREDENTIAL).toHttpRequest();
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.INVALID_REQUEST, e.reason, 'Method is required');
        }
    }

    @IsTest
    static void shouldRejectSend_WhenNoMethod() {
        try {
            Callwise.to(NAMED_CREDENTIAL).send();
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.INVALID_REQUEST, e.reason, 'Method is required');
        }
    }

    @IsTest
    static void shouldRejectSendAsync_WhenCallbackTypeIsNull() {
        assertInvalidCallback(null, 'requires a callback type');
    }

    @IsTest
    static void shouldRejectSendAsync_WhenCallbackHasNoDefaultConstructor() {
        assertInvalidCallback(NoDefaultConstructor.class, 'cannot be instantiated');
    }

    @IsTest
    static void shouldRejectSendAsync_WhenTypeIsNotACallback() {
        assertInvalidCallback(NotACallback.class, 'does not implement Callwise.Callback');
    }

    @IsTest
    static void shouldReachEngine_WhenCallbackIsValid() {
        assertInvalidCallback(ValidCallback.class, 'not available');
    }

    @IsTest
    static void shouldReachEngine_WhenSendAsyncWithoutCallback() {
        try {
            Callwise.to(NAMED_CREDENTIAL).get('/a').sendAsync();
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.isTrue(e.getMessage().contains('not available'), 'Async engine is not available yet');
        }
    }

    private static void assertInvalidNamedCredential(String name) {
        try {
            Callwise.to(name);
            Assert.fail('Expected CallwiseException for "' + name + '"');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.INVALID_REQUEST, e.reason, 'Invalid Named Credential');
        }
    }

    private static void assertInvalidTimeout(Integer milliseconds) {
        try {
            Callwise.to(NAMED_CREDENTIAL).timeout(milliseconds);
            Assert.fail('Expected CallwiseException for timeout ' + milliseconds);
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.INVALID_REQUEST, e.reason, 'Out of range is invalid');
        }
    }

    private static void assertInvalidCallback(Type callbackType, String expectedMessage) {
        try {
            Callwise.to(NAMED_CREDENTIAL).get('/a').sendAsync(callbackType);
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.INVALID_REQUEST, e.reason, 'Should be INVALID_REQUEST');
            Assert.isTrue(
                e.getMessage().contains(expectedMessage),
                'Message should contain "' + expectedMessage + '", got: ' + e.getMessage()
            );
        }
    }

    public class Payload {
        public String name;
        public String nickname;

        public Payload(String name, String nickname) {
            this.name = name;
            this.nickname = nickname;
        }
    }

    public class ValidCallback implements Callwise.Callback {
        public void onResponse(CallwiseRequest request, CallwiseResponse response) {
            return;
        }

        public void onFailure(CallwiseRequest request, CallwiseException failure) {
            return;
        }
    }

    public class NotACallback {
    }

    public class NoDefaultConstructor implements Callwise.Callback {
        public NoDefaultConstructor(String required) {
            return;
        }

        public void onResponse(CallwiseRequest request, CallwiseResponse response) {
            return;
        }

        public void onFailure(CallwiseRequest request, CallwiseException failure) {
            return;
        }
    }
}
