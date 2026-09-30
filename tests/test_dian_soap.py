import base64
import hashlib
import unittest
from datetime import datetime, timedelta, timezone

from cryptography import x509
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.x509.oid import NameOID
from lxml import etree

from dian.config import DEFAULT_ACTION, DEFAULT_ENDPOINT
from dian.soap import (
    DS_NS,
    SOAP_NS,
    WSA_NS,
    WCF_NS,
    WSU_NS,
    build_get_xml_request,
)


class DianSoapRequestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.private_key = rsa.generate_private_key(
            public_exponent=65537,
            key_size=2048,
        )
        subject = x509.Name(
            [x509.NameAttribute(NameOID.COMMON_NAME, "Test Company 900000000")]
        )
        now = datetime.now(timezone.utc)
        cls.certificate = (
            x509.CertificateBuilder()
            .subject_name(subject)
            .issuer_name(subject)
            .public_key(cls.private_key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - timedelta(days=1))
            .not_valid_after(now + timedelta(days=1))
            .sign(cls.private_key, hashes.SHA256())
        )

    def test_builds_and_signs_get_xml_request(self):
        cufe = "a" * 96
        now = datetime(2026, 9, 30, 15, 0, tzinfo=timezone.utc)
        request = build_get_xml_request(
            cufe=cufe,
            endpoint=DEFAULT_ENDPOINT,
            action=DEFAULT_ACTION,
            timestamp_ttl_seconds=60,
            private_key=self.private_key,
            certificate=self.certificate,
            now=now,
        )
        root = etree.fromstring(request)
        namespaces = {
            "s": SOAP_NS,
            "a": WSA_NS,
            "wcf": WCF_NS,
            "u": WSU_NS,
            "ds": DS_NS,
        }

        self.assertEqual(
            DEFAULT_ACTION,
            root.xpath("string(/s:Envelope/s:Header/a:Action)", namespaces=namespaces),
        )
        self.assertEqual(
            DEFAULT_ENDPOINT,
            root.xpath("string(/s:Envelope/s:Header/a:To)", namespaces=namespaces),
        )
        self.assertEqual(
            cufe,
            root.xpath(
                "string(/s:Envelope/s:Body/wcf:GetXmlByDocumentKey/wcf:trackId)",
                namespaces=namespaces,
            ),
        )

        to_element = root.xpath(
            "/s:Envelope/s:Header/a:To", namespaces=namespaces
        )[0]
        to_id = to_element.get(f"{{{WSU_NS}}}Id")
        reference = root.xpath("//ds:Reference", namespaces=namespaces)[0]
        self.assertEqual(f"#{to_id}", reference.get("URI"))

        canonical_to = etree.tostring(
            to_element,
            method="c14n",
            exclusive=True,
            with_comments=False,
        )
        expected_digest = base64.b64encode(
            hashlib.sha256(canonical_to).digest()
        ).decode("ascii")
        self.assertEqual(
            expected_digest,
            root.xpath("string(//ds:DigestValue)", namespaces=namespaces),
        )

        signed_info = root.xpath("//ds:SignedInfo", namespaces=namespaces)[0]
        canonical_signed_info = etree.tostring(
            signed_info,
            method="c14n",
            exclusive=True,
            with_comments=False,
        )
        signature = base64.b64decode(
            root.xpath("string(//ds:SignatureValue)", namespaces=namespaces)
        )
        self.certificate.public_key().verify(
            signature,
            canonical_signed_info,
            padding.PKCS1v15(),
            hashes.SHA256(),
        )

        self.assertEqual(
            "2026-09-30T15:00:00.000Z",
            root.xpath("string(//u:Timestamp/u:Created)", namespaces=namespaces),
        )
        self.assertEqual(
            "2026-09-30T15:01:00.000Z",
            root.xpath("string(//u:Timestamp/u:Expires)", namespaces=namespaces),
        )
