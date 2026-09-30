import base64
import hashlib
import uuid
from datetime import datetime, timedelta, timezone

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from lxml import etree


SOAP_NS = "http://www.w3.org/2003/05/soap-envelope"
WSA_NS = "http://www.w3.org/2005/08/addressing"
WCF_NS = "http://wcf.dian.colombia"
WSSE_NS = (
    "http://docs.oasis-open.org/wss/2004/01/"
    "oasis-200401-wss-wssecurity-secext-1.0.xsd"
)
WSU_NS = (
    "http://docs.oasis-open.org/wss/2004/01/"
    "oasis-200401-wss-wssecurity-utility-1.0.xsd"
)
DS_NS = "http://www.w3.org/2000/09/xmldsig#"
X509_VALUE_TYPE = (
    "http://docs.oasis-open.org/wss/2004/01/"
    "oasis-200401-wss-x509-token-profile-1.0#X509v3"
)
BASE64_ENCODING_TYPE = (
    "http://docs.oasis-open.org/wss/2004/01/"
    "oasis-200401-wss-soap-message-security-1.0#Base64Binary"
)
EXCLUSIVE_C14N = "http://www.w3.org/2001/10/xml-exc-c14n#"
RSA_SHA256 = "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"
SHA256 = "http://www.w3.org/2001/04/xmlenc#sha256"
ANONYMOUS_REPLY = "http://www.w3.org/2005/08/addressing/anonymous"


def build_get_xml_request(
    *,
    cufe: str,
    endpoint: str,
    action: str,
    timestamp_ttl_seconds: int,
    private_key,
    certificate,
    now: datetime | None = None,
) -> bytes:
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    expires_at = now + timedelta(seconds=timestamp_ttl_seconds)

    nsmap = {
        "s": SOAP_NS,
        "a": WSA_NS,
        "wcf": WCF_NS,
        "o": WSSE_NS,
        "u": WSU_NS,
        "ds": DS_NS,
    }
    envelope = etree.Element(_qname(SOAP_NS, "Envelope"), nsmap=nsmap)
    header = etree.SubElement(envelope, _qname(SOAP_NS, "Header"))
    body = etree.SubElement(envelope, _qname(SOAP_NS, "Body"))

    action_element = etree.SubElement(header, _qname(WSA_NS, "Action"))
    action_element.set(_qname(SOAP_NS, "mustUnderstand"), "1")
    action_element.text = action

    message_id = etree.SubElement(header, _qname(WSA_NS, "MessageID"))
    message_id.text = f"urn:uuid:{uuid.uuid4()}"

    reply_to = etree.SubElement(header, _qname(WSA_NS, "ReplyTo"))
    reply_address = etree.SubElement(reply_to, _qname(WSA_NS, "Address"))
    reply_address.text = ANONYMOUS_REPLY

    to_id = f"ID-{uuid.uuid4()}"
    to_element = etree.SubElement(header, _qname(WSA_NS, "To"))
    to_element.set(_qname(SOAP_NS, "mustUnderstand"), "1")
    to_element.set(_qname(WSU_NS, "Id"), to_id)
    to_element.text = endpoint

    operation = etree.SubElement(body, _qname(WCF_NS, "GetXmlByDocumentKey"))
    track_id = etree.SubElement(operation, _qname(WCF_NS, "trackId"))
    track_id.text = cufe

    security = etree.SubElement(header, _qname(WSSE_NS, "Security"))
    security.set(_qname(SOAP_NS, "mustUnderstand"), "1")

    timestamp = etree.SubElement(security, _qname(WSU_NS, "Timestamp"))
    timestamp.set(_qname(WSU_NS, "Id"), f"TS-{uuid.uuid4()}")
    created = etree.SubElement(timestamp, _qname(WSU_NS, "Created"))
    created.text = _format_utc(now)
    expires = etree.SubElement(timestamp, _qname(WSU_NS, "Expires"))
    expires.text = _format_utc(expires_at)

    token_id = f"X509-{uuid.uuid4()}"
    binary_token = etree.SubElement(
        security, _qname(WSSE_NS, "BinarySecurityToken")
    )
    binary_token.set(_qname(WSU_NS, "Id"), token_id)
    binary_token.set("EncodingType", BASE64_ENCODING_TYPE)
    binary_token.set("ValueType", X509_VALUE_TYPE)
    binary_token.text = base64.b64encode(
        certificate.public_bytes(serialization.Encoding.DER)
    ).decode("ascii")

    signature = etree.SubElement(security, _qname(DS_NS, "Signature"))
    signature.set("Id", f"SIG-{uuid.uuid4()}")
    signed_info = etree.SubElement(signature, _qname(DS_NS, "SignedInfo"))

    canonicalization_method = etree.SubElement(
        signed_info, _qname(DS_NS, "CanonicalizationMethod")
    )
    canonicalization_method.set("Algorithm", EXCLUSIVE_C14N)
    signature_method = etree.SubElement(
        signed_info, _qname(DS_NS, "SignatureMethod")
    )
    signature_method.set("Algorithm", RSA_SHA256)

    reference = etree.SubElement(signed_info, _qname(DS_NS, "Reference"))
    reference.set("URI", f"#{to_id}")
    transforms = etree.SubElement(reference, _qname(DS_NS, "Transforms"))
    transform = etree.SubElement(transforms, _qname(DS_NS, "Transform"))
    transform.set("Algorithm", EXCLUSIVE_C14N)
    digest_method = etree.SubElement(reference, _qname(DS_NS, "DigestMethod"))
    digest_method.set("Algorithm", SHA256)
    digest_value = etree.SubElement(reference, _qname(DS_NS, "DigestValue"))
    digest_value.text = base64.b64encode(
        hashlib.sha256(_canonicalize(to_element)).digest()
    ).decode("ascii")

    signature_value = etree.SubElement(signature, _qname(DS_NS, "SignatureValue"))
    key_info = etree.SubElement(signature, _qname(DS_NS, "KeyInfo"))
    token_reference = etree.SubElement(
        key_info, _qname(WSSE_NS, "SecurityTokenReference")
    )
    certificate_reference = etree.SubElement(
        token_reference, _qname(WSSE_NS, "Reference")
    )
    certificate_reference.set("URI", f"#{token_id}")
    certificate_reference.set("ValueType", X509_VALUE_TYPE)

    signature_bytes = private_key.sign(
        _canonicalize(signed_info),
        padding.PKCS1v15(),
        hashes.SHA256(),
    )
    signature_value.text = base64.b64encode(signature_bytes).decode("ascii")

    return etree.tostring(
        envelope,
        xml_declaration=True,
        encoding="UTF-8",
        pretty_print=False,
    )


def _canonicalize(element) -> bytes:
    return etree.tostring(
        element,
        method="c14n",
        exclusive=True,
        with_comments=False,
    )


def _qname(namespace: str, name: str) -> str:
    return f"{{{namespace}}}{name}"


def _format_utc(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(
        timespec="milliseconds"
    ).replace("+00:00", "Z")
