import json
import logging

import azure.functions as func

from dian.errors import (
    DianConfigurationError,
    DianDocumentNotFoundError,
    DianServiceError,
)
from dian.service import run_dian_get_xml


app = func.FunctionApp()


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
