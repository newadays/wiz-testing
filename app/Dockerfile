# Multi-stage, slim runtime, non-root. The image is (re)built by .github/workflows/app.yml.
FROM python:3.12-slim AS build
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim
WORKDIR /app
COPY --from=build /install /usr/local
COPY app.py .
COPY templates ./templates
# Requirement: the image must contain wizexercise.txt with the candidate's name.
# It is copied from the build context (committed to the repo) so it is in the image layer,
# not mounted at runtime. Verify: docker run --rm IMAGE cat /app/wizexercise.txt
COPY wizexercise.txt /app/wizexercise.txt
# Pick up Debian security fixes released after the base image was built (e.g. zlib), so Trivy's gate passes.
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*
RUN useradd --uid 10001 --no-create-home appuser && chown -R appuser /app
USER 10001
ENV PYTHONUNBUFFERED=1
EXPOSE 8080
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--threads", "4", "app:app"]
