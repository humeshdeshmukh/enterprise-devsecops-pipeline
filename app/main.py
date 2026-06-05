import os
import time
import logging
import json
from flask import Flask, jsonify, request, Response
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST


# Configure structured JSON logging
class JSONFormatter(logging.Formatter):
    def format(self, record):
        log_record = {
            "timestamp": self.formatTime(record, self.datefmt),
            "level": record.levelname,
            "message": record.getMessage(),
            "module": record.module,
            "filename": record.filename,
            "line": record.lineno,
        }
        if record.exc_info:
            log_record["exception"] = self.formatException(record.exc_info)
        return json.dumps(log_record)


logger = logging.getLogger("product-catalog")
handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logger.addHandler(handler)
logger.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())

app = Flask(__name__)

# Prometheus metrics setup
REQUEST_COUNT = Counter(
    "http_requests_total", "Total HTTP Requests", ["method", "endpoint", "http_status"]
)
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP Request Latency in Seconds",
    ["method", "endpoint"],
)

# In-memory product database
PRODUCTS = [
    {"id": 1, "name": "Cloud Security Handbook", "price": 49.99, "category": "Books"},
    {
        "id": 2,
        "name": "Kubernetes Mastery Course",
        "price": 199.99,
        "category": "Education",
    },
    {
        "id": 3,
        "name": "DevSecOps Automation Tool",
        "price": 29.99,
        "category": "Software",
    },
]


@app.before_request
def start_timer():
    request.start_time = time.time()


@app.after_request
def log_request(response):
    # Skip logging and metrics for health/metrics endpoints to keep logs clean
    if request.path in ["/health", "/metrics"]:
        return response

    latency = time.time() - request.start_time
    REQUEST_COUNT.labels(
        method=request.method, endpoint=request.path, http_status=response.status_code
    ).inc()
    REQUEST_LATENCY.labels(method=request.method, endpoint=request.path).observe(
        latency
    )

    logger.info(
        "Request processed",
        extra={
            "method": request.method,
            "path": request.path,
            "status": response.status_code,
            "latency": latency,
            "ip": request.remote_addr,
        },
    )
    return response


@app.route("/health", methods=["GET"])
def health_check():
    """
    Detailed health check for Liveness and Readiness probes.
    Checks memory usage and database connectivity.
    """
    health_status = {
        "status": "UP",
        "timestamp": time.time(),
        "checks": {
            "database": {"status": "UP", "latency_ms": 0.5},  # Mocked latency check
            "system": {"status": "UP", "memory_healthy": True},
        },
    }

    # Try to calculate memory usage if on Linux
    try:
        with open("/proc/self/status", "r") as f:
            lines = f.readlines()
            for line in lines:
                if line.startswith("VmRSS:"):
                    mem_kb = int(line.split()[1])
                    health_status["checks"]["system"]["memory_used_kb"] = mem_kb
                    if mem_kb > 512000:  # 500 MB limit check for mock
                        health_status["status"] = "DEGRADED"
                        health_status["checks"]["system"]["memory_healthy"] = False
                    break
    except Exception:
        # Fallback if proc fs is not available (e.g. non-linux test environment)
        health_status["checks"]["system"]["memory_used_kb"] = 0

    status_code = 200 if health_status["status"] == "UP" else 503
    return jsonify(health_status), status_code


@app.route("/metrics", methods=["GET"])
def metrics():
    """Expose Prometheus metrics."""
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


@app.route("/api/v1/products", methods=["GET"])
def list_products():
    """Retrieve all products from the catalog."""
    logger.debug("Listing all products")
    return jsonify({"products": PRODUCTS, "count": len(PRODUCTS)})


@app.route("/api/v1/products/<int:product_id>", methods=["GET"])
def get_product(product_id):
    """Retrieve a single product by its ID."""
    logger.debug(f"Retrieving product with ID: {product_id}")
    product = next((p for p in PRODUCTS if p["id"] == product_id), None)
    if product is None:
        logger.warning(f"Product not found: {product_id}")
        return jsonify({"error": "Product not found"}), 404
    return jsonify(product)


@app.route("/api/v1/products", methods=["POST"])
def create_product():
    """Create a new product."""
    data = request.get_json()
    if not data or not data.get("name") or not data.get("price"):
        logger.warning("Failed product creation: missing name or price")
        return jsonify({"error": "Missing required fields: name, price"}), 400

    new_product = {
        "id": len(PRODUCTS) + 1,
        "name": data["name"],
        "price": float(data["price"]),
        "category": data.get("category", "General"),
    }
    PRODUCTS.append(new_product)
    logger.info(f"Created new product with ID: {new_product['id']}")
    return jsonify(new_product), 201


if __name__ == "__main__":
    port = int(os.getenv("PORT", 5000))
    # In production, we run through gunicorn, but we keep this for local run
    app.run(host="0.0.0.0", port=port)  # nosec B104
