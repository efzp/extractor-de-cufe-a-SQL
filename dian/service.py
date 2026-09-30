from .client import DianSoapClient
from .config import DianSettings
from .security import load_pfx
from .soap import build_get_xml_request


def run_dian_get_xml(cufe: str, settings: DianSettings | None = None) -> dict:
    settings = settings or DianSettings.from_environment()
    private_key, certificate = load_pfx(settings)
    request_xml = build_get_xml_request(
        cufe=cufe,
        endpoint=settings.endpoint,
        action=settings.action,
        timestamp_ttl_seconds=settings.timestamp_ttl_seconds,
        private_key=private_key,
        certificate=certificate,
    )
    result = DianSoapClient(
        endpoint=settings.endpoint,
        action=settings.action,
        timeout_seconds=settings.request_timeout_seconds,
    ).get_xml(request_xml)

    return {
        "status": "OK",
        "mode": "POC_NO_PERSISTENCE",
        "cufe": cufe,
        "dianCode": result.code,
        "message": result.message,
        "contentType": "application/xml",
        "sizeBytes": len(result.xml_bytes),
        "xmlBase64": result.xml_base64,
    }
