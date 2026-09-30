import os
from dataclasses import dataclass

from .errors import DianConfigurationError


DEFAULT_ENDPOINT = "https://vpfe.dian.gov.co/WcfDianCustomerServices.svc"
DEFAULT_ACTION = (
    "http://wcf.dian.colombia/"
    "IWcfDianCustomerServices/GetXmlByDocumentKey"
)


@dataclass(frozen=True)
class DianSettings:
    endpoint: str
    action: str
    request_timeout_seconds: float
    timestamp_ttl_seconds: int
    pfx_password: str
    pfx_path: str | None = None
    pfx_base64: str | None = None

    @classmethod
    def from_environment(cls):
        settings = cls(
            endpoint=os.environ.get("DIAN_ENDPOINT", DEFAULT_ENDPOINT).strip(),
            action=os.environ.get("DIAN_ACTION", DEFAULT_ACTION).strip(),
            request_timeout_seconds=_read_positive_float(
                "DIAN_REQUEST_TIMEOUT_SECONDS", "60"
            ),
            timestamp_ttl_seconds=_read_positive_int(
                "DIAN_TIMESTAMP_TTL_SECONDS", "60"
            ),
            pfx_password=os.environ.get("DIAN_PFX_PASSWORD", ""),
            pfx_path=_optional_environment("DIAN_PFX_PATH"),
            pfx_base64=_optional_environment("DIAN_PFX_BASE64"),
        )

        if not settings.endpoint.startswith("https://"):
            raise DianConfigurationError("DIAN_ENDPOINT debe utilizar HTTPS.")
        if not settings.action:
            raise DianConfigurationError("DIAN_ACTION no puede estar vac\u00edo.")
        if not settings.pfx_password:
            raise DianConfigurationError("Falta DIAN_PFX_PASSWORD.")
        if bool(settings.pfx_path) == bool(settings.pfx_base64):
            raise DianConfigurationError(
                "Configure exactamente una fuente: DIAN_PFX_PATH o DIAN_PFX_BASE64."
            )
        return settings


def _optional_environment(name: str) -> str | None:
    value = os.environ.get(name, "").strip()
    if not value or value.startswith("CONFIGURE_"):
        return None
    return value


def _read_positive_float(name: str, default: str) -> float:
    try:
        value = float(os.environ.get(name, default))
    except ValueError as error:
        raise DianConfigurationError(f"{name} debe ser num\u00e9rico.") from error
    if value <= 0:
        raise DianConfigurationError(f"{name} debe ser positivo.")
    return value


def _read_positive_int(name: str, default: str) -> int:
    try:
        value = int(os.environ.get(name, default))
    except ValueError as error:
        raise DianConfigurationError(f"{name} debe ser entero.") from error
    if value <= 0:
        raise DianConfigurationError(f"{name} debe ser positivo.")
    return value
