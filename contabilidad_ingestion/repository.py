from __future__ import annotations

from typing import Any

from dian_ingestion.sql_repository import SqlRepository

from .models import AccountingQueuedLoad, AccountingRow


class AccountingSqlRepository(SqlRepository):
    def start_load(
        self,
        message: AccountingQueuedLoad,
        file_hash: str,
        sheet_name: str,
        blob_uri: str,
        size: int,
    ) -> dict[str, Any]:
        return self._execute_one(
            """
EXEC [contabilidad].[sp_IniciarCargaContable]
    @ClienteID = ?, @FuenteContable = ?, @NombreArchivo = ?,
    @NombreHoja = ?, @BlobUri = ?, @TamanoBytes = ?,
    @HashArchivoSha256 = ?, @SharePointItemID = ?,
    @SharePointUrl = ?, @ETag = ?, @CargadoPor = ?;
""",
            (
                message.client_id,
                message.source,
                message.file_name,
                sheet_name,
                blob_uri,
                size,
                file_hash,
                message.sharepoint_item_id,
                message.sharepoint_url,
                message.etag,
                message.uploaded_by,
            ),
        )

    def register_movement(
        self, load_id: int, row: AccountingRow
    ) -> dict[str, Any]:
        return self._execute_one(
            """
EXEC [contabilidad].[sp_RegistrarMovimientoContable]
    @CargaArchivoID = ?, @FilaOrigen = ?, @FilaJson = ?;
""",
            (load_id, row.row_number, row.json_text),
        )

    def finish_load(self, load_id: int, row_count: int) -> dict[str, Any]:
        return self._execute_one(
            """
EXEC [contabilidad].[sp_FinalizarCargaContable]
    @CargaArchivoID = ?, @TotalFilasEsperadas = ?;
""",
            (load_id, row_count),
        )
