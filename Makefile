# Makefile for Enterprise DevSecOps CI/CD Pipeline

.PHONY: all install lint test scan build deploy clean

# Default targets
all:
	@chmod +x local-pipeline.sh
	./local-pipeline.sh

install:
	@echo "Setting up virtual environment and installing dependencies..."
	python3 -m venv venv
	./venv/bin/pip install --upgrade pip
	./venv/bin/pip install -r app/requirements.txt

lint:
	@echo "Running code linters & formatters..."
	./venv/bin/flake8 app/ --count --select=E9,F63,F7,F82 --show-source --statistics
	./venv/bin/flake8 app/ --count --max-complexity=10 --max-line-length=127 --statistics
	./venv/bin/black --check app/

test:
	@echo "Running unit tests with coverage..."
	./venv/bin/pytest --cov=app/ --cov-report=term-missing --cov-report=xml app/tests/

scan:
	@echo "Running SAST and SCA security scans..."
	./venv/bin/bandit -r app/ -ll -ii
	./venv/bin/safety check -r app/requirements.txt || echo "Safety scan finished with warnings."
	@echo "Running Trivy filesystem scan..."
	docker run --rm -v "$$(pwd)":/apps aquasec/trivy:latest fs /apps --severity HIGH,CRITICAL

build:
	@echo "Building docker container..."
	docker build -t product-catalog:latest .
	@echo "Scanning docker container..."
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v ~/.cache:/root/.cache/ aquasec/trivy:latest image product-catalog:latest --severity HIGH,CRITICAL

deploy:
	@echo "Deploying application to local Minikube cluster..."
	minikube image load product-catalog:latest
	helm upgrade --install product-catalog ./helm/product-catalog \
		--namespace default \
		--set image.repository=product-catalog \
		--set image.tag=latest \
		--set service.type=NodePort \
		--wait
	kubectl rollout status deployment/product-catalog --namespace default --timeout=60s
	@echo "Service URL:"
	minikube service product-catalog --url

clean:
	@echo "Cleaning up generated workspace cache..."
	rm -rf venv
	rm -rf .pytest_cache
	rm -rf .coverage
	rm -rf coverage.xml
	find . -type d -name "__pycache__" -exec rm -rf {} +
	@echo "Clean completed."
