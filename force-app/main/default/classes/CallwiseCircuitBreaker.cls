/**
 * Internal: circuit breaker per Named Credential. Not part of the public API; the engine uses it for every request
 * unless the request calls withoutCircuitBreaker().
 *
 * CLOSED → OPEN after a number of consecutive failures. OPEN rejects requests for a while, then HALF_OPEN lets one
 * trial request through: success closes the circuit, failure opens it again.
 *
 * Both values come from the Callwise_Breaker__mdt record named after the Named Credential. Without a record, or for a
 * blank or out-of-range field, the defaults apply: FAILURE_THRESHOLD failures and OPEN_DURATION_MS.
 *
 * State lives in the org Platform Cache partition returned by Callwise.getCachePartition(). When the partition is
 * missing or unusable, state falls back to a store that only lives for the current transaction, and a warning is
 * written to the debug log once per transaction. A cache problem never opens the circuit.
 *
 * Best effort: Platform Cache has no atomic compare-and-set, so concurrent transactions can race on the counter.
 */
public inherited sharing class CallwiseCircuitBreaker {
    /** Default consecutive failures that open the circuit. */
    public static final Integer FAILURE_THRESHOLD = 5;
    /** Default time the circuit stays open before a trial request is allowed, in milliseconds. */
    public static final Integer OPEN_DURATION_MS = 60000;
    /** Largest Failure_Threshold__c accepted. */
    public static final Integer MAX_FAILURE_THRESHOLD = 100;
    /** Largest Open_Seconds__c accepted; well below the cache TTL, so open state never expires early. */
    public static final Integer MAX_OPEN_SECONDS = 3600;

    /** Cache entries outlive any open period; expiry only resets an idle breaker to CLOSED. */
    private static final Integer CACHE_TTL_SECONDS = 86400;
    private static final String KEY_PREFIX = 'cwcb';

    /** Replaces the clock in tests. */
    @TestVisible
    private static Long nowOverride;

    /** Replaces the store in tests. */
    @TestVisible
    private static Store storeOverride;

    /** Replaces Callwise_Breaker__mdt records in tests, keyed by Named Credential. */
    @TestVisible
    private static Map<String, Callwise_Breaker__mdt> settingsOverride;

    /** Lets tests exercise the Platform Cache path; by default tests use the transaction store for isolation. */
    @TestVisible
    private static Boolean usePlatformCacheInTests = false;

    private static final TransactionStore TRANSACTION_STORE = new TransactionStore();
    private static Store resolvedStore;
    private static String resolvedPartition;
    @TestVisible
    private static Boolean warned = false;

    private final String namedCredential;
    private final String key;
    private final Integer failureThreshold;
    private final Long openDurationMs;

    /**
     * Breaker state values.
     */
    public enum CircuitStatus {
        CLOSED,
        OPEN,
        HALF_OPEN
    }

    /**
     * Serializable breaker state, as stored in the cache.
     */
    public class State {
        public CircuitStatus status = CircuitStatus.CLOSED;
        public Integer consecutiveFailures = 0;
        public Long openedAt;
        public Long trialStartedAt;
    }

    /**
     * Where breaker state is kept.
     */
    public interface Store {
        /**
         * @param key Alphanumeric key
         * @return Stored state, or null when absent or expired
         */
        State get(String key);

        /**
         * @param key Alphanumeric key
         * @param state State to store
         */
        void put(String key, State state);
    }

    /**
     * @param namedCredential API name of the Named Credential the breaker protects
     */
    public CallwiseCircuitBreaker(String namedCredential) {
        this.namedCredential = namedCredential;
        // Cache keys must be alphanumeric; Named Credential names may contain underscores.
        this.key = KEY_PREFIX + EncodingUtil.convertToHex(Crypto.generateDigest('MD5', Blob.valueOf(namedCredential)));
        Callwise_Breaker__mdt settings = settingsFor(namedCredential);
        this.failureThreshold = inRange(settings?.Failure_Threshold__c, MAX_FAILURE_THRESHOLD) ?? FAILURE_THRESHOLD;
        Integer openSeconds = inRange(settings?.Open_Seconds__c, MAX_OPEN_SECONDS);
        this.openDurationMs = openSeconds == null ? OPEN_DURATION_MS : openSeconds * 1000L;
    }

    /**
     * @return Consecutive failures that open this circuit
     */
    public Integer getFailureThreshold() {
        return failureThreshold;
    }

    /**
     * @return Time this circuit stays open before a trial request, in milliseconds
     */
    public Long getOpenDurationMs() {
        return openDurationMs;
    }

    /**
     * Decides whether a request may be sent now. Moves an expired OPEN circuit to HALF_OPEN and claims the trial.
     *
     * @return True when the request may be sent
     */
    public Boolean allowRequest() {
        State state = load();
        Long now = now();
        if (state.status == CircuitStatus.CLOSED) {
            return true;
        }
        if (state.status == CircuitStatus.OPEN && now - state.openedAt < openDurationMs) {
            return false;
        }
        // A trial that never reported back (its transaction failed) is replaced after the same wait.
        if (state.status == CircuitStatus.HALF_OPEN && now - state.trialStartedAt < openDurationMs) {
            return false;
        }
        state.status = CircuitStatus.HALF_OPEN;
        state.trialStartedAt = now;
        save(state);
        return true;
    }

    /**
     * Records the outcome of an attempt. Only endpoint health counts: transport failures, timeouts and 5xx, 408 and
     * 429 responses are failures; any other response is a success. Other failures (uncommitted work, limits) are
     * not recorded.
     *
     * @param response Response of the attempt, or null
     * @param failure Exception raised by the attempt, or null
     */
    public void record(CallwiseResponse response, CallwiseException failure) {
        if (failure != null) {
            if (
                failure.reason == CallwiseException.FailureReason.TRANSPORT ||
                failure.reason == CallwiseException.FailureReason.TIMEOUT
            ) {
                recordFailure();
            }
            return;
        }
        if (response == null) {
            return;
        }
        Integer statusCode = response.getStatusCode();
        if (statusCode >= 500 || statusCode == 408 || statusCode == 429) {
            recordFailure();
        } else {
            recordSuccess();
        }
    }

    /**
     * @return Current status, for diagnostics and tests
     */
    public CircuitStatus getStatus() {
        return load().status;
    }

    /**
     * @return Seconds until an open circuit lets a trial request through; 0 when it is not open
     */
    public Long secondsUntilTrial() {
        State state = load();
        if (state.status != CircuitStatus.OPEN) {
            return 0;
        }
        Long remainingMs = Math.max(0, openDurationMs - (now() - state.openedAt));
        return (remainingMs + 999) / 1000;
    }

    /**
     * @return Exception thrown when the circuit rejects a request
     */
    public CallwiseException openCircuitException() {
        return CallwiseException.create(
            CallwiseException.FailureReason.CIRCUIT_OPEN,
            'Circuit open for ' +
                namedCredential +
                ' after repeated failures; no callout was made. Next trial in about ' +
                secondsUntilTrial() +
                ' s.'
        );
    }

    private void recordSuccess() {
        State state = load();
        if (state.status == CircuitStatus.CLOSED && state.consecutiveFailures == 0) {
            return;
        }
        save(new State());
    }

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

    private State load() {
        return store().get(key) ?? new State();
    }

    private void save(State state) {
        store().put(key, state);
    }

    private static Callwise_Breaker__mdt settingsFor(String namedCredential) {
        if (settingsOverride != null) {
            return settingsOverride.get(namedCredential);
        }
        return Callwise_Breaker__mdt.getInstance(namedCredential);
    }

    /**
     * @return The value as an Integer when it is a whole number between 1 and max, otherwise null
     */
    private static Integer inRange(Decimal value, Integer max) {
        if (value == null || value < 1 || value > max || value.scale() > 0 && value != value.round()) {
            return null;
        }
        return value.intValue();
    }

    private static Long now() {
        return nowOverride ?? System.currentTimeMillis();
    }

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

    @SuppressWarnings('PMD.AvoidDebugStatements')
    private static void warnCacheUnavailable(String partitionName, Exception cause) {
        if (warned) {
            return;
        }
        warned = true;
        System.debug(
            LoggingLevel.WARN,
            '[Callwise] Platform Cache partition ' +
                partitionName +
                ' is not usable (' +
                cause.getMessage() +
                '). Circuit breaker state only lives for this transaction.'
        );
    }

    /**
     * Keeps state in an org cache partition. Falls back to the transaction store for the rest of the transaction
     * as soon as the partition cannot be read or written.
     */
    @TestVisible
    private class PlatformCacheStore implements Store {
        private final String partitionName;
        private Cache.OrgPartition partition;
        private Boolean unavailable = false;

        private PlatformCacheStore(String partitionName) {
            this.partitionName = partitionName;
            try {
                partition = Cache.Org.getPartition(partitionName);
            } catch (Exception e) {
                markUnavailable(e);
            }
        }

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

        private void markUnavailable(Exception e) {
            unavailable = true;
            warnCacheUnavailable(partitionName, e);
        }
    }

    /**
     * Keeps state in a static map: shared by every breaker in the transaction, gone when it ends.
     */
    @TestVisible
    private class TransactionStore implements Store {
        private final Map<String, State> states = new Map<String, State>();

        public State get(String key) {
            return states.get(key);
        }

        public void put(String key, State state) {
            states.put(key, state);
        }
    }
}
