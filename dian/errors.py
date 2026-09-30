class DianServiceError(RuntimeError):
    """Error controlado durante una consulta a los servicios DIAN."""


class DianConfigurationError(DianServiceError):
    """La configuraci\u00f3n local o de Azure es incompleta o inv\u00e1lida."""


class DianTransportError(DianServiceError):
    """No fue posible transportar o interpretar la solicitud SOAP."""


class DianSoapFaultError(DianServiceError):
    """La DIAN respondi\u00f3 con un SOAP Fault."""


class DianDocumentNotFoundError(DianServiceError):
    def __init__(self, code: str | None, public_message: str):
        super().__init__(public_message)
        self.code = code
        self.public_message = public_message
