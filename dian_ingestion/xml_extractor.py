"""Extracción determinista de Invoice/CreditNote UBL; nunca evalúa entidades externas."""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date
from decimal import Decimal, InvalidOperation

from lxml import etree


EXTRACTOR_VERSION = 1
CBC = "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2"
CAC = "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
NS = {"cbc": CBC, "cac": CAC}
ROOT_NS = {
    "Invoice": "urn:oasis:names:specification:ubl:schema:xsd:Invoice-2",
    "CreditNote": "urn:oasis:names:specification:ubl:schema:xsd:CreditNote-2",
}
CUFE_PATTERN = re.compile(r"[0-9a-f]{96}\Z")


class XmlExtractionError(ValueError):
    """El Blob no cumple el contrato de extracción; no publicar como procesado."""


@dataclass(frozen=True)
class ExtractedXml:
    header: dict
    lines: list[dict]


def _text(node: etree._Element, path: str) -> str | None:
    found = node.find(path, namespaces=NS)
    if found is None or found.text is None:
        return None
    return found.text.strip() or None


def _required(node: etree._Element, path: str, label: str) -> str:
    value = _text(node, path)
    if value is None:
        raise XmlExtractionError(f"Falta {label} en el XML.")
    return value


def _decimal(value: str | None, label: str, *, default: str | None = None) -> str:
    if value is None:
        if default is None:
            raise XmlExtractionError(f"Falta {label} en el XML.")
        value = default
    try:
        number = Decimal(value)
    except InvalidOperation as error:
        raise XmlExtractionError(f"{label} no es decimal válido.") from error
    if not number.is_finite() or abs(number) >= Decimal("100000000000000000000"):
        raise XmlExtractionError(f"{label} está fuera de rango.")
    if number.as_tuple().exponent < -18:
        raise XmlExtractionError(f"{label} tiene más de dieciocho decimales.")
    return format(number, "f")


def _amount(node: etree._Element, path: str, label: str, *, default: str | None = None) -> str:
    return _decimal(_text(node, path), label, default=default)


def _party(root: etree._Element, kind: str) -> tuple[str, str]:
    base = f"cac:Accounting{kind}Party/cac:Party"
    nit = _required(root, f"{base}/cac:PartyTaxScheme/cbc:CompanyID", f"NIT {kind}")
    name = _text(root, f"{base}/cac:PartyTaxScheme/cbc:RegistrationName") or _text(
        root, f"{base}/cac:PartyName/cbc:Name"
    )
    if not name:
        raise XmlExtractionError(f"Falta nombre {kind}.")
    return nit, name


def _legacy_extension_amount(root: etree._Element, name: str) -> str:
    nodes = root.xpath('//*[local-name()=$tag]', tag=name)
    return _decimal(nodes[0].text.strip() if nodes and nodes[0].text else None,
                    name, default="0")


def _check_currency(node: etree._Element, path: str, currency: str) -> None:
    amount = node.find(path, namespaces=NS)
    if amount is not None and amount.get("currencyID") not in (None, currency):
        raise XmlExtractionError(f"Divisa incoherente en {path}.")


def extract_ubl(content: bytes) -> ExtractedXml:
    if not content:
        raise XmlExtractionError("XML vacío.")
    try:
        parser = etree.XMLParser(resolve_entities=False, load_dtd=False, no_network=True,
                                 huge_tree=False, recover=False)
        root = etree.fromstring(content, parser=parser)
    except etree.XMLSyntaxError as error:
        raise XmlExtractionError("XML malformado.") from error
    if root.getroottree().docinfo.doctype:
        raise XmlExtractionError("XML con DTD no permitido.")
    kind = etree.QName(root).localname
    if etree.QName(root).namespace != ROOT_NS.get(kind):
        raise XmlExtractionError("Tipo o espacio de nombres UBL no compatible.")
    uuid = _required(root, "cbc:UUID", "UUID").lower()
    if not CUFE_PATTERN.fullmatch(uuid):
        raise XmlExtractionError("UUID/CUFE no tiene 96 caracteres hexadecimales.")
    invoice_id = _required(root, "cbc:ID", "ID")
    issue_date = _required(root, "cbc:IssueDate", "IssueDate")
    try:
        date.fromisoformat(issue_date)
    except ValueError as error:
        raise XmlExtractionError("IssueDate no es una fecha ISO válida.") from error
    supplier_nit, supplier_name = _party(root, "Supplier")
    customer_nit, customer_name = _party(root, "Customer")
    line_name = "InvoiceLine" if kind == "Invoice" else "CreditNoteLine"
    nodes = root.findall(f"cac:{line_name}", namespaces=NS)
    if not nodes:
        raise XmlExtractionError("El XML no tiene líneas.")
    count_text = _required(root, "cbc:LineCountNumeric", "LineCountNumeric")
    try:
        decimal_count = Decimal(count_text)
        if not decimal_count.is_finite() or decimal_count != decimal_count.to_integral_value():
            raise ValueError("non-integral")
        declared_count = int(decimal_count)
    except (ValueError, InvalidOperation) as error:
        raise XmlExtractionError("LineCountNumeric no es entero.") from error
    if declared_count != len(nodes):
        raise XmlExtractionError("LineCountNumeric no coincide con las líneas reales.")

    total_path = "cac:LegalMonetaryTotal"
    monetary = root.find(total_path, namespaces=NS)
    if monetary is None:
        raise XmlExtractionError("Falta LegalMonetaryTotal.")
    payable_node = monetary.find("cbc:PayableAmount", namespaces=NS)
    currency = payable_node.get("currencyID") if payable_node is not None else None
    if not currency:
        raise XmlExtractionError("Falta currencyID en PayableAmount.")
    for field in ("LineExtensionAmount", "TaxExclusiveAmount", "TaxInclusiveAmount",
                  "AllowanceTotalAmount", "ChargeTotalAmount"):
        _check_currency(monetary, f"cbc:{field}", currency)

    taxes = {"01": Decimal(0), "04": Decimal(0)}
    for subtotal in root.findall("cac:TaxTotal/cac:TaxSubtotal", namespaces=NS):
        _check_currency(subtotal, "cbc:TaxAmount", currency)
        scheme = _text(subtotal, "cac:TaxCategory/cac:TaxScheme/cbc:ID")
        if scheme in taxes:
            taxes[scheme] += Decimal(_amount(subtotal, "cbc:TaxAmount", "TaxSubtotal.TaxAmount"))

    lines = []
    for ordinal, line in enumerate(nodes, 1):
        quantity_tag = "InvoicedQuantity" if kind == "Invoice" else "CreditedQuantity"
        quantity_node = line.find(f"cbc:{quantity_tag}", namespaces=NS)
        _check_currency(line, "cbc:LineExtensionAmount", currency)
        _check_currency(line, "cac:Price/cbc:PriceAmount", currency)
        lines.append({
            "ordinal": ordinal,
            "lineId": _required(line, "cbc:ID", f"línea {ordinal}.ID"),
            "description": _text(line, "cac:Item/cbc:Description") or _text(line, "cac:Item/cbc:Name"),
            "standardCode": _text(line, "cac:Item/cac:StandardItemIdentification/cbc:ID"),
            "quantity": _decimal(quantity_node.text.strip() if quantity_node is not None and quantity_node.text else None,
                                 f"línea {ordinal}.cantidad"),
            "unitCode": quantity_node.get("unitCode") if quantity_node is not None else None,
            "price": _amount(line, "cac:Price/cbc:PriceAmount", f"línea {ordinal}.precio"),
            "lineAmount": _amount(line, "cbc:LineExtensionAmount", f"línea {ordinal}.importe"),
        })
    header = {
        "extractorVersion": EXTRACTOR_VERSION,
        "xmlType": kind,
        "uuid": uuid,
        "invoiceId": invoice_id,
        "issueDate": issue_date,
        "supplierNit": supplier_nit,
        "supplierName": supplier_name,
        "supplierCity": _text(root, "cac:AccountingSupplierParty/cac:Party/cac:PhysicalLocation/cac:Address/cbc:CityName")
        or _text(root, "cac:AccountingSupplierParty/cac:Party/cac:PartyTaxScheme/cac:RegistrationAddress/cbc:CityName"),
        "supplierTaxLevel": _text(root, "cac:AccountingSupplierParty/cac:Party/cac:PartyTaxScheme/cbc:TaxLevelCode"),
        "supplierTaxSchemeId": _text(root, "cac:AccountingSupplierParty/cac:Party/cac:PartyTaxScheme/cac:TaxScheme/cbc:ID"),
        "supplierTaxSchemeName": _text(root, "cac:AccountingSupplierParty/cac:Party/cac:PartyTaxScheme/cac:TaxScheme/cbc:Name"),
        "supplierIndustryCode": _text(root, "cac:AccountingSupplierParty/cac:Party/cbc:IndustryClassificationCode"),
        "customerNit": customer_nit,
        "customerName": customer_name,
        "currency": currency,
        "lineCount": declared_count,
        "lineExtensionAmount": _amount(monetary, "cbc:LineExtensionAmount", "LineExtensionAmount"),
        "taxExclusiveAmount": _amount(monetary, "cbc:TaxExclusiveAmount", "TaxExclusiveAmount"),
        "taxInclusiveAmount": _amount(monetary, "cbc:TaxInclusiveAmount", "TaxInclusiveAmount"),
        "payableAmount": _amount(monetary, "cbc:PayableAmount", "PayableAmount"),
        "ivaTotal": format(taxes["01"], "f"),
        "incTotal": format(taxes["04"], "f"),
        "allowanceTotal": _amount(monetary, "cbc:AllowanceTotalAmount", "AllowanceTotalAmount", default="0"),
        "chargeTotal": _amount(monetary, "cbc:ChargeTotalAmount", "ChargeTotalAmount", default="0"),
        "legacyDiscount": _legacy_extension_amount(root, "MntDctoCop"),
        "legacyCharge": _legacy_extension_amount(root, "MntRcgoCop"),
        "firstDescription": _text(nodes[0], "cac:Item/cbc:Description"),
    }
    limits = {
        "invoiceId": 100, "supplierNit": 20, "supplierName": 300,
        "supplierCity": 200, "supplierTaxLevel": 100,
        "supplierTaxSchemeId": 100, "supplierTaxSchemeName": 200,
        "supplierIndustryCode": 100, "customerNit": 20,
        "customerName": 300, "currency": 10, "firstDescription": 2000,
    }
    for field, limit in limits.items():
        if header[field] is not None and len(header[field]) > limit:
            raise XmlExtractionError(f"{field} excede la longitud SQL.")
    for line in lines:
        for field, limit in (("lineId", 100), ("standardCode", 100), ("unitCode", 20)):
            if line[field] is not None and len(line[field]) > limit:
                raise XmlExtractionError(f"{field} excede la longitud SQL.")
    return ExtractedXml(header=header, lines=lines)
