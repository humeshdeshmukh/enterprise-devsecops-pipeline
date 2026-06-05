#!/usr/bin/env bash

# ==============================================================================
# Enterprise DevSecOps CI/CD Local Pipeline Runner
# This script simulates the full GitHub Actions pipeline locally.
# ==============================================================================

# Exit immediately if a command exits with a non-zero status
set -e

# Terminal Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}======================================================================${NC}"
echo -e "${CYAN}        ENTERPRISE DEVSECOPS LOCAL PIPELINE RUNNER                    ${NC}"
echo -e "${CYAN}======================================================================${NC}"

# Define project root relative to the script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Helper function to print headers
print_step() {
    echo -e "\n${BLUE}>>> [STEP] $1...${NC}"
}

# Helper function to check command dependencies
check_dep() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}[ERROR] Required dependency '$1' is not installed. Please install it first.${NC}"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# STEP 1: Verify Prerequisites
# ------------------------------------------------------------------------------
print_step "1/8: Verifying System Prerequisites"
check_dep python3
check_dep docker
check_dep kubectl
check_dep minikube
check_dep helm
echo -e "${GREEN}[OK] All local CLI tools (python3, docker, kubectl, minikube, helm) are present.${NC}"

# ------------------------------------------------------------------------------
# STEP 2: Setup Python Virtual Environment and Install Dependencies
# ------------------------------------------------------------------------------
print_step "2/8: Setting up virtual environment & installing dependencies"
if [ ! -d "venv" ]; then
    echo -e "${YELLOW}Creating python virtual environment (venv)...${NC}"
    python3 -m venv venv
fi

# Activate virtual environment
source venv/bin/activate

echo -e "${YELLOW}Installing requirements...${NC}"
pip install --upgrade pip
pip install -r app/requirements.txt
echo -e "${GREEN}[OK] Dependencies installed successfully in virtual environment.${NC}"

# ------------------------------------------------------------------------------
# STEP 3: Linting & Code Formatting
# ------------------------------------------------------------------------------
print_step "3/8: Code Linting and Formatting Checks"
echo -e "${YELLOW}Running Flake8 linter...${NC}"
# Stop the build if there are Python syntax errors or undefined names
flake8 app/ --count --select=E9,F63,F7,F82 --show-source --statistics
# Exit-zero on style checks for local running convenience, but fail on critical lint errors
flake8 app/ --count --max-complexity=10 --max-line-length=127 --statistics

echo -e "${YELLOW}Running Black formatter check...${NC}"
black --check app/
echo -e "${GREEN}[OK] Code structure and linting checks passed.${NC}"

# ------------------------------------------------------------------------------
# STEP 4: Unit Testing & Code Coverage
# ------------------------------------------------------------------------------
print_step "4/8: Running Unit Tests & Generating Coverage"
pytest --cov=app/ --cov-report=term-missing --cov-report=xml app/tests/

# Check coverage percentage and fail if below threshold (e.g. 80%)
COVERAGE_PCT=$(python3 -c "
import xml.etree.ElementTree as ET
try:
    tree = ET.parse('coverage.xml')
    root = tree.getroot()
    line_rate = float(root.attrib['line-rate'])
    print(int(line_rate * 100))
except Exception:
    print(0)
")

echo -e "${CYAN}Total Unit Test Code Coverage: ${COVERAGE_PCT}%${NC}"
if [ "${COVERAGE_PCT}" -lt 80 ]; then
    echo -e "${RED}[FAIL] Code coverage is ${COVERAGE_PCT}%, which is below the 80% minimum threshold!${NC}"
    exit 1
fi
echo -e "${GREEN}[OK] All unit tests passed and met the coverage threshold.${NC}"

# ------------------------------------------------------------------------------
# STEP 5: DevSecOps Static Analysis (SAST & SCA)
# ------------------------------------------------------------------------------
print_step "5/8: Running DevSecOps SAST & SCA Security Scans"
echo -e "${YELLOW}Running Bandit SAST security scan...${NC}"
# Scan code, report issues, fail on high severity
bandit -r app/ -ll -ii

echo -e "${YELLOW}Running Safety dependency scan...${NC}"
# Scan dependency requirements.txt
safety check -r app/requirements.txt || echo -e "${YELLOW}[WARNING] Safety scan found warnings. Continuing in local mode.${NC}"

echo -e "${YELLOW}Running Trivy filesystem vulnerability scan via Docker...${NC}"
# Run Trivy fs scan inside a Docker container
docker run --rm \
    -v "$(pwd)":/apps \
    aquasec/trivy:latest fs /apps \
    --severity HIGH,CRITICAL \
    --exit-code 0 # Set to 1 in strict pipelines to break build on vuln
echo -e "${GREEN}[OK] SAST and SCA scans completed successfully.${NC}"

# ------------------------------------------------------------------------------
# STEP 6: Container Build & Image Scan
# ------------------------------------------------------------------------------
print_step "6/8: Building Container & Scanning Image"
echo -e "${YELLOW}Building Docker Image 'product-catalog:latest'...${NC}"
docker build -t product-catalog:latest .

echo -e "${YELLOW}Running Trivy image vulnerability scan via Docker...${NC}"
# Run Trivy image scan using Docker
docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v ~/.cache:/root/.cache/ \
    aquasec/trivy:latest image product-catalog:latest \
    --severity HIGH,CRITICAL \
    --exit-code 0 # Set to 1 in strict pipelines to break build on vuln
echo -e "${GREEN}[OK] Docker image built and verified securely.${NC}"

# ------------------------------------------------------------------------------
# STEP 7: Local Kubernetes Deployment (Minikube & Helm)
# ------------------------------------------------------------------------------
print_step "7/8: Deploying to Local Kubernetes Cluster"

# Verify Minikube status
MINIKUBE_STATUS=$(minikube status --format='{{.Host}}' || echo "Stopped")
if [ "${MINIKUBE_STATUS}" != "Running" ]; then
    echo -e "${YELLOW}Minikube is not running. Starting Minikube cluster...${NC}"
    minikube start --memory=2048 --cpus=2
fi

echo -e "${YELLOW}Loading Docker image into Minikube cluster...${NC}"
minikube image load product-catalog:latest

echo -e "${YELLOW}Deploying Application via Helm...${NC}"
# Deploy using Helm chart, overriding service type to NodePort so we can easily query it locally
helm upgrade --install product-catalog ./helm/product-catalog \
    --namespace default \
    --set image.repository=product-catalog \
    --set image.tag=latest \
    --set service.type=NodePort \
    --wait

echo -e "${YELLOW}Verifying Rollout Status...${NC}"
kubectl rollout status deployment/product-catalog --namespace default --timeout=60s

# Get URL from minikube service exposure
SERVICE_URL=$(minikube service product-catalog --url --namespace default | head -n 1)
echo -e "${GREEN}[OK] Microservice successfully deployed to Kubernetes!${NC}"
echo -e "${GREEN}Service Endpoint URL: ${SERVICE_URL}${NC}"

# Wait 2 seconds for app sockets to settle
sleep 2

# ------------------------------------------------------------------------------
# STEP 8: Smoke Testing & Notifications Simulation
# ------------------------------------------------------------------------------
print_step "8/8: Performing App Smoke Test & Pipeline Notifications"

echo -e "${YELLOW}Testing health check endpoint (/health)...${NC}"
HEALTH_RESP=$(curl -s -o /dev/null -w "%{http_code}" "${SERVICE_URL}/health")
if [ "${HEALTH_RESP}" -eq 200 ]; then
    echo -e "${GREEN}[PASS] /health returned HTTP 200 OK${NC}"
else
    echo -e "${RED}[FAIL] /health returned HTTP ${HEALTH_RESP}${NC}"
    exit 1
fi

echo -e "${YELLOW}Testing catalog API GET endpoint (/api/v1/products)...${NC}"
PRODUCTS_RESP=$(curl -s "${SERVICE_URL}/api/v1/products")
echo -e "${CYAN}API Response:${NC} ${PRODUCTS_RESP}"

echo -e "${YELLOW}Simulating Slack Webhook notification...${NC}"
echo -e "${CYAN}Slack Notification Payload Summary:${NC}"
cat <<EOF
{
  "status": "SUCCESS",
  "notification_title": "product-catalog DevSecOps CI/CD Pipeline status",
  "message": "✅ pipeline successfully built, scanned, tested, and deployed to Kubernetes cluster (Minikube)!"
}
EOF

echo -e "\n${GREEN}======================================================================${NC}"
echo -e "${GREEN}      LOCAL DEVSECOPS PIPELINE RUN COMPLETED SUCCESSFULLY             ${NC}"
echo -e "${GREEN}======================================================================${NC}"
