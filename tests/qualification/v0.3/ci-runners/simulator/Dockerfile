FROM python:3.13-alpine
WORKDIR /app
COPY server.py /app/server.py
USER 65532:65532
EXPOSE 8081
ENTRYPOINT ["python3", "/app/server.py"]
