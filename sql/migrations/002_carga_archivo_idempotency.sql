SET XACT_ABORT ON;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE [object_id] = OBJECT_ID(N'[dian].[CargaArchivo]')
      AND [name] = N'UX_DianCargaArchivo_SharePointVersion'
)
BEGIN
    CREATE UNIQUE INDEX [UX_DianCargaArchivo_SharePointVersion]
        ON [dian].[CargaArchivo]
        (
            [ClienteID],
            [SharePointItemID],
            [ETag]
        )
        WHERE [SharePointItemID] IS NOT NULL
          AND [ETag] IS NOT NULL;
END;
GO
