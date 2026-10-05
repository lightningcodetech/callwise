/**
 * @description Tests for the CallwiseRequest builder: validation of the Named Credential, path, headers, parameters,
 * body, timeout and callbacks, idempotency and the platform HttpRequest it builds.
 *
 * Not parallel: a test calls sendAsync(), which runs System.enqueueJob(), and parallel tests cannot enqueue jobs.
 */
@IsTest(IsParallel=false)
public class CallwiseRequestTest {
    private static final String NAMED_CREDENTIAL = 'Test_API';

    @IsTest
    static void shouldApplyDefaultsWhenCreated() {
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
    static void shouldRejectNamedCredentialWhenBlank() {
        assertInvalidNamedCredential(' ');
    }

    @IsTest
    static void shouldRejectNamedCredentialWhenNull() {
        assertInvalidNamedCredential(null);
    }

    @IsTest
    static void shouldRejectNamedCredentialWhenCalloutPrefixUsed() {
        assertInvalidNamedCredential('callout:Test_API');
    }

    @IsTest
    static void shouldRejectNamedCredentialWhenRawUrl() {
        assertInvalidNamedCredential('https://api.example.com');
    }

    @IsTest
    static void shouldExplainInvalidNamedCredential() {
        try {
            Callwise.to('https://api.example.com');
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(
                'Expected the API name of a Named Credential (e.g. Stripe_API), got "https://api.example.com". ' +
                'Raw URLs are not supported.',
                e.getMessage(),
                'Exact message'
            );
        }
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
    static void shouldAddLeadingSlashWhenPathIsRelative() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).get('v1/customers');

        Assert.areEqual('/v1/customers', request.getPath(), 'Leading slash should be added');
        Assert.areEqual('callout:Test_API/v1/customers', request.getEndpoint(), 'Endpoint should be built');
    }

    @IsTest
    static void shouldUseCredentialRootWhenPathIsBlank() {
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
    static void shouldRejectPathWhenAbsoluteUrl() {
        try {
            Callwise.to(NAMED_CREDENTIAL).get('https://evil.example.com/steal');
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.INVALID_REQUEST, e.reason, 'Absolute URLs are invalid');
        }
    }

    @IsTest
    static void shouldEncodeParamsInCallOrder() {
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
    static void shouldAppendParamsWhenPathHasQuery() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).get('/search?limit=10').param('q', 'x');

        Assert.areEqual('callout:Test_API/search?limit=10&q=x', request.getEndpoint(), 'Params join with &');
    }

    @IsTest
    static void shouldRejectParamWhenNameIsBlank() {
        try {
            Callwise.to(NAMED_CREDENTIAL).get('/a').param('', 'x');
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.INVALID_REQUEST, e.reason, 'Blank name is invalid');
        }
    }

    @IsTest
    static void shouldReplaceHeaderCaseInsensitively() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL)
            .get('/a')
            .header('X-Trace', 'one')
            .header('x-trace', 'two');

        Map<String, String> headers = request.getHeaders();
        Assert.areEqual(1, headers.size(), 'Header should be replaced, not duplicated');
        Assert.areEqual('two', headers.get('x-trace'), 'Latest value wins with latest name');
    }

    @IsTest
    static void shouldSendEmptyStringWhenHeaderValueIsNull() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).get('/a').header('X-Empty', null);

        Assert.areEqual('', request.getHeaders().get('X-Empty'), 'Null header value becomes empty string');
    }

    @IsTest
    static void shouldRejectHeaderWhenNameIsBlank() {
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
    static void shouldKeepExistingContentTypeWhenJsonBody() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL)
            .post('/a')
            .header('content-type', 'application/vnd.api+json')
            .jsonBody(new Payload('Ada', 'x'));

        Map<String, String> headers = request.getHeaders();
        Assert.areEqual(1, headers.size(), 'No second Content-Type header');
        Assert.areEqual('application/vnd.api+json', headers.get('content-type'), 'Custom Content-Type is kept');
    }

    @IsTest
    static void shouldSetTimeoutWhenInRange() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).timeout(CallwiseRequest.MAX_TIMEOUT_MS);

        Assert.areEqual(CallwiseRequest.MAX_TIMEOUT_MS, request.getTimeoutMs(), 'Upper bound is allowed');
    }

    @IsTest
    static void shouldRejectTimeoutWhenZero() {
        assertInvalidTimeout(0);
    }

    @IsTest
    static void shouldRejectTimeoutWhenAboveMax() {
        assertInvalidTimeout(CallwiseRequest.MAX_TIMEOUT_MS + 1);
    }

    @IsTest
    static void shouldRejectTimeoutWhenNull() {
        assertInvalidTimeout(null);
    }

    @IsTest
    static void shouldSetRetryPolicy() {
        CallwiseRetryPolicy policy = CallwiseRetryPolicy.none();

        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).retry(policy);

        Assert.areEqual(policy, request.getRetryPolicy(), 'Policy should be kept');
    }

    @IsTest
    static void shouldRejectRetryPolicyWhenNull() {
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
    static void shouldTreatPostAsNonIdempotentWithoutKey() {
        Assert.isFalse(Callwise.to(NAMED_CREDENTIAL).post('/a').isIdempotent(), 'POST');
        Assert.isFalse(Callwise.to(NAMED_CREDENTIAL).patch('/a').isIdempotent(), 'PATCH');
    }

    @IsTest
    static void shouldTreatPostAsIdempotentWithKey() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).post('/a').header('idempotency-key', 'k1');

        Assert.isTrue(request.isIdempotent(), 'POST with Idempotency-Key is idempotent');
    }

    @IsTest
    static void shouldTreatPostAsNonIdempotentWithBlankKey() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).post('/a').header('Idempotency-Key', ' ');

        Assert.isFalse(request.isIdempotent(), 'Blank Idempotency-Key does not count');
    }

    @IsTest
    static void shouldGenerateIdempotencyKeyWhenIdempotentIsCalled() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).post('/a').idempotent();

        String key = request.getIdempotencyKey();
        Assert.isTrue(
            Pattern.matches('[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}', key),
            'Key should be a UUID v4, got ' + key
        );
        Assert.isTrue(request.isIdempotent(), 'POST with a generated key is idempotent');
        Assert.areEqual(key, request.toHttpRequest().getHeader('Idempotency-Key'), 'Key should be sent');
    }

    @IsTest
    static void shouldKeepGeneratedKeyWhenIdempotentIsCalledTwice() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).post('/a').idempotent();
        String firstKey = request.getIdempotencyKey();

        request.idempotent();

        Assert.areEqual(firstKey, request.getIdempotencyKey(), 'Key is generated once');
    }

    @IsTest
    static void shouldGenerateDifferentKeysForDifferentRequests() {
        String first = Callwise.to(NAMED_CREDENTIAL).post('/a').idempotent().getIdempotencyKey();
        String second = Callwise.to(NAMED_CREDENTIAL).post('/a').idempotent().getIdempotencyKey();

        Assert.areNotEqual(first, second, 'Each request gets its own key');
    }

    @IsTest
    static void shouldKeepCallerKeyWhenIdempotentIsCalled() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL)
            .post('/a')
            .header('idempotency-key', 'order-42')
            .idempotent();

        Assert.areEqual('order-42', request.getIdempotencyKey(), 'Caller key takes precedence');
        Assert.areEqual(1, request.getHeaders().size(), 'No duplicate header');
    }

    @IsTest
    static void shouldReplaceBlankCallerKeyWhenIdempotentIsCalled() {
        CallwiseRequest request = Callwise.to(NAMED_CREDENTIAL).post('/a').header('Idempotency-Key', ' ').idempotent();

        Assert.isNotNull(request.getIdempotencyKey(), 'Blank key is replaced by a generated one');
        Assert.areEqual(1, request.getHeaders().size(), 'No duplicate header');
    }

    @IsTest
    static void shouldReturnNullIdempotencyKeyWhenAbsent() {
        Assert.isNull(Callwise.to(NAMED_CREDENTIAL).post('/a').getIdempotencyKey(), 'No key by default');
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
    static void shouldNotSetBodyWhenNoBody() {
        HttpRequest built = Callwise.to(NAMED_CREDENTIAL).get('/a').toHttpRequest();

        Assert.isTrue(String.isBlank(built.getBody()), 'GET without body sends no body');
    }

    @IsTest
    static void shouldRejectHttpRequestWhenNoMethod() {
        try {
            Callwise.to(NAMED_CREDENTIAL).toHttpRequest();
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.INVALID_REQUEST, e.reason, 'Method is required');
        }
    }

    @IsTest
    static void shouldRejectSendWhenNoMethod() {
        try {
            Callwise.to(NAMED_CREDENTIAL).send();
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.INVALID_REQUEST, e.reason, 'Method is required');
        }
    }

    @IsTest
    static void shouldRejectSendAsyncWhenCallbackTypeIsNull() {
        assertInvalidCallback(null, 'requires a callback type');
    }

    @IsTest
    static void shouldRejectSendAsyncWhenCallbackHasNoDefaultConstructor() {
        assertInvalidCallback(NoDefaultConstructor.class, 'cannot be instantiated');
    }

    @IsTest
    static void shouldRejectSendAsyncWhenTypeIsNotACallback() {
        assertInvalidCallback(NotACallback.class, 'does not implement Callwise.Callback');
    }

    @IsTest
    static void shouldEnqueueJobWhenCallbackIsValid() {
        new CallwiseMock().whenRequest('GET', '/a').thenRespond(200, '').install();

        Test.startTest();
        Id jobId = Callwise.to(NAMED_CREDENTIAL).get('/a').sendAsync(ValidCallback.class);
        Test.stopTest();

        Assert.isNotNull(jobId, 'A valid callback reaches the engine and a job is enqueued');
    }

    @IsTest
    static void shouldRejectSendAsyncWhenMethodIsMissing() {
        try {
            Callwise.to(NAMED_CREDENTIAL).sendAsync();
            Assert.fail('Expected CallwiseException');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.INVALID_REQUEST, e.reason, 'Method is required');
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

    /**
     * @description JSON payload with an optional field, to check that null fields are omitted.
     */
    public class Payload {
        public String name;
        public String nickname;

        public Payload(String name, String nickname) {
            this.name = name;
            this.nickname = nickname;
        }
    }

    /**
     * @description Callback that does nothing; a valid callback type.
     */
    public class ValidCallback implements Callwise.Callback {
        public void onResponse(CallwiseRequest request, CallwiseResponse response) {
            return;
        }

        public void onFailure(CallwiseRequest request, CallwiseException failure) {
            return;
        }
    }

    /**
     * @description Class that does not implement Callwise.Callback.
     */
    public class NotACallback {
    }

    /**
     * @description Callback without a no-argument constructor, so it cannot be instantiated by type.
     */
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
