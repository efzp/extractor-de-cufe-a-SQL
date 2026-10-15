FROM python:3.11.9-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    MPLCONFIGDIR=/tmp/matplotlib

RUN apt-get update \
    && apt-get install -y --no-install-recommends libgomp1 libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements-ml-smoke.txt ./
RUN python -m pip install --no-cache-dir -r requirements-ml-smoke.txt

COPY ml_dataset/__init__.py ml_dataset/config.py ml_dataset/message.py ml_dataset/service.py ./ml_dataset/
COPY ml_dataset/legacy/*.py ./ml_dataset/legacy/
COPY ml_inferencia/__init__.py ml_inferencia/service.py ./ml_inferencia/
COPY scripts/entrenar_modelo_azure_sql.py scripts/probar_modelo_linux.py ./scripts/

USER 10001:10001
CMD ["python", "scripts/probar_modelo_linux.py", \
     "--paquete", "/input/modelo.tar.gz", \
     "--manifiesto", "/input/manifiesto.json", \
     "--referencia-dir", "/input/referencia", \
     "--sha256-paquete", "b0dcb976fcd986317dde055d322555b805a504c48325a117b63c5fdf90dac4a3"]
