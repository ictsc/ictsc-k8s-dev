FROM python:3.12.12-alpine3.22
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY cleanup.py .
USER 65532:65532
ENTRYPOINT ["python", "/app/cleanup.py"]
