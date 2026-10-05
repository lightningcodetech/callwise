/**
 * @description Entry point for resilient REST callouts over Named Credentials.
 *
 * @example
 * CallwiseResponse res = Callwise.to('Stripe_API')
 *     .post('/v1/customers')
 *     .header('Idempotency-Key', key)
 *     .jsonBody(payload)
 *     .retry(CallwiseRetryPolicy.transientErrors().maxAttempts(3))
 *     .send();
 */
public inherited sharing class Callwise {
    /** @description Platform Cache partition used by the circuit breaker unless setCachePartition() is called. */
    public static final String DEFAULT_CACHE_PARTITION = 'local.Callwise';

    /** @description Qualified Platform Cache partition name: namespace.partition, e.g. local.Callwise. */
    private static final Pattern CACHE_PARTITION_NAME = Pattern.compile('^[A-Za-z0-9_]+\\.[A-Za-z][A-Za-z0-9_]*$');

    /** @description Logger for the rest of the transaction; set with setLogger(). */
    private static Logger activeLogger = new NoOpLogger();
    /** @description Platform Cache partition for the rest of the transaction; set with setCachePartition(). */
    private static String cachePartition = DEFAULT_CACHE_PARTITION;

    /**
     * @description Receives one call per attempt. Implementations must not throw and should not log bodies unless the
     * subscriber org has decided that is acceptable (bodies often carry PII).
     */
    public interface Logger {
        /**
         * @description Records one attempt.
         *
         * @param request `CallwiseRequest` Request being sent
         * @param response `CallwiseResponse` Response of this attempt, or null when it failed with an exception
         * @param failure `CallwiseException` Exception raised by this attempt, or null when a response was received
         * @param attempt `Integer` Attempt number, starting at 1
         */
        void log(CallwiseRequest request, CallwiseResponse response, CallwiseException failure, Integer attempt);
    }

    /**
     * @description Receives the outcome of sendAsync(). Implementations need a public no-argument constructor. They
     * run in the
     * Queueable's transaction, so they may perform DML.
     */
    public interface Callback {
        /**
         * @description Called with the final response, whatever its status, unless the request used throwOnError() and
         * the
         * status was not 2xx (then onFailure() is called with reason HTTP_ERROR).
         *
         * @param request `CallwiseRequest` Request that was sent
         * @param response `CallwiseResponse` Final response
         */
        void onResponse(CallwiseRequest request, CallwiseResponse response);

        /**
         * @description Called when the request failed after all permitted attempts.
         *
         * @param request `CallwiseRequest` Request that was sent
         * @param failure `CallwiseException` Final failure
         */
        void onFailure(CallwiseRequest request, CallwiseException failure);
    }

    /**
     * @description Not instantiable: Callwise only exposes static methods.
     */
    private Callwise() {
        // Static entry point only.
    }

    /**
     * @description Starts a request against a Named Credential.
     *
     * @param namedCredential `String` API name of the Named Credential, without the 'callout:' prefix
     * @return `CallwiseRequest` New request builder
     * @throws `CallwiseException` INVALID_REQUEST when the name is blank or invalid
     */
    public static CallwiseRequest to(String namedCredential) {
        return new CallwiseRequest(namedCredential);
    }

    /**
     * @description Sets the logger for the rest of the transaction. Static state does not travel to async jobs.
     *
     * @param logger `Logger` Logger to use; null restores the NoOpLogger
     */
    public static void setLogger(Logger logger) {
        activeLogger = logger ?? new NoOpLogger();
    }

    /**
     * @description Returns the logger in effect for this transaction.
     *
     * @return `Logger` Logger set with setLogger(), or the NoOpLogger
     */
    public static Logger getLogger() {
        return activeLogger;
    }

    /**
     * @description Sets the org Platform Cache partition used to store circuit breaker state.
     *
     * @param partitionName `String` Qualified partition name, e.g. 'local.Callwise'
     * @throws `CallwiseException` INVALID_REQUEST when the name is not of the form namespace.partition
     */
    public static void setCachePartition(String partitionName) {
        if (String.isBlank(partitionName) || !CACHE_PARTITION_NAME.matcher(partitionName).matches()) {
            throw CallwiseException.create(
                CallwiseException.FailureReason.INVALID_REQUEST,
                'Expected a qualified cache partition name such as local.Callwise, got "' + partitionName + '".'
            );
        }
        cachePartition = partitionName;
    }

    /**
     * @description Returns the Platform Cache partition used to store circuit breaker state.
     *
     * @return `String` Partition set with setCachePartition(), or DEFAULT_CACHE_PARTITION
     */
    public static String getCachePartition() {
        return cachePartition;
    }

    /**
     * @description Default logger: does nothing.
     */
    public class NoOpLogger implements Logger {
        /**
         * @description Ignores the attempt.
         *
         * @param request `CallwiseRequest` Ignored
         * @param response `CallwiseResponse` Ignored
         * @param failure `CallwiseException` Ignored
         * @param attempt `Integer` Ignored
         */
        public void log(
            CallwiseRequest request,
            CallwiseResponse response,
            CallwiseException failure,
            Integer attempt
        ) {
            return;
        }
    }

    /**
     * @description Writes one System.debug line per attempt: method, endpoint, attempt, status or failure, elapsed
     * time.
     * Bodies are excluded unless includeBodies() is called.
     *
     * @example
     * Callwise.setLogger(new Callwise.DebugLogger(LoggingLevel.INFO).includeBodies());
     */
    public class DebugLogger implements Logger {
        /** @description Logging level of every line. */
        private final LoggingLevel level;
        /** @description True when includeBodies() was called. */
        private Boolean bodiesIncluded = false;

        /**
         * @description Logs at LoggingLevel.DEBUG.
         */
        public DebugLogger() {
            this(LoggingLevel.DEBUG);
        }

        /**
         * @description Logs at the given level.
         *
         * @param level `LoggingLevel` Logging level for every line; null means DEBUG
         */
        public DebugLogger(LoggingLevel level) {
            this.level = level ?? LoggingLevel.DEBUG;
        }

        /**
         * @description Also logs request and response bodies. Bodies often contain PII: do not enable in production
         * orgs
         * unless that is acceptable.
         *
         * @return `DebugLogger` This logger
         */
        public DebugLogger includeBodies() {
            bodiesIncluded = true;
            return this;
        }

        /**
         * @description Writes the attempt to the debug log.
         *
         * @param request `CallwiseRequest` Request being sent
         * @param response `CallwiseResponse` Response of this attempt, or null
         * @param failure `CallwiseException` Exception raised by this attempt, or null
         * @param attempt `Integer` Attempt number, starting at 1
         */
        @SuppressWarnings('PMD.AvoidDebugStatements')
        public void log(
            CallwiseRequest request,
            CallwiseResponse response,
            CallwiseException failure,
            Integer attempt
        ) {
            System.debug(level, format(request, response, failure, attempt));
        }

        /**
         * @description Builds the log line. Exposed so it can be asserted in tests.
         *
         * @param request `CallwiseRequest` Request being sent
         * @param response `CallwiseResponse` Response of this attempt, or null
         * @param failure `CallwiseException` Exception raised by this attempt, or null
         * @param attempt `Integer` Attempt number, starting at 1
         * @return `String` Single log line
         */
        public String format(
            CallwiseRequest request,
            CallwiseResponse response,
            CallwiseException failure,
            Integer attempt
        ) {
            List<String> parts = new List<String>{
                '[Callwise]',
                request?.getMethod(),
                request?.getEndpoint(),
                'attempt=' + attempt
            };
            if (response != null) {
                parts.add('status=' + response.getStatusCode());
                parts.add('elapsedMs=' + response.getElapsedMs());
            }
            if (failure != null) {
                parts.add('failure=' + failure.reason);
                parts.add('message=' + failure.getMessage());
            }
            if (bodiesIncluded) {
                parts.add('requestBody=' + request?.getBody());
                parts.add('responseBody=' + response?.getBody());
            }
            return String.join(parts, ' ');
        }
    }
}
