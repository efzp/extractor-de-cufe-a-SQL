import base64
from dataclasses import dataclass

import requests
from lxml import etree

from .errors import (
    DianDocumentNotFoundError,
    DianSoapFaultError,
    DianTransportError,
)


@dataclass(frozen=True)
class DianDocument:
    code: str | None
    message: str | None
    xml_base64: str
    xml_bytes: bytes


class DianSoapClient:
    def __init__(self, endpoint: str, action: str, timeout_seconds: float, session=None):
        self.endpoint = endpoint
        self.action = action
        self.timeout_seconds = timeout_seconds
        self.session = session or requests.Session()

    def get_xml(self, soap_request: bytes) -> DianDocument:
        headers = {
            "Accept": "application/soap+xml",
            "Content-Type": (
                "application/soap+xml; charset=utf-8; "
                f'action="{self.action}"'
            ),
        }
        try:
            response = self.session.post(
                self.endpoint,
                data=soap_request,
                headers=headers,
                timeout=self.timeout_seconds,
            )
        except requests.RequestException as error:
            raise DianTransportError(
                "No fue posible establecer comunicaci\u00f3n con la DIAN."
            ) from error

        try:
            root = etree.fromstring(response.content)
        except etree.XMLSyntaxError as error:
            raise DianTransportError(
                f"La DIAN devolvi\u00f3 una respuesta no XML (HTTP {response.status_code})."
            ) from error

        fault = root.xpath(
            "string(//*[local-name()='Fault']"
            "//*[local-name()='Reason']/*[local-name()='Text'])"
        ).strip()
        if fault:
            raise DianSoapFaultError("La DIAN rechaz\u00f3 la seguridad o el SOAP enviado.")
        if response.status_code >= 400:
            raise DianTransportError(
                f"La DIAN respondi\u00f3 con HTTP {response.status_code}."
            )

        code = _first_text(root, "Code")
        message = _first_text(root, "Message")
        xml_base64 = _first_text(root, "XmlBytesBase64") or _first_text(
            root, "XmlBase64Bytes"
        )
        if not xml_base64:
            raise DianDocumentNotFoundError(
                code=code,
                public_message=message or "La DIAN no devolvi\u00f3 el XML solicitado.",
            )

        compact_base64 = "".join(xml_base64.split())
        try:
            xml_bytes = base64.b64decode(compact_base64, validate=True)
        except ValueError as error:
            raise DianTransportError(
                "La DIAN devolvi\u00f3 un documento Base64 inv\u00e1lido."
            ) from error
        if not xml_bytes:
            raise DianTransportError("La DIAN devolvi\u00f3 un documento vac\u00edo.")

        return DianDocument(
            code=code,
            message=message,
            xml_base64=compact_base64,
            xml_bytes=xml_bytes,
        )


def _first_text(root, local_name: str) -> str | None:
    values = root.xpath(f"//*[local-name()='{local_name}']/text()")
    if not values:
        return None
    value = str(values[0]).strip()
    return value or None
