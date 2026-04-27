from flask import Flask, request, jsonify
import requests

## Define VARS
BACKEND_SERVER_URL = "http://127.0.0.1:11434"
PORT = 11435 ## Hosting port for this API proxy
API_KEY = "test1" ## replace with API key used to access this proxy


app = Flask(__name__)
@app.route("/<path:path>", methods=["POST","GET"])
def proxy(path):
    try:
        ## Extract the API key from headers or query parameters
        api_key = request.headers.get("Authorization")
        print(api_key)
        if not api_key:
            return jsonify({"error": "API key is required, or call direct to backend"}), 401
        elif api_key == f"Bearer {API_KEY}":    
            # Remove the API key from the request headers and query params before forwarding
            headers = {key: value for key, value in request.headers if key != "Authorization"}
            params = request.args.copy()
            print(headers)
            # Forward the request to the backend server without the API key
            response = requests.request(
                method=request.method,
                url=f"{BACKEND_SERVER_URL}/{path}",
                headers=headers,
                params=params,
                data=request.get_data(),
                json=request.get_json() if request.is_json else None,
                timeout=300,
            )
            print(response)
            # Send the response from the backend server back to the client
            return response.json()
        else:
            return jsonify({"error": "API key is not valid"}), 405
    except requests.RequestException as e:
        print(f"Error forwarding request: {e}")
        return jsonify({"error": "Internal Server Error"}), 500

if __name__ == "__main__":
    app.run(host="0.0.0.0",port=PORT)
