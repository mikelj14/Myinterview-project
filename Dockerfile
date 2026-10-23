FROM python:3.13-slim
WORKDIR /app
COPY requirements.txt .
# pip/setuptools are only needed to install; removing them drops their CVEs from the image
RUN pip install --no-cache-dir -r requirements.txt && pip uninstall -y pip setuptools
COPY app.py .
RUN useradd --create-home --uid 10001 appuser
# numeric UID: Kubernetes runAsNonRoot can only verify a number, not a username
USER 10001
ENV PORT=8080
# CI passes the commit SHA so the page shows which build is running
ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION
EXPOSE 8080
# gunicorn: production WSGI server; finishes in-flight requests on SIGTERM (needed for zero-downtime rollouts)
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "app:app"]
