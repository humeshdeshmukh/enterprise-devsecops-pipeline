import pytest
import json
from app.main import app, PRODUCTS

@pytest.fixture
def client():
    app.config["TESTING"] = True
    with app.test_client() as client:
        yield client

def test_health_check(client):
    """Test health check returns status UP and 200 OK."""
    response = client.get("/health")
    assert response.status_code == 200
    data = json.loads(response.data)
    assert data["status"] == "UP"
    assert "database" in data["checks"]
    assert "system" in data["checks"]

def test_metrics(client):
    """Test metrics endpoint returns Prometheus format."""
    response = client.get("/metrics")
    assert response.status_code == 200
    assert b"http_requests_total" in response.data or b"# HELP" in response.data

def test_list_products(client):
    """Test list products returns all items."""
    response = client.get("/api/v1/products")
    assert response.status_code == 200
    data = json.loads(response.data)
    assert "products" in data
    assert "count" in data
    assert data["count"] == len(PRODUCTS)

def test_get_product_success(client):
    """Test get product by valid ID returns the product details."""
    response = client.get("/api/v1/products/1")
    assert response.status_code == 200
    data = json.loads(response.data)
    assert data["id"] == 1
    assert data["name"] == "Cloud Security Handbook"

def test_get_product_not_found(client):
    """Test get product by invalid ID returns 404."""
    response = client.get("/api/v1/products/999")
    assert response.status_code == 404
    data = json.loads(response.data)
    assert "error" in data

def test_create_product_success(client):
    """Test create product with valid body returns 201 and new product data."""
    payload = {
        "name": "Kubernetes Deep Dive Book",
        "price": 39.99,
        "category": "Books"
    }
    # Track count before insert
    count_before = len(PRODUCTS)
    response = client.post(
        "/api/v1/products",
        data=json.dumps(payload),
        content_type="application/json"
    )
    assert response.status_code == 201
    data = json.loads(response.data)
    assert data["name"] == "Kubernetes Deep Dive Book"
    assert data["price"] == 39.99
    assert data["category"] == "Books"
    assert len(PRODUCTS) == count_before + 1

def test_create_product_invalid_data(client):
    """Test create product with missing fields returns 400 Bad Request."""
    payload = {
        "category": "Books"
    }
    response = client.post(
        "/api/v1/products",
        data=json.dumps(payload),
        content_type="application/json"
    )
    assert response.status_code == 400
    data = json.loads(response.data)
    assert "error" in data
