FROM python:3.12-slim
WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
COPY tests ./tests
# don't run as root
RUN useradd --create-home appuser
USER appuser
EXPOSE 8000
# 1 worker on purpose, the fail-next counter is in memory
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
