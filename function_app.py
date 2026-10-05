import json
import logging

import azure.functions as func

from dian.errors import (
    DianConfigurationError,
    DianDocumentNotFoundError,
    DianServiceError,
)
from dian.service import run_dian_get_xml
from dian_ingestion.errors import (
    IngestionConfigurationError,
    IngestionPersistenceError,
    SpreadsheetValidationError,
)
from dian_ingestion.service import accept_upload, process_queued_load
from dian_ingestion.document_service import process_queued_document


app = func.FunctionApp()


@app.function_name(name="RecibirCargaDian")
@app.route(
    route="dian/cargas/{cliente_id}",
    methods=["POST"],
    auth_level=func.AuthLevel.FUNCTION,
)
def receive_dian_load(req: func.HttpRequest) -> func.HttpResponse:
    """Recibe un XLSX, lo almacena en Blob y agenda su procesamiento."""
    try:
        client_id = int(req.route_params.get("cliente_id", ""))
    except (TypeError, ValueError):
        return _json_response(
            {
                "status": "REJECTED",
                "message": "El ClienteID de la ruta debe ser un entero positivo.",
            },
            status_code=400,
        )

    try:
        queued_load = accept_upload(
            client_id=client_id,
            file_name=req.headers.get("x-file-name", ""),
            content=req.get_body(),
            sharepoint_item_id=req.headers.get("x-sharepoint-item-id"),
            sharepoint_url=req.headers.get("x-sharepoint-url"),
            etag=req.headers.get("x-sharepoint-etag"),
            preferred_table_name=req.headers.get("x-table-name"),
            uploaded_by=req.headers.get("x-uploaded-by"),
        )
        return _json_response(
            {
                "status": "ACCEPTED",
                "correlationId": queued_load.correlation_id,
                "clienteId": queued_load.client_id,
                "fileName": queued_load.file_name,
                "message": "El archivo fue almacenado y quedó pendiente de procesamiento.",
            },
            status_code=202,
        )
    except SpreadsheetValidationError as error:
        return _json_response(
            {"status": "REJECTED", "message": str(error)},
            status_code=400,
        )
    except IngestionConfigurationError:
        logging.exception("La ingestión DIAN no está configurada correctamente.")
        return _json_response(
            {
                "status": "NOT_CONFIGURED",
                "message": "Falta configurar almacenamiento o Azure SQL.",
            },
            status_code=503,
        )
    except Exception:
        logging.exception("No fue posible recibir el listado DIAN.")
        return _json_response(
            {
                "status": "ERROR",
                "message": "No fue posible almacenar y agendar el archivo.",
            },
            status_code=500,
        )


@app.function_name(name="ProcesarCargaDian")
@app.queue_trigger(
    arg_name="message",
    queue_name="%DIAN_LOAD_QUEUE_NAME%",
    connection="DianStorage",
)
def process_dian_load(message: func.QueueMessage) -> None:
    """Procesa un XLSX encolado y registra su trazabilidad en Azure SQL."""
    try:
        summary = process_queued_load(message.get_body().decode("utf-8"))
        logging.info(
            "Carga DIAN procesada. correlationId=%s cargaArchivoId=%s "
            "estado=%s totalProcesable=%s omitidos=%s errores=%s encolados=%s",
            summary.correlation_id,
            summary.load_id,
            summary.status,
            summary.total_rows,
            summary.ignored_rows,
            summary.error_rows,
            summary.queued_documents,
        )
    except (
        SpreadsheetValidationError,
        IngestionConfigurationError,
        IngestionPersistenceError,
    ):
        logging.exception("Falló el procesamiento controlado de una carga DIAN.")
        raise
    except Exception:
        logging.exception("Falló inesperadamente el procesamiento de una carga DIAN.")
        raise


@app.function_name(name="ProcesarDocumentoDian")
@app.queue_trigger(
    arg_name="message",
    queue_name="%DIAN_QUEUE_NAME%",
    connection="DianStorage",
)
def process_dian_document(message: func.QueueMessage) -> None:
    """Consulta el XML de un documento encolado y registra su resultado."""
    try:
        summary = process_queued_document(message.get_body().decode("utf-8"))
        logging.info(
            "Documento DIAN procesado. documentoId=%s consultaDianId=%s "
            "resultado=%s reintentoEncolado=%s",
            summary.document_id,
            summary.consultation_id,
            summary.result,
            summary.retry_queued,
        )
    except Exception:
        logging.exception("Fallo el procesamiento de un documento DIAN encolado.")
        raise


@app.function_name(name="DianGetXmlPoc")
@app.route(
    route="dian/xml/consultar",
    methods=["POST"],
    auth_level=func.AuthLevel.FUNCTION,
)
def dian_get_xml_poc(req: func.HttpRequest) -> func.HttpResponse:
    """Consulta un XML por CUFE sin persistir datos (prueba de concepto)."""
    try:
        payload = req.get_json()
    except ValueError:
        payload = None

    cufe = payload.get("cufe") if isinstance(payload, dict) else None
    if not isinstance(cufe, str) or not _is_valid_cufe(cufe):
        return _json_response(
            {
                "status": "REJECTED",
                "mode": "POC_NO_PERSISTENCE",
                "message": "Se requiere un CUFE SHA-384 de 96 caracteres hexadecimales.",
            },
            status_code=400,
        )

    normalized_cufe = cufe.strip().lower()
    try:
        result = run_dian_get_xml(normalized_cufe)
        return _json_response(result, status_code=200)
    except DianDocumentNotFoundError as error:
        logging.warning("La DIAN no devolvió XML para el CUFE solicitado.")
        return _json_response(
            {
                "status": "NOT_FOUND",
                "mode": "POC_NO_PERSISTENCE",
                "dianCode": error.code,
                "message": error.public_message,
            },
            status_code=404,
        )
    except DianConfigurationError:
        logging.exception("La prueba DIAN no está configurada correctamente.")
        return _json_response(
            {
                "status": "NOT_CONFIGURED",
                "mode": "POC_NO_PERSISTENCE",
                "message": "Falta configurar el certificado o los parámetros DIAN.",
            },
            status_code=503,
        )
    except DianServiceError:
        logging.exception("Falló la consulta SOAP a la DIAN.")
        return _json_response(
            {
                "status": "ERROR",
                "mode": "POC_NO_PERSISTENCE",
                "message": "No fue posible consultar el documento en la DIAN.",
            },
            status_code=502,
        )
    except Exception:
        logging.exception("Falló inesperadamente la prueba de consulta DIAN.")
        return _json_response(
            {
                "status": "ERROR",
                "mode": "POC_NO_PERSISTENCE",
                "message": "No fue posible completar la prueba DIAN.",
            },
            status_code=500,
        )


def _is_valid_cufe(value: str) -> bool:
    normalized = value.strip()
    return len(normalized) == 96 and all(
        character in "0123456789abcdefABCDEF" for character in normalized
    )


def _json_response(payload: dict, status_code: int) -> func.HttpResponse:
    return func.HttpResponse(
        json.dumps(payload, ensure_ascii=False),
        status_code=status_code,
        mimetype="application/json",
    )
