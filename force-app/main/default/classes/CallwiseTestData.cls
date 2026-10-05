/**
 * @description Builders shared by the Callwise test classes: platform responses, CallwiseResponses and failures.
 */
@IsTest
public class CallwiseTestData {
    /**
     * @description Builds a platform response. Null arguments are left unset.
     *
     * @param statusCode `Integer` HTTP status code
     * @param status `String` Reason phrase, or null
     * @param body `String` Body, or null
     * @param headers `Map<String, String>` Headers, or null
     * @return `HttpResponse` Platform response
     */
    public static HttpResponse httpResponse(
        Integer statusCode,
        String status,
        String body,
        Map<String, String> headers
    ) {
        HttpResponse response = new HttpResponse();
        response.setStatusCode(statusCode);
        if (status != null) {
            response.setStatus(status);
        }
        if (body != null) {
            response.setBody(body);
        }
        for (String name : (headers ?? new Map<String, String>()).keySet()) {
            response.setHeader(name, headers.get(name));
        }
        return response;
    }

    /**
     * @description Builds a CallwiseResponse with only a status code, as obtained in one attempt.
     *
     * @param statusCode `Integer` HTTP status code
     * @return `CallwiseResponse` Response with 1 attempt and 0 ms elapsed
     */
    public static CallwiseResponse response(Integer statusCode) {
        return response(statusCode, null);
    }

    /**
     * @description Builds a CallwiseResponse with a status code and headers, as obtained in one attempt.
     *
     * @param statusCode `Integer` HTTP status code
     * @param headers `Map<String, String>` Headers, or null
     * @return `CallwiseResponse` Response with 1 attempt and 0 ms elapsed
     */
    public static CallwiseResponse response(Integer statusCode, Map<String, String> headers) {
        return new CallwiseResponse(httpResponse(statusCode, null, null, headers), 1, 0L);
    }

    /**
     * @description Builds a failure with the given reason.
     *
     * @param reason `CallwiseException.FailureReason` Failure category
     * @return `CallwiseException` Failure with the message 'test'
     */
    public static CallwiseException failure(CallwiseException.FailureReason reason) {
        return CallwiseException.create(reason, 'test');
    }
}
