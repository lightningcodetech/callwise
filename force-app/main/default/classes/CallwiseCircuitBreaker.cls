/**
 * Internal: circuit breaker per Named Credential. Not part of the public API; the engine uses it for every request
 * unless the request calls withoutCircuitBreaker().
 *
 * CLOSED → OPEN after FAILURE_THRESHOLD consecutive failures. OPEN rejects requests for OPEN_DURATION_MS, then
 * HALF_OPEN lets one trial request through: success closes the circuit, failure opens it again.
 *
 * State lives in the org Platform Cache partition returned by Callwise.getCachePartition(). When the partition is
 * missing or unusable, state falls back to a store that only lives for the current transaction, and a warning is
 * written to the debug log once per transaction. A cache problem never opens the circuit.
 *
 * Best effort: Platform Cache has no atomic compare-and-set, so concurrent transactions can race on the counter.
 */
public inherited sharing class CallwiseCircuitBreaker {
    /** Consecutive failures that open the circuit. */
    public static final Integer FAILURE_THRESHOLD = 5;
    /** Time the circuit stays open before a trial request is allowed, in milliseconds. */
    public static final Integer OPEN_DURATION_MS = 60000;

    /** Cache entries outlive any open period; expiry only resets an idle breaker to CLOSED. */
    private static final Integer CACHE_TTL_SECONDS = 86400;
    private static final String KEY_PREFIX = 'cwcb';

    /** Replaces the clock in tests. */
    @TestVisible
    private static Long nowOverride;

    /** Replaces the store in tests. */
    @TestVisible
    private static Store storeOverride;

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
        if (state.status == CircuitStatus.OPEN && now - state.openedAt < OPEN_DURATION_MS) {
            return false;
        }
        // A trial that never reported back (its transaction failed) is replaced after the same wait.
        if (state.status == CircuitStatus.HALF_OPEN && now - state.trialStartedAt < OPEN_DURATION_MS) {
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
        Long remainingMs = Math.max(0, OPEN_DURATION_MS - (now() - state.openedAt));
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
        if (state.status == CircuitStatus.HALF_OPEN || state.consecutiveFailures >= FAILURE_THRESHOLD) {
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
