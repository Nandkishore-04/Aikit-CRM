FROM python:3.12-slim
WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
COPY tests ./tests
# Run as non-root.
RUN useradd --create-home appuser
USER appuser
EXPOSE 8000
# Single worker on purpose: the test-only fail-injection counter lives in memory.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
