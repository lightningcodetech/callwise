/**
 * @description Internal: circuit breaker per Named Credential. Not part of the public API; the engine uses it for every
 * request unless the request calls withoutCircuitBreaker().
 *
 * CLOSED → OPEN after a number of consecutive failures. OPEN rejects requests for a while, then HALF_OPEN lets one
 * trial request through: success closes the circuit, failure opens it again.
 *
 * Both values come from the CallwiseBreaker__mdt record named after the Named Credential. Without a record, or for a
 * blank or out-of-range field, the defaults apply: FAILURE_THRESHOLD failures and OPEN_DURATION_MS.
 *
 * State lives in the org Platform Cache partition returned by Callwise.getCachePartition(). When the partition is
 * missing or unusable, state falls back to a store that only lives for the current transaction, and a warning is
 * written to the debug log once per transaction. A cache problem never opens the circuit.
 *
 * Best effort: Platform Cache has no atomic compare-and-set, so concurrent transactions can race on the counter.
 */
public inherited sharing class CallwiseCircuitBreaker {
    /** @description Default consecutive failures that open the circuit. */
    public static final Integer FAILURE_THRESHOLD = 5;
    /** @description Default time the circuit stays open before a trial request is allowed, in milliseconds. */
    public static final Integer OPEN_DURATION_MS = 60000;
    /** @description Largest FailureThreshold__c accepted. */
    public static final Integer MAX_FAILURE_THRESHOLD = 100;
    /** @description Largest OpenSeconds__c accepted; well below the cache TTL, so open state never expires early. */
    public static final Integer MAX_OPEN_SECONDS = 3600;

    /** @description Cache entries outlive any open period; expiry only resets an idle breaker to CLOSED. */
    private static final Integer CACHE_TTL_SECONDS = 86400;
    /** @description Prefix of every cache key written by the breaker. */
    private static final String KEY_PREFIX = 'cwcb';
    /** @description Statuses below 500 that also mean the endpoint is struggling: 408 and 429. */
    private static final Set<Integer> FAILURE_STATUS_CODES = new Set<Integer>{ 408, 429 };

    /** @description Replaces the clock in tests. */
    @TestVisible
    private static Long nowOverride;

    /** @description Replaces the store in tests. */
    @TestVisible
    private static Store storeOverride;

    /** @description Replaces CallwiseBreaker__mdt records in tests, keyed by Named Credential. */
    @TestVisible
    private static Map<String, CallwiseBreaker__mdt> settingsOverride;

    /**
     * @description Lets tests exercise the Platform Cache path; by default tests use the transaction store for
     * isolation.
     */
    @TestVisible
    private static Boolean usePlatformCacheInTests = false;

    /** @description Store shared by every breaker of the transaction; also the fallback when the cache is unusable. */
    private static final TransactionStore TRANSACTION_STORE = new TransactionStore();
    /** @description Platform Cache store resolved for resolvedPartition, reused for the rest of the transaction. */
    private static Store resolvedStore;
    /** @description Partition name resolvedStore was created for. */
    private static String resolvedPartition;
    /** @description True once the cache warning has been written in this transaction. */
    @TestVisible
    private static Boolean warned = false;

    /** @description API name of the Named Credential this breaker protects. */
    private final String namedCredential;
    /** @description Alphanumeric cache key derived from the Named Credential name. */
    private final String key;
    /** @description Consecutive failures that open this circuit. */
    private final Integer failureThreshold;
    /** @description Time this circuit stays open before a trial request, in milliseconds. */
    private final Long openDurationMs;

    /**
     * @description Breaker state values: CLOSED lets requests through, OPEN rejects them, HALF_OPEN lets one trial
     * through.
     */
    public enum CircuitStatus {
        CLOSED,
        OPEN,
        HALF_OPEN
    }

    /**
     * @description Serializable breaker state, as stored in the cache.
     */
    public class State {
        /** @description Current status. */
        public CircuitStatus status = CircuitStatus.CLOSED;
        /** @description Failures recorded since the last success. */
        public Integer consecutiveFailures = 0;
        /** @description When the circuit opened, in epoch milliseconds; null unless OPEN. */
        public Long openedAt;
        /** @description When the current trial started, in epoch milliseconds; null unless HALF_OPEN. */
        public Long trialStartedAt;
    }

    /**
     * @description Where breaker state is kept.
     */
    public interface Store {
        /**
         * @description Reads the state of a breaker.
         *
         * @param key `String` Alphanumeric key
         * @return `State` Stored state, or null when absent or expired
         */
        State get(String key);

        /**
         * @description Writes the state of a breaker.
         *
         * @param key `String` Alphanumeric key
         * @param state `State` State to store
         */
        void put(String key, State state);
    }

    /**
     * @description Creates the breaker of a Named Credential and reads its CallwiseBreaker__mdt settings.
     *
     * @param namedCredential `String` API name of the Named Credential the breaker protects
     */
    public CallwiseCircuitBreaker(String namedCredential) {
        this.namedCredential = namedCredential;
        // Cache keys must be alphanumeric; Named Credential names may contain underscores.
        this.key = KEY_PREFIX + EncodingUtil.convertToHex(Crypto.generateDigest('MD5', Blob.valueOf(namedCredential)));
        CallwiseBreaker__mdt settings = settingsFor(namedCredential);
        this.failureThreshold = inRange(settings?.FailureThreshold__c, MAX_FAILURE_THRESHOLD) ?? FAILURE_THRESHOLD;
        Integer openSeconds = inRange(settings?.OpenSeconds__c, MAX_OPEN_SECONDS);
        this.openDurationMs = openSeconds == null ? OPEN_DURATION_MS : openSeconds * 1000L;
    }

    /**
     * @description Returns the breaker of a request's Named Credential, unless the request opts out.
     *
     * @param request `CallwiseRequest` Request about to be sent
     * @return `CallwiseCircuitBreaker` Breaker of the Named Credential, or null when withoutCircuitBreaker() was called
     */
    public static CallwiseCircuitBreaker forRequest(CallwiseRequest request) {
        return request.isCircuitBreakerEnabled() ? new CallwiseCircuitBreaker(request.getNamedCredential()) : null;
    }

    /**
     * @description Returns the consecutive failures that open this circuit.
     *
     * @return `Integer` FailureThreshold__c of the settings record, or FAILURE_THRESHOLD
     */
    public Integer getFailureThreshold() {
        return failureThreshold;
    }

    /**
     * @description Returns the time this circuit stays open before a trial request.
     *
     * @return `Long` OpenSeconds__c of the settings record in milliseconds, or OPEN_DURATION_MS
     */
    public Long getOpenDurationMs() {
        return openDurationMs;
    }

    /**
     * @description Decides whether a request may be sent now. Moves an expired OPEN circuit to HALF_OPEN and claims the
     * trial.
     *
     * @return `Boolean` True when the request may be sent
     */
    public Boolean allowRequest() {
        State state = load();
        Long now = now();
        if (state.status == CircuitStatus.CLOSED) {
            return true;
        }
        // OPEN waits from the moment it opened; HALF_OPEN waits from the trial, so a trial that never reported back
        // (its transaction failed) is replaced after the same wait.
        Long since = state.status == CircuitStatus.OPEN ? state.openedAt : state.trialStartedAt;
        if (now - since < openDurationMs) {
            return false;
        }
        state.status = CircuitStatus.HALF_OPEN;
        state.trialStartedAt = now;
        save(state);
        return true;
    }

    /**
     * @description Records the outcome of an attempt. Only endpoint health counts: transport failures, timeouts and
     * 5xx, 408 and 429 responses are failures; any other response is a success. Other failures (uncommitted work,
     * limits) are not recorded.
     *
     * @param response `CallwiseResponse` Response of the attempt, or null
     * @param failure `CallwiseException` Exception raised by the attempt, or null
     */
    public void record(CallwiseResponse response, CallwiseException failure) {
        if (failure != null) {
            if (failure.isTransportFailure()) {
                recordFailure();
            }
            return;
        }
        if (response == null) {
            return;
        }
        Integer statusCode = response.getStatusCode();
        if (statusCode >= 500 || FAILURE_STATUS_CODES.contains(statusCode)) {
            recordFailure();
        } else {
            recordSuccess();
        }
    }

    /**
     * @description Returns the current status of the circuit, for diagnostics and tests.
     *
     * @return `CircuitStatus` CLOSED, OPEN or HALF_OPEN
     */
    public CircuitStatus getStatus() {
        return load().status;
    }

    /**
     * @description Returns how long an open circuit still rejects requests.
     *
     * @return `Long` Seconds until a trial request is let through, rounded up; 0 when the circuit is not open
     */
    public Long secondsUntilTrial() {
        State state = load();
        if (state.status != CircuitStatus.OPEN) {
            return 0;
        }
        Long remainingMs = Math.max(0, openDurationMs - (now() - state.openedAt));
        return Math.ceil((Double) remainingMs / 1000).longValue();
    }

    /**
     * @description Builds the exception thrown when the circuit rejects a request.
     *
     * @return `CallwiseException` CIRCUIT_OPEN failure naming the Named Credential and the wait until the next trial
     */
    public CallwiseException openCircuitException() {
        return CallwiseException.create(
            CallwiseException.FailureReason.CIRCUIT_OPEN,
            String.format(
                'Circuit open for {0} after repeated failures; no callout was made. Next trial in about {1} s.',
                new List<Object>{ namedCredential, String.valueOf(secondsUntilTrial()) }
            )
        );
    }

    /**
     * @description Closes the circuit and resets the failure count. Skips the write when nothing changes.
     */
    private void recordSuccess() {
        State state = load();
        if (state.status == CircuitStatus.CLOSED && state.consecutiveFailures == 0) {
            return;
        }
        save(new State());
    }

    /**
     * @description Counts a failure and opens the circuit when the threshold is reached or the trial failed.
     */
    private void recordFailure() {
        State state = load();
        state.consecutiveFailures++;
        if (state.status == CircuitStatus.HALF_OPEN || state.consecutiveFailures >= failureThreshold) {
            state.status = CircuitStatus.OPEN;
            state.openedAt = now();
            state.trialStartedAt = null;
        }
        save(state);
    }

    /**
     * @description Reads the state of this breaker.
     *
     * @return `State` Stored state, or a new CLOSED state when none is stored
     */
    private State load() {
        return store().get(key) ?? new State();
    }

    /**
     * @description Writes the state of this breaker.
     *
     * @param state `State` State to store
     */
    private void save(State state) {
        store().put(key, state);
    }

    /**
     * @description Reads the settings record of a Named Credential. getInstance() does not count against SOQL limits.
     *
     * @param namedCredential `String` API name of the Named Credential
     * @return `CallwiseBreaker__mdt` Settings record, or null when there is none
     */
    private static CallwiseBreaker__mdt settingsFor(String namedCredential) {
        if (settingsOverride != null) {
            return settingsOverride.get(namedCredential);
        }
        return CallwiseBreaker__mdt.getInstance(namedCredential);
    }

    /**
     * @description Validates a numeric setting.
     *
     * @param value `Decimal` Field value, possibly null
     * @param max `Integer` Largest accepted value
     * @return `Integer` The value when it is a whole number between 1 and max, otherwise null
     */
    private static Integer inRange(Decimal value, Integer max) {
        if (value == null || value < 1 || value > max || value != value.round()) {
            return null;
        }
        return value.intValue();
    }

    /**
     * @description Returns the current time, or nowOverride in tests.
     *
     * @return `Long` Epoch milliseconds
     */
    private static Long now() {
        return nowOverride ?? System.currentTimeMillis();
    }

    /**
     * @description Returns the store for breaker state: the test override, the transaction store in tests, or the
     * Platform Cache store of the current partition, created once per partition and transaction.
     *
     * @return `Store` Store to use
     */
    private static Store store() {
        if (storeOverride != null) {
            return storeOverride;
        }
        if (Test.isRunningTest() && !usePlatformCacheInTests) {
            return TRANSACTION_STORE;
        }
        String partitionName = Callwise.getCachePartition();
        if (resolvedStore == null || resolvedPartition != partitionName) {
            resolvedPartition = partitionName;
            resolvedStore = new PlatformCacheStore(partitionName);
        }
        return resolvedStore;
    }

    /**
     * @description Writes a WARN debug line, once per transaction, when the cache partition cannot be used.
     *
     * @param partitionName `String` Partition that failed
     * @param cause `Exception` Error raised by Platform Cache
     */
    @SuppressWarnings('PMD.AvoidDebugStatements')
    private static void warnCacheUnavailable(String partitionName, Exception cause) {
        if (warned) {
            return;
        }
        warned = true;
        System.debug(
            LoggingLevel.WARN,
            String.format(
                '[Callwise] Platform Cache partition {0} is not usable ({1}). ' +
                'Circuit breaker state only lives for this transaction.',
                new List<Object>{ partitionName, cause.getMessage() }
            )
        );
    }

    /**
     * @description Keeps state in an org cache partition. Falls back to the transaction store for the rest of the
     * transaction as soon as the partition cannot be read or written.
     */
    @TestVisible
    private class PlatformCacheStore implements Store {
        /** @description Qualified partition name, e.g. local.Callwise. */
        private final String partitionName;
        /** @description Resolved partition; null when it could not be resolved. */
        private Cache.OrgPartition partition;
        /** @description True once the partition failed; from then on the transaction store is used. */
        private Boolean unavailable = false;

        /**
         * @description Resolves the partition. A missing partition marks the store as unavailable.
         *
         * @param partitionName `String` Qualified partition name
         */
        private PlatformCacheStore(String partitionName) {
            this.partitionName = partitionName;
            try {
                partition = Cache.Org.getPartition(partitionName);
            } catch (Exception e) {
                markUnavailable(e);
            }
        }

        /**
         * @description Reads from the partition, or from the transaction store when the partition is unavailable.
         *
         * @param key `String` Alphanumeric key
         * @return `State` Stored state, or null when absent or expired
         */
        public State get(String key) {
            if (!unavailable) {
                try {
                    return (State) partition.get(key);
                } catch (Exception e) {
                    markUnavailable(e);
                }
            }
            return TRANSACTION_STORE.get(key);
        }

        /**
         * @description Writes to the partition with CACHE_TTL_SECONDS, or to the transaction store when the partition
         * is unavailable.
         *
         * @param key `String` Alphanumeric key
         * @param state `State` State to store
         */
        public void put(String key, State state) {
            if (!unavailable) {
                try {
                    partition.put(key, state, CACHE_TTL_SECONDS);
                    return;
                } catch (Exception e) {
                    markUnavailable(e);
                }
            }
            TRANSACTION_STORE.put(key, state);
        }

        /**
         * @description Switches to the transaction store for the rest of the transaction and warns once.
         *
         * @param e `Exception` Error raised by Platform Cache
         */
        private void markUnavailable(Exception e) {
            unavailable = true;
            warnCacheUnavailable(partitionName, e);
        }
    }

    /**
     * @description Keeps state in a static map: shared by every breaker in the transaction, gone when it ends.
     */
    @TestVisible
    private class TransactionStore implements Store {
        /** @description State per cache key. */
        private final Map<String, State> states = new Map<String, State>();

        /**
         * @description Reads the state kept in this transaction.
         *
         * @param key `String` Alphanumeric key
         * @return `State` Stored state, or null when absent
         */
        public State get(String key) {
            return states.get(key);
        }

        /**
         * @description Keeps the state for the rest of the transaction.
         *
         * @param key `String` Alphanumeric key
         * @param state `State` State to store
         */
        public void put(String key, State state) {
            states.put(key, state);
        }
    }
}
