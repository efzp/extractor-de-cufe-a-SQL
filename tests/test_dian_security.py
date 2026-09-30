import base64
import unittest
from datetime import datetime, timedelta, timezone

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID

from dian.config import DEFAULT_ACTION, DEFAULT_ENDPOINT, DianSettings
from dian.errors import DianConfigurationError
from dian.security import load_pfx


class DianPfxTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.password = "test-password"
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
        pfx = pkcs12.serialize_key_and_certificates(
            name=b"dian-test",
            key=cls.private_key,
            cert=cls.certificate,
            cas=None,
            encryption_algorithm=serialization.BestAvailableEncryption(
                cls.password.encode("utf-8")
            ),
        )
        cls.pfx_base64 = base64.b64encode(pfx).decode("ascii")

    def make_settings(self, password=None):
        return DianSettings(
            endpoint=DEFAULT_ENDPOINT,
            action=DEFAULT_ACTION,
            request_timeout_seconds=60,
            timestamp_ttl_seconds=60,
            pfx_password=password or self.password,
            pfx_base64=self.pfx_base64,
        )

    def test_loads_encrypted_pfx_from_base64(self):
        private_key, certificate = load_pfx(self.make_settings())

        self.assertEqual(
            self.private_key.public_key().public_numbers(),
            private_key.public_key().public_numbers(),
        )
        self.assertEqual(self.certificate.serial_number, certificate.serial_number)

    def test_rejects_wrong_password_without_exposing_it(self):
        with self.assertRaises(DianConfigurationError) as context:
            load_pfx(self.make_settings(password="wrong-secret"))

        self.assertNotIn("wrong-secret", str(context.exception))


if __name__ == "__main__":
    unittest.main()
