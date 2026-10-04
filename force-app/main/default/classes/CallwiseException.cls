/**
 * Raised by Callwise for transport failures and library-level failures. HTTP error statuses (4xx/5xx) are
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
    /**
     * Why the call failed.
     */
    public enum FailureReason {
        /** The request was built with invalid arguments, or the library was misconfigured. */
        INVALID_REQUEST,
        /** The callout failed below HTTP (DNS, TLS, connection reset, unknown Named Credential...). */
        TRANSPORT,
        /** The callout exceeded its timeout. */
        TIMEOUT,
        /** The circuit breaker for the Named Credential is open; no callout was made. */
        CIRCUIT_OPEN,
        /** The next attempt would not fit in the remaining callout count or cumulative timeout budget. */
        LIMIT_BUDGET,
        /** DML ran earlier in the transaction; callouts are not allowed until it commits. Use sendAsync(). */
        UNCOMMITTED_WORK,
        /** The server answered with a non-2xx status and the request used throwOnError(). */
        HTTP_ERROR
    }

    /**
     * Failure category. Never null on exceptions created through the factories.
     */
    public FailureReason reason { get; private set; }

    /**
     * Response that caused the failure. Only set when reason is HTTP_ERROR.
     */
    public CallwiseResponse response { get; private set; }

    /**
     * Creates an exception with the given reason.
     *
     * @param reason Failure category
     * @param message Human-readable description. Must not contain request or response bodies.
     * @return The exception, ready to throw
     */
    public static CallwiseException create(FailureReason reason, String message) {
        CallwiseException failure = new CallwiseException(message);
        failure.reason = reason;
        return failure;
    }

    /**
     * Creates an exception with the given reason, preserving the original cause.
     *
     * @param reason Failure category
     * @param message Human-readable description. Must not contain request or response bodies.
     * @param cause Underlying exception
     * @return The exception, ready to throw
     */
    public static CallwiseException create(FailureReason reason, String message, Exception cause) {
        CallwiseException failure = new CallwiseException(message, cause);
        failure.reason = reason;
        return failure;
    }

    /**
     * Creates an HTTP_ERROR exception that carries the response.
     *
     * @param response Non-successful response
     * @return The exception, ready to throw
     * @throws CallwiseException INVALID_REQUEST when response is null
     */
    public static CallwiseException fromResponse(CallwiseResponse response) {
        if (response == null) {
            throw create(FailureReason.INVALID_REQUEST, 'Cannot build an HTTP error from a null response.');
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
}
