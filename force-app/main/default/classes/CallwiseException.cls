/**
 * @description Raised by Callwise for transport failures and library-level failures. HTTP error statuses (4xx/5xx) are
 * returned as a CallwiseResponse and only raise this exception when the request opts in with throwOnError().
 *
 * @example
 * try {
 *     Callwise.to('ERP').get('/orders/42').throwOnError().send();
 * } catch (CallwiseException e) {
 *     if (e.reason == CallwiseException.FailureReason.HTTP_ERROR) {
 *         Integer status = e.response.getStatusCode();
 *     }
 * }
 */
public inherited sharing class CallwiseException extends Exception {
    /** @description Failure category. Never null on exceptions created through the factories. */
    public FailureReason reason { get; private set; }
    /** @description Response that caused the failure. Only set when reason is HTTP_ERROR. */
    public CallwiseResponse response { get; private set; }

    /**
     * @description Why the call failed.
     */
    public enum FailureReason {
        /** @description The request was built with invalid arguments, or the library was misconfigured. */
        INVALID_REQUEST,
        /** @description The callout failed below HTTP (DNS, TLS, connection reset, unknown Named Credential...). */
        TRANSPORT,
        /** @description The callout exceeded its timeout. */
        TIMEOUT,
        /** @description The circuit breaker for the Named Credential is open; no callout was made. */
        CIRCUIT_OPEN,
        /** @description The next attempt would not fit in the remaining callout count or cumulative timeout budget. */
        LIMIT_BUDGET,
        /**
         * @description DML ran earlier in the transaction; callouts are not allowed until it commits. Use sendAsync().
         */
        UNCOMMITTED_WORK,
        /** @description The server answered with a non-2xx status and the request used throwOnError(). */
        HTTP_ERROR
    }

    /**
     * @description Creates an exception with the given reason.
     *
     * @param reason `FailureReason` Failure category
     * @param message `String` Human-readable description. Must not contain request or response bodies.
     * @return `CallwiseException` The exception, ready to throw
     */
    public static CallwiseException create(FailureReason reason, String message) {
        CallwiseException failure = new CallwiseException(message);
        failure.reason = reason;
        return failure;
    }

    /**
     * @description Creates an exception with the given reason, preserving the original cause.
     *
     * @param reason `FailureReason` Failure category
     * @param message `String` Human-readable description. Must not contain request or response bodies.
     * @param cause `Exception` Underlying exception
     * @return `CallwiseException` The exception, ready to throw
     */
    public static CallwiseException create(FailureReason reason, String message, Exception cause) {
        CallwiseException failure = new CallwiseException(message, cause);
        failure.reason = reason;
        return failure;
    }

    /**
     * @description Creates an INVALID_REQUEST exception, for invalid arguments or configuration.
     *
     * @param message `String` Description of the invalid argument. Must not contain request or response bodies.
     * @return `CallwiseException` The exception, ready to throw
     */
    public static CallwiseException invalidRequest(String message) {
        return create(FailureReason.INVALID_REQUEST, message);
    }

    /**
     * @description Creates an HTTP_ERROR exception that carries the response.
     *
     * @param response `CallwiseResponse` Non-successful response
     * @return `CallwiseException` The exception, ready to throw
     * @throws `CallwiseException` INVALID_REQUEST when response is null
     */
    public static CallwiseException fromResponse(CallwiseResponse response) {
        if (response == null) {
            throw invalidRequest('Cannot build an HTTP error from a null response.');
        }
        CallwiseException failure = create(
            FailureReason.HTTP_ERROR,
            'HTTP ' +
                response.getStatusCode() +
                (String.isBlank(response.getStatus()) ? '' : ' ' + response.getStatus())
        );
        failure.response = response;
        return failure;
    }

    /**
     * @description Tells whether the callout failed below HTTP. Retry policies and the circuit breaker treat these
     * failures as signs of an unhealthy endpoint.
     *
     * @return `Boolean` True for TRANSPORT and TIMEOUT
     */
    public Boolean isTransportFailure() {
        return this.reason == FailureReason.TRANSPORT || this.reason == FailureReason.TIMEOUT;
    }
}
