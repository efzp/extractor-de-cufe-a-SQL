import base64
import unittest

from dian.client import DianSoapClient
from dian.errors import DianDocumentNotFoundError, DianSoapFaultError


class FakeResponse:
    def __init__(self, status_code: int, content: bytes):
        self.status_code = status_code
        self.content = content


class FakeSession:
    def __init__(self, response: FakeResponse):
        self.response = response
        self.calls = []

    def post(self, url, **kwargs):
        self.calls.append((url, kwargs))
        return self.response


class DianSoapClientTests(unittest.TestCase):
    def make_client(self, response):
        session = FakeSession(response)
        client = DianSoapClient(
            endpoint="https://example.test/service",
            action="urn:test-action",
            timeout_seconds=12,
            session=session,
        )
        return client, session

    def test_parses_successful_document(self):
        document = b"<?xml version='1.0'?><Invoice/>"
        encoded = base64.b64encode(document).decode("ascii")
        response_xml = f"""
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
                    xmlns:b="http://schemas.datacontract.org/2004/07/DianResponse">
          <s:Body>
            <GetXmlByDocumentKeyResponse>
              <GetXmlByDocumentKeyResult>
                <b:Code>Ok</b:Code>
                <b:Message>Documento encontrado</b:Message>
                <b:XmlBytesBase64>{encoded}</b:XmlBytesBase64>
              </GetXmlByDocumentKeyResult>
            </GetXmlByDocumentKeyResponse>
          </s:Body>
        </s:Envelope>
        """.encode("utf-8")
        client, session = self.make_client(FakeResponse(200, response_xml))

        result = client.get_xml(b"<request/>")

        self.assertEqual("Ok", result.code)
        self.assertEqual(document, result.xml_bytes)
        self.assertEqual(encoded, result.xml_base64)
        self.assertEqual(1, len(session.calls))
        _, kwargs = session.calls[0]
        self.assertEqual(12, kwargs["timeout"])
        self.assertIn('action="urn:test-action"', kwargs["headers"]["Content-Type"])

    def test_raises_not_found_when_response_has_no_document(self):
        response_xml = b"""
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
          <s:Body><Result><Code>90</Code><Message>TrackId no encontrado</Message></Result></s:Body>
        </s:Envelope>
        """
        client, _ = self.make_client(FakeResponse(200, response_xml))

        with self.assertRaises(DianDocumentNotFoundError) as context:
            client.get_xml(b"<request/>")

        self.assertEqual("90", context.exception.code)
        self.assertEqual("TrackId no encontrado", context.exception.public_message)

    def test_maps_soap_fault_without_exposing_remote_detail(self):
        fault_xml = b"""
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
          <s:Body><s:Fault><s:Reason><s:Text>private diagnostic</s:Text></s:Reason></s:Fault></s:Body>
        </s:Envelope>
        """
        client, _ = self.make_client(FakeResponse(500, fault_xml))

        with self.assertRaises(DianSoapFaultError) as context:
            client.get_xml(b"<request/>")

        self.assertNotIn("private", str(context.exception))
