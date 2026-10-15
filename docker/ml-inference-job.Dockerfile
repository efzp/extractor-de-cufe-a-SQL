FROM python:3.11.9-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    MPLCONFIGDIR=/tmp/matplotlib \
    HOME=/tmp

# ODBC Driver 18 para token Entra de Azure SQL (Debian 12).
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl libgomp1 libstdc++6 libgssapi-krb5-2 \
    && curl -fsSLo /tmp/packages-microsoft-prod.deb https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb \
    && dpkg -i /tmp/packages-microsoft-prod.deb \
    && rm /tmp/packages-microsoft-prod.deb \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y --no-install-recommends msodbcsql18 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements-ml-smoke.txt requirements-ml-inference-job.txt ./
# El artefacto usa FastAI, pero no GPU. Fijar las mismas versiones de torch y
# torchvision que la prueba Linux, usando ruedas CPU para no incluir CUDA.
RUN python -m pip install --no-cache-dir \
        torch==2.13.0+cpu torchvision==0.28.0+cpu \
        --index-url https://download.pytorch.org/whl/cpu \
    && python -m pip install --no-cache-dir -r requirements-ml-inference-job.txt

COPY ml_dataset/__init__.py ml_dataset/config.py ml_dataset/message.py ml_dataset/service.py ./ml_dataset/
COPY ml_dataset/legacy/*.py ./ml_dataset/legacy/
COPY ml_inferencia/*.py ./ml_inferencia/
COPY scripts/entrenar_modelo_azure_sql.py scripts/probar_modelo_linux.py scripts/probar_inferencia_blob_azure_sql.py scripts/ejecutar_inferencia_blob_sql.py ./scripts/

USER 10001:10001
ENTRYPOINT ["python", "-m", "scripts.ejecutar_inferencia_blob_sql"]
CMD ["--limite", "3"]
