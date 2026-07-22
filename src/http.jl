import HTTP

function _request(model::Optimizer, method::String, path::String; body::String = "")
    headers = ["Content-Type" => "application/json"]
    if !isempty(model.api_key)
        push!(headers, "Authorization" => "Bearer $(model.api_key)")
    end
    response = HTTP.request(
        method,
        model.server_url * _API * path,
        headers,
        body;
        status_exception = false,
    )
    if response.status >= 400
        # The error may come from the proxy or a crashed handler rather than
        # the API, in which case the body is not the JSON error object
        if startswith(HTTP.header(response, "Content-Type"), "application/json")
            err = JSON.parse(String(response.body))["error"]
            error(
                "NexOR server returned $(response.status) $(err["code"]): $(err["message"])",
            )
        end
        error("NexOR server returned $(response.status): $(String(response.body))")
    end
    return JSON.parse(String(response.body))
end
