class IngestionError(Exception):
    """Error base de la ingestión de listados DIAN."""


class IngestionConfigurationError(IngestionError):
    """La configuración requerida no está disponible o no es válida."""


class SpreadsheetValidationError(IngestionError):
    """El archivo no cumple el contrato mínimo del listado DIAN."""


class IngestionPersistenceError(IngestionError):
    """No fue posible completar una operación de persistencia."""

