import base64
from datetime import datetime, timezone
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization.pkcs12 import (
    load_key_and_certificates,
)

from .config import DianSettings
from .errors import DianConfigurationError


def load_pfx(settings: DianSettings):
    try:
        if settings.pfx_base64:
            pfx_bytes = base64.b64decode(
                "".join(settings.pfx_base64.split()), validate=True
            )
        else:
            pfx_path = Path(settings.pfx_path or "")
            pfx_bytes = pfx_path.read_bytes()
    except (OSError, ValueError) as error:
        raise DianConfigurationError(
            "No fue posible leer el certificado PFX configurado."
        ) from error

    try:
        private_key, certificate, _ = load_key_and_certificates(
            pfx_bytes,
            settings.pfx_password.encode("utf-8"),
        )
    except (TypeError, ValueError) as error:
        raise DianConfigurationError(
            "No fue posible abrir el PFX; revise el archivo y la contrase\u00f1a."
        ) from error

    if private_key is None or certificate is None:
        raise DianConfigurationError(
            "El PFX debe contener el certificado y su clave privada."
        )
    if not isinstance(private_key, rsa.RSAPrivateKey):
        raise DianConfigurationError("La prueba requiere un certificado con clave RSA.")

    _validate_certificate_dates(certificate)
    return private_key, certificate


def _validate_certificate_dates(certificate: x509.Certificate) -> None:
    now = datetime.now(timezone.utc)
    not_before = getattr(certificate, "not_valid_before_utc", None)
    not_after = getattr(certificate, "not_valid_after_utc", None)

    if not_before is None:
        not_before = certificate.not_valid_before.replace(tzinfo=timezone.utc)
    if not_after is None:
        not_after = certificate.not_valid_after.replace(tzinfo=timezone.utc)

    if now < not_before:
        raise DianConfigurationError("El certificado DIAN todav\u00eda no es v\u00e1lido.")
    if now > not_after:
        raise DianConfigurationError("El certificado DIAN est\u00e1 vencido.")
