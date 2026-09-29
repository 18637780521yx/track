FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY migrations ./migrations

ENV ADDR=:8080
ENV DATABASE_URL=postgres://track:track@postgres:5432/track?sslmode=disable

EXPOSE 8080
CMD ["python", "-m", "app.main"]
