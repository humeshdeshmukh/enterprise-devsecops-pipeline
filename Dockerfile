# ==============================================================================
# STAGE 1: Builder
# ==============================================================================
FROM python:3.11-slim AS builder

WORKDIR /build

# Install system dependencies needed for compiling python packages (if any)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install python dependencies and compile them into wheels
COPY app/requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

# ==============================================================================
# STAGE 2: Final Runner
# ==============================================================================
FROM python:3.11-slim AS runner

# Set environment variables for Python optimization and safety
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=5000 \
    ENV=production

WORKDIR /app

# Create a system group and user with specific UID/GID for security
RUN groupadd -g 10001 appgroup && \
    useradd -r -u 10001 -g appgroup -d /app -s /sbin/nologin -c "Application User" appuser

# Copy installed packages from the builder stage
COPY --from=builder /root/.local /home/appuser/.local
COPY app/ /app/

# Ensure all files are owned by the non-root app user
RUN chown -R appuser:appgroup /app /home/appuser

# Add PATH environment variable to locate installed local pip packages
ENV PATH=/home/appuser/.local/bin:$PATH

# Expose the application port
EXPOSE 5000

# Set up health check instructions for container runtime
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:5000/health || exit 1

# Run the container under the non-root user account
USER 10001:10001

# Command to execute the Flask application using Gunicorn for production
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "4", "--threads", "2", "main:app"]
