-- Reparacion unica para los 22 documentos de la carga 8 que fallaron por
-- DianConfigurationError. Ejecutar en la base Azure SQL de desarrollo.
-- El valor 0 impide cualquier escritura hasta que se cambie explicitamente a 1.
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ConfirmarEjecucion bit = 0;
DECLARE @ClienteID bigint = 9;
DECLARE @CargaArchivoID bigint = 8;
DECLARE @Esperados int = 22;

IF @ConfirmarEjecucion <> 1
    THROW 51020, 'Revise los 22 objetivos y cambie @ConfirmarEjecucion a 1 para ejecutar.', 1;

DECLARE @Objetivos TABLE
(
    DocumentoID bigint NOT NULL PRIMARY KEY,
    DocumentoVersionID bigint NOT NULL,
    ConsultaDianID bigint NOT NULL,
    CorrelationID uniqueidentifier NULL
);

INSERT INTO @Objetivos (DocumentoID, DocumentoVersionID, ConsultaDianID)
VALUES
    (12, 11,  9), (13, 12, 10), (14, 13, 11),
    (16, 15, 23), (17, 16, 19), (18, 17, 13),
    (19, 18, 15), (20, 19, 12), (21, 20, 18),
    (22, 21, 20), (23, 22, 17), (24, 23, 25),
    (25, 24, 21), (26, 25, 31), (27, 26, 26),
    (28, 27, 27), (29, 28, 28), (30, 29, 29),
    (31, 30, 30), (32, 31, 16), (33, 32, 22),
    (34, 33, 24);

IF (SELECT COUNT(*) FROM @Objetivos) <> @Esperados
    THROW 51021, 'La lista de objetivos no contiene exactamente 22 documentos.', 1;

UPDATE @Objetivos SET CorrelationID = NEWID();

DECLARE @Mensajes TABLE
(
    DocumentoID bigint NOT NULL PRIMARY KEY,
    ConsultaDianID bigint NOT NULL,
    MensajeParaCola nvarchar(max) NOT NULL
);
DECLARE @DocumentoID bigint;
DECLARE @UltimoDocumentoID bigint = 0;
DECLARE @Recurso nvarchar(255);
DECLARE @LockResult int;
DECLARE @Validos int;

BEGIN TRY
    BEGIN TRANSACTION;

    -- El consumidor usa este mismo bloqueo por documento.
    SELECT @DocumentoID = MIN(DocumentoID)
    FROM @Objetivos WHERE DocumentoID > @UltimoDocumentoID;

    WHILE @DocumentoID IS NOT NULL
    BEGIN
        SET @Recurso = CONCAT(N'dian:consulta-documento:', @DocumentoID);
        EXEC @LockResult = sys.sp_getapplock
            @Resource = @Recurso,
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult < 0
            THROW 51022, 'No se pudo bloquear uno de los documentos.', 1;

        SET @UltimoDocumentoID = @DocumentoID;
        SELECT @DocumentoID = MIN(DocumentoID)
        FROM @Objetivos WHERE DocumentoID > @UltimoDocumentoID;
    END;

    SELECT @Validos = COUNT(*)
    FROM @Objetivos AS o
    JOIN dian.Documento AS d WITH (UPDLOCK, HOLDLOCK)
      ON d.DocumentoID = o.DocumentoID
    JOIN dian.ConsultaDian AS c WITH (UPDLOCK, HOLDLOCK)
      ON c.ConsultaDianID = o.ConsultaDianID
     AND c.DocumentoID = d.DocumentoID
    JOIN dian.DocumentoVersion AS v
      ON v.DocumentoVersionID = o.DocumentoVersionID
     AND v.DocumentoID = d.DocumentoID
    WHERE d.ClienteID = @ClienteID
      AND d.UltimaCargaID = @CargaArchivoID
      AND d.EstadoProceso = 'ERROR'
      AND v.EsRevisionVigente = 1
      AND c.NumeroIntento = 1
      AND c.Estado = 'ERROR'
      AND c.ErrorTipo = N'DianConfigurationError'
      AND EXISTS
      (
          SELECT 1 FROM dian.CargaDocumento AS cd
          WHERE cd.CargaArchivoID = @CargaArchivoID
            AND cd.DocumentoID = d.DocumentoID
            AND cd.DocumentoVersionID = v.DocumentoVersionID
            AND cd.EsValida = 1
      )
      AND NOT EXISTS
      (
          SELECT 1 FROM dian.ConsultaDian AS posterior
          WHERE posterior.DocumentoID = d.DocumentoID
            AND posterior.NumeroIntento > 1
      )
      AND NOT EXISTS
      (
          SELECT 1 FROM dian.DocumentoXml AS x
          WHERE x.DocumentoID = d.DocumentoID
            AND x.EsVigente = 1
      );

    IF @Validos <> @Esperados
        THROW 51023, 'Alguno de los 22 documentos cambio; se revierte todo el lote.', 1;

    UPDATE d
    SET d.EstadoProceso = 'PENDIENTE_DESCARGA',
        d.FechaActualizacionUTC = SYSUTCDATETIME()
    FROM dian.Documento AS d
    JOIN @Objetivos AS o ON o.DocumentoID = d.DocumentoID
    WHERE d.EstadoProceso = 'ERROR';

    IF @@ROWCOUNT <> @Esperados
        THROW 51024, 'No se actualizaron exactamente 22 documentos.', 1;

    INSERT INTO dian.DocumentoProcesoHistorial
    (
        DocumentoID, CargaArchivoID, EstadoAnterior, EstadoNuevo,
        TipoEvento, Origen, Actor, DetalleJson
    )
    SELECT
        o.DocumentoID, @CargaArchivoID, 'ERROR', 'PENDIENTE_DESCARGA',
        'REINTENTO_MANUAL', 'USUARIO', SUSER_SNAME(),
        CONCAT(
            N'{"consultaDianId":', o.ConsultaDianID,
            N',"motivo":"certificado_corregido","correlationId":"',
            CONVERT(nvarchar(36), o.CorrelationID), N'"}'
        )
    FROM @Objetivos AS o;

    IF @@ROWCOUNT <> @Esperados
        THROW 51025, 'No se registraron exactamente 22 eventos de auditoria.', 1;

    INSERT INTO @Mensajes (DocumentoID, ConsultaDianID, MensajeParaCola)
    SELECT
        o.DocumentoID,
        o.ConsultaDianID,
        (
            SELECT
                1 AS [schemaVersion],
                CONVERT(varchar(36), o.CorrelationID) AS [correlationId],
                @ClienteID AS [clienteId],
                @CargaArchivoID AS [cargaArchivoId],
                o.DocumentoID AS [documentoId],
                o.DocumentoVersionID AS [documentoVersionId],
                d.TipoClave AS [tipoClave],
                RTRIM(d.ClaveDocumento) AS [claveDocumento]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        )
    FROM @Objetivos AS o
    JOIN dian.Documento AS d ON d.DocumentoID = o.DocumentoID;

    IF (SELECT COUNT(*) FROM @Mensajes) <> @Esperados
        THROW 51026, 'No se generaron exactamente 22 mensajes.', 1;

    COMMIT TRANSACTION;

    -- Exportar este resultado como JSON. Cada MensajeParaCola contiene el
    -- JSON interior que espera ProcesarDocumentoDian, sin codificar en Base64.
    SELECT DocumentoID, ConsultaDianID, MensajeParaCola
    FROM @Mensajes
    ORDER BY DocumentoID;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
