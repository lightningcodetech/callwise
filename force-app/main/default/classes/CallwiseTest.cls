@IsTest
private class CallwiseTest {
    @IsTest
    static void shouldStartRequest_WhenTo() {
        CallwiseRequest request = Callwise.to('Test_API');

        Assert.areEqual('Test_API', request.getNamedCredential(), 'to() should start a request');
    }

    @IsTest
    static void shouldUseNoOpLogger_ByDefault() {
        Assert.isInstanceOfType(Callwise.getLogger(), Callwise.NoOpLogger.class, 'Default logger is NoOpLogger');
    }

    @IsTest
    static void shouldSetLogger() {
        Callwise.DebugLogger logger = new Callwise.DebugLogger();

        Callwise.setLogger(logger);

        Assert.areEqual(logger, Callwise.getLogger(), 'Logger should be replaced');
    }

    @IsTest
    static void shouldRestoreNoOpLogger_WhenSetToNull() {
        Callwise.setLogger(new Callwise.DebugLogger());

        Callwise.setLogger(null);

        Assert.isInstanceOfType(Callwise.getLogger(), Callwise.NoOpLogger.class, 'Null restores NoOpLogger');
    }

    @IsTest
    static void shouldUseDefaultCachePartition() {
        Assert.areEqual(Callwise.DEFAULT_CACHE_PARTITION, Callwise.getCachePartition(), 'Default partition');
    }

    @IsTest
    static void shouldSetCachePartition_WhenQualified() {
        Callwise.setCachePartition('local.Integrations');

        Assert.areEqual('local.Integrations', Callwise.getCachePartition(), 'Partition should be replaced');
    }

    @IsTest
    static void shouldRejectCachePartition_WhenUnqualified() {
        assertInvalidPartition('Integrations');
    }

    @IsTest
    static void shouldRejectCachePartition_WhenBlank() {
        assertInvalidPartition('');
    }

    @IsTest
    static void shouldIgnoreAttempt_WhenNoOpLogger() {
        Callwise.NoOpLogger logger = new Callwise.NoOpLogger();

        logger.log(Callwise.to('Test_API').get('/a'), null, null, 1);

        Assert.isNotNull(logger, 'NoOpLogger.log() should not throw');
    }

    @IsTest
    static void shouldFormatResponse_WithoutBodies() {
        Callwise.DebugLogger logger = new Callwise.DebugLogger(LoggingLevel.INFO);

        String line = logger.format(request(), response(), null, 2);

        Assert.areEqual(
            '[Callwise] POST callout:Test_API/orders attempt=2 status=201 elapsedMs=40',
            line,
            'Line should contain method, endpoint, attempt, status and timing only'
        );
    }

    @IsTest
    static void shouldFormatFailure() {
        CallwiseException failure = CallwiseException.create(CallwiseException.FailureReason.TIMEOUT, 'Read timed out');

        String line = new Callwise.DebugLogger().format(request(), null, failure, 1);

        Assert.areEqual(
            '[Callwise] POST callout:Test_API/orders attempt=1 failure=TIMEOUT message=Read timed out',
            line,
            'Line should contain the failure reason and message'
        );
    }

    @IsTest
    static void shouldIncludeBodies_WhenRequested() {
        Callwise.DebugLogger logger = new Callwise.DebugLogger(null).includeBodies();

        String line = logger.format(request(), response(), null, 1);

        Assert.isTrue(line.endsWith('requestBody={"sku":"A1"} responseBody={"id":"o1"}'), 'Bodies should be logged');
    }

    @IsTest
    static void shouldWriteDebugLine_WhenLogging() {
        Callwise.DebugLogger logger = new Callwise.DebugLogger();

        logger.log(request(), response(), null, 1);

        Assert.isNotNull(logger, 'DebugLogger.log() should not throw');
    }

    private static void assertInvalidPartition(String partitionName) {
        try {
            Callwise.setCachePartition(partitionName);
            Assert.fail('Expected CallwiseException for "' + partitionName + '"');
        } catch (CallwiseException e) {
            Assert.areEqual(CallwiseException.FailureReason.INVALID_REQUEST, e.reason, 'Invalid partition name');
            Assert.areEqual(Callwise.DEFAULT_CACHE_PARTITION, Callwise.getCachePartition(), 'Partition unchanged');
        }
    }

    private static CallwiseRequest request() {
        return Callwise.to('Test_API').post('/orders').body('{"sku":"A1"}');
    }

    private static CallwiseResponse response() {
        HttpResponse raw = new HttpResponse();
        raw.setStatusCode(201);
        raw.setBody('{"id":"o1"}');
        return new CallwiseResponse(raw, 1, 40L);
    }
}
