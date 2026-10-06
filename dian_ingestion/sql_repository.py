from __future__ import annotations

import struct
from typing import Any

from .config import IngestionSettings
from .errors import IngestionPersistenceError
from .models import NormalizedDocumentRow, QueuedLoad
from .document_message import QueuedDocument


SQL_COPT_SS_ACCESS_TOKEN = 1256


class SqlRepository:
    def __init__(
        self,
        settings: IngestionSettings,
        credential=None,
        connector=None,
    ):
        self._settings = settings
        self._credential = credential
        self._connector = connector
        self._connection = None

    def __enter__(self) -> "SqlRepository":
        self.open()
        return self

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        self.close()

    def open(self) -> None:
        if self._connection is not None:
            return

        if self._credential is None:
            from azure.identity import DefaultAzureCredential

            self._credential = DefaultAzureCredential(
                exclude_interactive_browser_credential=True
            )
        if self._connector is None:
            import pyodbc

            self._connector = pyodbc.connect

        access_token = self._credential.get_token(
            "https://database.windows.net/.default"
        ).token
        token_bytes = access_token.encode("utf-16-le")
        token_struct = struct.pack("=i", len(token_bytes)) + token_bytes
        connection_string = (
            f"DRIVER={{{self._settings.sql_driver}}};"
            f"SERVER=tcp:{self._settings.sql_server},1433;"
            f"DATABASE={self._settings.sql_database};"
            "Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"
        )

        try:
            self._connection = self._connector(
                connection_string,
                attrs_before={SQL_COPT_SS_ACCESS_TOKEN: token_struct},
                autocommit=True,
            )
        except Exception as error:
            raise IngestionPersistenceError(
                "No fue posible conectar con Azure SQL."
            ) from error

    def close(self) -> None:
        if self._connection is not None:
            self._connection.close()
            self._connection = None

    def start_load(
        self,
        message: QueuedLoad,
        file_hash: str,
        table_name: str,
    ) -> dict[str, Any]:
        return self._execute_one(
            """
EXEC [dian].[sp_IniciarCargaArchivo]
    @ClienteID = ?,
    @NombreArchivo = ?,
    @HashArchivoSha256 = ?,
    @SharePointItemID = ?,
    @SharePointUrl = ?,
    @ETag = ?,
    @NombreTablaOrigen = ?,
    @CargadoPor = ?;
""",
            (
                message.client_id,
                message.file_name,
                file_hash,
                message.sharepoint_item_id,
                message.sharepoint_url,
                message.etag,
                table_name,
                message.uploaded_by,
            ),
        )

    def register_document(
        self,
        load_id: int,
        row: NormalizedDocumentRow,
    ) -> dict[str, Any]:
        values = row.values
        return self._execute_one(
            """
EXEC [dian].[sp_RegistrarDocumentoCarga]
    @CargaArchivoID = ?, @FilaOrigen = ?, @ClaveDocumento = ?,
    @TipoClave = ?, @TipoDocumento = ?, @Folio = ?, @Prefijo = ?,
    @Divisa = ?, @FormaPago = ?, @MedioPago = ?, @FechaEmision = ?,
    @FechaRecepcion = ?, @NitEmisor = ?, @NombreEmisor = ?,
    @NitReceptor = ?, @NombreReceptor = ?, @Iva = ?, @Ica = ?,
    @Ic = ?, @Inc = ?, @Timbre = ?, @IncBolsas = ?, @InCarbono = ?,
    @InCombustibles = ?, @IcDatos = ?, @Icl = ?, @Inpp = ?,
    @Ibua = ?, @Icui = ?, @ReteIva = ?, @ReteRenta = ?,
    @ReteIca = ?, @Total = ?, @EstadoDianOrigen = ?, @GrupoOrigen = ?,
    @HashFilaSha256 = ?, @HashContenidoSha256 = ?, @FilaOrigenJson = ?;
""",
            (
                load_id,
                row.row_number,
                row.document_key,
                row.key_type,
                values.get("tipo_documento"),
                values.get("folio"),
                values.get("prefijo"),
                values.get("divisa"),
                values.get("forma_pago"),
                values.get("medio_pago"),
                values.get("fecha_emision"),
                values.get("fecha_recepcion"),
                values.get("nit_emisor"),
                values.get("nombre_emisor"),
                values.get("nit_receptor"),
                values.get("nombre_receptor"),
                values.get("iva"),
                values.get("ica"),
                values.get("ic"),
                values.get("inc"),
                values.get("timbre"),
                values.get("inc_bolsas"),
                values.get("in_carbono"),
                values.get("in_combustibles"),
                values.get("ic_datos"),
                values.get("icl"),
                values.get("inpp"),
                values.get("ibua"),
                values.get("icui"),
                values.get("rete_iva"),
                values.get("rete_renta"),
                values.get("rete_ica"),
                values.get("total"),
                values.get("estado_dian"),
                values.get("grupo"),
                row.row_hash,
                row.content_hash,
                row.original_json,
            ),
        )

    def finish_load(
        self,
        load_id: int,
        total_rows: int,
        message: str | None = None,
    ) -> dict[str, Any]:
        return self._execute_one(
            """
EXEC [dian].[sp_FinalizarCargaArchivo]
    @CargaArchivoID = ?,
    @TotalFilasEsperadas = ?,
    @Mensaje = ?;
""",
            (load_id, total_rows, message),
        )

    def start_document(
        self, message: QueuedDocument, max_attempts: int, claim_timeout_seconds: int
    ) -> dict[str, Any]:
        return self._execute_one(
            """
EXEC [dian].[sp_IniciarConsultaDocumento]
    @DocumentoID = ?, @ClienteID = ?, @CargaArchivoID = ?,
    @DocumentoVersionID = ?, @ClaveDocumento = ?,
    @MaximoIntentos = ?, @TiempoReclamoSegundos = ?;
""",
            (
                message.document_id, message.client_id, message.load_id,
                message.version_id, message.document_key,
                max_attempts, claim_timeout_seconds,
            ),
        )

    def register_xml(
        self, document_id: int, consultation_id: int, uri: str,
        digest: str, size: int, xml_type: str | None,
    ) -> dict[str, Any]:
        return self._execute_one(
            """
EXEC [dian].[sp_RegistrarXmlDocumento]
    @DocumentoID = ?, @ConsultaDianID = ?, @BlobUri = ?,
    @HashXmlSha256 = ?, @TamanoBytes = ?, @TipoXmlDetectado = ?;
""",
            (document_id, consultation_id, uri, digest, size, xml_type),
        )

    def finish_document(
        self, consultation_id: int, result: str, max_attempts: int,
        *, dian_code: str | None = None, error_type: str | None = None,
        duration_ms: int | None = None,
    ) -> dict[str, Any]:
        return self._execute_one(
            """
EXEC [dian].[sp_FinalizarConsultaDocumento]
    @ConsultaDianID = ?, @Resultado = ?, @CodigoDian = ?,
    @DuracionMs = ?, @ErrorTipo = ?, @MaximoIntentos = ?;
""",
            (
                consultation_id, result, dian_code, duration_ms,
                error_type, max_attempts,
            ),
        )

    def get_xml_for_extraction(self, xml_id: int) -> dict[str, Any]:
        return self._execute_one(
            "EXEC [dian].[sp_ObtenerXmlParaExtraccion] @DocumentoXmlID = ?, @VersionExtractor = ?;",
            (xml_id, 1),
        )

    def list_pending_xml_extractions(self, limit: int, version: int) -> list[dict[str, Any]]:
        return self._execute_rows(
            "EXEC [dian].[sp_ListarXmlPendientesExtraccion] @Limite = ?, @VersionExtractor = ?;",
            (limit, version),
        )

    def save_xml_extraction(self, xml_id: int, header_json: str,
                            lines_json: str) -> dict[str, Any]:
        return self._execute_one(
            "EXEC [dian].[sp_RegistrarExtraccionXml] @DocumentoXmlID = ?, "
            "@CabeceraJson = ?, @LineasJson = ?;",
            (xml_id, header_json, lines_json),
        )

    def record_xml_extraction_error(self, xml_id: int, version: int,
                                    code: str, detail: str) -> dict[str, Any]:
        return self._execute_one(
            "EXEC [dian].[sp_RegistrarErrorExtraccionXml] @DocumentoXmlID = ?, "
            "@VersionExtractor = ?, @Codigo = ?, @Detalle = ?;",
            (xml_id, version, code, detail),
        )

    def _execute_rows(self, sql: str, parameters: tuple[Any, ...]) -> list[dict[str, Any]]:
        if self._connection is None:
            raise IngestionPersistenceError("La conexión SQL no está abierta.")
        cursor = self._connection.cursor()
        try:
            cursor.execute(sql, parameters)
            if cursor.description is None:
                raise IngestionPersistenceError("El procedimiento no devolvió columnas.")
            columns = [column[0] for column in cursor.description]
            return [dict(zip(columns, row)) for row in cursor.fetchall()]
        except IngestionPersistenceError:
            raise
        except Exception as error:
            raise IngestionPersistenceError("Falló una consulta del repositorio DIAN.") from error
        finally:
            cursor.close()

    def _execute_one(self, sql: str, parameters: tuple[Any, ...]) -> dict[str, Any]:
        if self._connection is None:
            raise IngestionPersistenceError("La conexión SQL no está abierta.")

        cursor = self._connection.cursor()
        try:
            cursor.execute(sql, parameters)
            row = cursor.fetchone()
            if row is None or cursor.description is None:
                raise IngestionPersistenceError(
                    "El procedimiento no devolvió el resultado esperado."
                )
            columns = [description[0] for description in cursor.description]
            return dict(zip(columns, row))
        except IngestionPersistenceError:
            raise
        except Exception as error:
            raise IngestionPersistenceError(
                "Falló una operación del repositorio DIAN."
            ) from error
        finally:
            cursor.close()
