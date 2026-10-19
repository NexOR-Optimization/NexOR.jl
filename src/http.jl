import HTTP

function _response(response)
    if response.status >= 300
        if startswith(HTTP.header(response, "Content-Type"), "application/json")
            payload = JSON.parse(String(response.body))
            err = get(payload, "error", payload)
            error(
                "NexOR server returned $(response.status) $(err["code"]): $(err["message"])",
            )
        end
        error("NexOR server returned $(response.status): $(String(response.body))")
    end
    return JSON.parse(String(response.body))
end

function _request(
    model::Optimizer,
    method::String,
    path::String;
    body::String = "",
    transport = HTTP.request,
)
    headers = ["Content-Type" => "application/json"]
    if !isempty(model.api_key)
        push!(headers, "Authorization" => "Bearer $(model.api_key)")
    end
    response = transport(
        method,
        rstrip(model.server_url, '/') * _API * path,
        headers,
        body;
        redirect = false,
        status_exception = false,
    )
    if method == "GET" && response.status == 302
        # Large results use a presigned object URL. Never forward the API key.
        response = transport(
            "GET",
            HTTP.header(response, "Location"),
            Pair{String,String}[],
            "";
            redirect = false,
            status_exception = false,
        )
    end
    return _response(response)
end
