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
    payload = JSON.parse(String(response.body))
    if response.status >= 400
        err = payload["error"]
        error("NexOR server returned $(response.status) $(err["code"]): $(err["message"])")
    end
    return payload
end
