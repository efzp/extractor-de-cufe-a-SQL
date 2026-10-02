-- Ejecutar despues de instalar los tres procedimientos nuevos.
-- Todos los datos de prueba se revierten, incluso si una asercion falla.
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @Nit nvarchar(20) = CONCAT(
        N'T', LEFT(REPLACE(CONVERT(nvarchar(36), NEWID()), N'-', N''), 19)
    );
    DECLARE @Semilla varchar(32) = LOWER(
        REPLACE(CONVERT(varchar(36), NEWID()), '-', '')
    );
    DECLARE @ClienteID bigint;
    DECLARE @CargaArchivoID bigint;
    DECLARE @DocumentoID bigint;
    DECLARE @DocumentoVersionID bigint;
    DECLARE @Clave char(96);
    DECLARE @ConsultaDianID bigint;
    DECLARE @ConsultaAnteriorID bigint;
    DECLARE @HashXml char(64) = REPLICATE('1', 64);
    DECLARE @BlobUri nvarchar(1000);

    DECLARE @Fixture TABLE
    (
        [Numero] int NOT NULL PRIMARY KEY,
        [Clave] char(96) NOT NULL UNIQUE
    );

    DECLARE @Documentos TABLE
    (
        [Numero] int NULL,
        [DocumentoID] bigint NOT NULL PRIMARY KEY,
        [Clave] char(96) NOT NULL UNIQUE,
        [DocumentoVersionID] bigint NULL
    );

    DECLARE @Inicio TABLE
    (
        [DocumentoID] bigint,
        [ClienteID] bigint,
        [ClaveDocumento] char(96),
        [ConsultaDianID] bigint NULL,
        [NumeroIntento] int NULL,
        [EstadoProceso] varchar(30),
        [Resultado] varchar(30),
        [DebeConsultar] bit
    );

    DECLARE @Xml TABLE
    (
        [DocumentoXmlID] bigint,
        [DocumentoID] bigint,
        [ConsultaDianID] bigint,
        [HashXmlSha256] varchar(128),
        [Resultado] varchar(30)
    );

    DECLARE @Fin TABLE
    (
        [ConsultaDianID] bigint,
        [DocumentoID] bigint,
        [NumeroIntento] smallint,
        [Resultado] varchar(20),
        [EstadoProceso] varchar(30),
        [Reintentar] bit,
        [Operacion] varchar(20)
    );

    INSERT INTO @Fixture ([Numero], [Clave])
    VALUES
        (1, REPLICATE('a', 64) + @Semilla),
        (2, REPLICATE('b', 64) + @Semilla),
        (3, REPLICATE('c', 64) + @Semilla),
        (4, REPLICATE('d', 64) + @Semilla),
        (5, REPLICATE('e', 64) + @Semilla),
        (6, REPLICATE('f', 64) + @Semilla);

    INSERT INTO [dian].[Cliente] ([Nit], [RazonSocial])
    VALUES (@Nit, N'Prueba transaccional de consulta DIAN');
    SET @ClienteID = SCOPE_IDENTITY();

    INSERT INTO [dian].[CargaArchivo]
        ([ClienteID], [NombreArchivo], [HashArchivoSha256], [Estado])
    VALUES
        (@ClienteID, N'prueba-consulta-dian.xlsx',
         REPLICATE('f', 64), 'OK');
    SET @CargaArchivoID = SCOPE_IDENTITY();

    INSERT INTO [dian].[Documento]
    (
        [ClienteID], [ClaveDocumento], [TipoClave], [TipoDocumento],
        [EstadoProceso], [PrimeraCargaID], [UltimaCargaID]
    )
    OUTPUT inserted.[DocumentoID], inserted.[ClaveDocumento]
        INTO @Documentos ([DocumentoID], [Clave])
    SELECT
        @ClienteID, [Clave], 'CUFE', N'Factura electronica',
        'PENDIENTE_DESCARGA', @CargaArchivoID, @CargaArchivoID
    FROM @Fixture;

    UPDATE d
    SET [Numero] = f.[Numero]
    FROM @Documentos AS d
    JOIN @Fixture AS f ON f.[Clave] = d.[Clave];

    INSERT INTO [dian].[DocumentoVersion]
    (
        [DocumentoID], [NumeroRevision], [HashContenidoSha256],
        [TipoDocumentoOrigen], [Folio], [FechaEmision], [FechaRecepcion],
        [NitEmisor], [NombreEmisor], [NitReceptor], [NombreReceptor],
        [Total], [EstadoDianOrigen], [GrupoOrigen],
        [EsRevisionVigente], [CargaCreacionID]
    )
    SELECT
        d.[DocumentoID], 1,
        LOWER(CONVERT(char(64), HASHBYTES(
            'SHA2_256', CONVERT(varchar(20), d.[DocumentoID])
        ), 2)),
        N'Factura electronica',
        CONCAT(N'FV-', d.[Numero]),
        '2026-09-01', '2026-09-02T10:30:00',
        N'900111222', N'Proveedor de prueba',
        @Nit, N'Cliente de prueba',
        100.0000, N'Aceptado', N'Recibidos',
        1, @CargaArchivoID
    FROM @Documentos AS d;

    UPDATE d
    SET [DocumentoVersionID] = v.[DocumentoVersionID]
    FROM @Documentos AS d
    JOIN [dian].[DocumentoVersion] AS v
        ON v.[DocumentoID] = d.[DocumentoID]
       AND v.[NumeroRevision] = 1;

    INSERT INTO [dian].[CargaDocumento]
    (
        [CargaArchivoID], [FilaOrigen], [DocumentoID],
        [DocumentoVersionID], [HashFilaSha256],
        [FilaOrigenJson], [EsValida], [Resultado]
    )
    SELECT
        @CargaArchivoID, d.[Numero] + 1,
        d.[DocumentoID], d.[DocumentoVersionID],
        LOWER(CONVERT(char(64), HASHBYTES(
            'SHA2_256', CONCAT('fila-', d.[DocumentoID])
        ), 2)),
        CONCAT(N'{"fixture":', d.[Numero], N'}'), 1, 'NUEVO'
    FROM @Documentos AS d;

    -- Caso 1: reclamo, entrega repetida, registro XML y finalizacion idempotente.
    SELECT @DocumentoID = [DocumentoID],
           @DocumentoVersionID = [DocumentoVersionID],
           @Clave = [Clave]
    FROM @Documentos WHERE [Numero] = 1;

    INSERT INTO @Inicio
    EXEC [dian].[sp_IniciarConsultaDocumento]
        @DocumentoID = @DocumentoID,
        @ClienteID = @ClienteID,
        @CargaArchivoID = @CargaArchivoID,
        @DocumentoVersionID = @DocumentoVersionID,
        @ClaveDocumento = @Clave;

    SELECT @ConsultaDianID = [ConsultaDianID] FROM @Inicio;

    IF NOT EXISTS
    (
        SELECT 1 FROM @Inicio
        WHERE [Resultado] = 'CONSULTA_INICIADA'
          AND [DebeConsultar] = 1
          AND [NumeroIntento] = 1
          AND [EstadoProceso] = 'CONSULTANDO_DIAN'
    )
        THROW 51401, 'El primer reclamo no inicio la consulta.', 1;

    DELETE FROM @Inicio;
    INSERT INTO @Inicio
    EXEC [dian].[sp_IniciarConsultaDocumento]
        @DocumentoID = @DocumentoID,
        @ClienteID = @ClienteID,
        @CargaArchivoID = @CargaArchivoID,
        @DocumentoVersionID = @DocumentoVersionID,
        @ClaveDocumento = @Clave;

    IF NOT EXISTS
    (
        SELECT 1 FROM @Inicio
        WHERE [Resultado] = 'CONSULTA_EN_PROGRESO'
          AND [DebeConsultar] = 0
          AND [ConsultaDianID] = @ConsultaDianID
    )
       OR (SELECT COUNT(*) FROM [dian].[ConsultaDian]
           WHERE [DocumentoID] = @DocumentoID) <> 1
        THROW 51402, 'La entrega repetida inicio otra consulta.', 1;

    SET @BlobUri = CONCAT(
        N'https://stdianxmlcpabaasdev.blob.core.windows.net/',
        N'xml-dian/clientes/', @ClienteID,
        N'/documentos/', @DocumentoID,
        N'/', @HashXml, N'.xml'
    );

    INSERT INTO @Xml
    EXEC [dian].[sp_RegistrarXmlDocumento]
        @DocumentoID = @DocumentoID,
        @ConsultaDianID = @ConsultaDianID,
        @BlobUri = @BlobUri,
        @HashXmlSha256 = @HashXml,
        @TamanoBytes = 25,
        @TipoXmlDetectado = N'Invoice';

    IF NOT EXISTS
    (
        SELECT 1 FROM @Xml WHERE [Resultado] = 'XML_REGISTRADO'
    )
        THROW 51403, 'El XML no fue registrado.', 1;

    DELETE FROM @Xml;
    INSERT INTO @Xml
    EXEC [dian].[sp_RegistrarXmlDocumento]
        @DocumentoID = @DocumentoID,
        @ConsultaDianID = @ConsultaDianID,
        @BlobUri = @BlobUri,
        @HashXmlSha256 = @HashXml,
        @TamanoBytes = 25,
        @TipoXmlDetectado = N'Invoice';

    IF NOT EXISTS
    (
        SELECT 1 FROM @Xml WHERE [Resultado] = 'XML_EXISTENTE'
    )
       OR (SELECT COUNT(*) FROM [dian].[DocumentoXml]
           WHERE [DocumentoID] = @DocumentoID) <> 1
        THROW 51404, 'El registro XML repetido no fue idempotente.', 1;

    INSERT INTO @Fin
    EXEC [dian].[sp_FinalizarConsultaDocumento]
        @ConsultaDianID = @ConsultaDianID,
        @Resultado = 'OK',
        @CodigoDian = N'Ok',
        @DuracionMs = 100;

    IF NOT EXISTS
    (
        SELECT 1 FROM @Fin
        WHERE [Resultado] = 'OK'
          AND [EstadoProceso] = 'XML_DESCARGADO'
          AND [Reintentar] = 0
          AND [Operacion] = 'FINALIZADA'
    )
        THROW 51405, 'La consulta exitosa no finalizo correctamente.', 1;

    DELETE FROM @Fin;
    INSERT INTO @Fin
    EXEC [dian].[sp_FinalizarConsultaDocumento]
        @ConsultaDianID = @ConsultaDianID,
        @Resultado = 'OK';

    IF NOT EXISTS
    (
        SELECT 1 FROM @Fin WHERE [Operacion] = 'YA_FINALIZADA'
    )
        THROW 51406, 'La finalizacion repetida no fue idempotente.', 1;

    DELETE FROM @Inicio;
    INSERT INTO @Inicio
    EXEC [dian].[sp_IniciarConsultaDocumento]
        @DocumentoID = @DocumentoID,
        @ClienteID = @ClienteID,
        @CargaArchivoID = @CargaArchivoID,
        @DocumentoVersionID = @DocumentoVersionID,
        @ClaveDocumento = @Clave;

    IF NOT EXISTS
    (
        SELECT 1 FROM @Inicio
        WHERE [Resultado] = 'XML_YA_REGISTRADO'
          AND [DebeConsultar] = 0
    )
       OR (SELECT COUNT(*) FROM [dian].[ConsultaDian]
           WHERE [DocumentoID] = @DocumentoID) <> 1
        THROW 51407, 'Se intento descargar un XML ya registrado.', 1;

    -- Caso 2: CUFE no encontrado; no debe generar un segundo intento.
    SELECT @DocumentoID = [DocumentoID],
           @DocumentoVersionID = [DocumentoVersionID],
           @Clave = [Clave]
    FROM @Documentos WHERE [Numero] = 2;

    DELETE FROM @Inicio;
    INSERT INTO @Inicio
    EXEC [dian].[sp_IniciarConsultaDocumento]
        @DocumentoID = @DocumentoID,
        @ClienteID = @ClienteID,
        @CargaArchivoID = @CargaArchivoID,
        @DocumentoVersionID = @DocumentoVersionID,
        @ClaveDocumento = @Clave;
    SELECT @ConsultaDianID = [ConsultaDianID] FROM @Inicio;

    DELETE FROM @Fin;
    INSERT INTO @Fin
    EXEC [dian].[sp_FinalizarConsultaDocumento]
        @ConsultaDianID = @ConsultaDianID,
        @Resultado = 'NO_ENCONTRADO',
        @CodigoDian = N'90';

    IF NOT EXISTS
    (
        SELECT 1 FROM @Fin
        WHERE [Resultado] = 'NO_ENCONTRADO'
          AND [EstadoProceso] = 'NO_ENCONTRADO'
          AND [Reintentar] = 0
    )
        THROW 51408, 'NO_ENCONTRADO no quedo terminal.', 1;

    DELETE FROM @Inicio;
    INSERT INTO @Inicio
    EXEC [dian].[sp_IniciarConsultaDocumento]
        @DocumentoID = @DocumentoID,
        @ClienteID = @ClienteID,
        @CargaArchivoID = @CargaArchivoID,
        @DocumentoVersionID = @DocumentoVersionID,
        @ClaveDocumento = @Clave;

    IF NOT EXISTS
    (
        SELECT 1 FROM @Inicio
        WHERE [Resultado] = 'ESTADO_NO_ELEGIBLE'
          AND [DebeConsultar] = 0
    )
        THROW 51409, 'NO_ENCONTRADO inicio otra consulta.', 1;

    -- Caso 3: reintento transitorio y limite de dos intentos.
    SELECT @DocumentoID = [DocumentoID],
           @DocumentoVersionID = [DocumentoVersionID],
           @Clave = [Clave]
    FROM @Documentos WHERE [Numero] = 3;

    DELETE FROM @Inicio;
    INSERT INTO @Inicio
    EXEC [dian].[sp_IniciarConsultaDocumento]
        @DocumentoID = @DocumentoID,
        @ClienteID = @ClienteID,
        @CargaArchivoID = @CargaArchivoID,
        @DocumentoVersionID = @DocumentoVersionID,
        @ClaveDocumento = @Clave,
        @MaximoIntentos = 2;
    SELECT @ConsultaDianID = [ConsultaDianID] FROM @Inicio;

    DELETE FROM @Fin;
    INSERT INTO @Fin
    EXEC [dian].[sp_FinalizarConsultaDocumento]
        @ConsultaDianID = @ConsultaDianID,
        @Resultado = 'REINTENTO',
        @ErrorTipo = N'DianTransportError',
        @MaximoIntentos = 2;

    IF NOT EXISTS
    (
        SELECT 1 FROM @Fin
        WHERE [Resultado] = 'REINTENTO'
          AND [EstadoProceso] = 'PENDIENTE_DESCARGA'
          AND [Reintentar] = 1
    )
        THROW 51410, 'El error transitorio no permitio reintento.', 1;

    DELETE FROM @Inicio;
    INSERT INTO @Inicio
    EXEC [dian].[sp_IniciarConsultaDocumento]
        @DocumentoID = @DocumentoID,
        @ClienteID = @ClienteID,
        @CargaArchivoID = @CargaArchivoID,
        @DocumentoVersionID = @DocumentoVersionID,
        @ClaveDocumento = @Clave,
        @MaximoIntentos = 2;
    SELECT @ConsultaDianID = [ConsultaDianID] FROM @Inicio;

    IF NOT EXISTS
    (
        SELECT 1 FROM @Inicio
        WHERE [NumeroIntento] = 2 AND [DebeConsultar] = 1
    )
        THROW 51411, 'El segundo intento no fue reclamado.', 1;

    DELETE FROM @Fin;
    INSERT INTO @Fin
    EXEC [dian].[sp_FinalizarConsultaDocumento]
        @ConsultaDianID = @ConsultaDianID,
        @Resultado = 'REINTENTO',
        @MaximoIntentos = 2;

    IF NOT EXISTS
    (
        SELECT 1 FROM @Fin
        WHERE [Resultado] = 'ERROR'
          AND [EstadoProceso] = 'ERROR'
          AND [Reintentar] = 0
    )
        THROW 51412, 'No se detuvo al alcanzar el maximo.', 1;

    -- Caso 4: un reclamo vencido se cierra y se reemplaza con otro intento.
    SELECT @DocumentoID = [DocumentoID],
           @DocumentoVersionID = [DocumentoVersionID],
           @Clave = [Clave]
    FROM @Documentos WHERE [Numero] = 4;

    DELETE FROM @Inicio;
    INSERT INTO @Inicio
    EXEC [dian].[sp_IniciarConsultaDocumento]
        @DocumentoID = @DocumentoID,
        @ClienteID = @ClienteID,
        @CargaArchivoID = @CargaArchivoID,
        @DocumentoVersionID = @DocumentoVersionID,
        @ClaveDocumento = @Clave;
    SELECT @ConsultaAnteriorID = [ConsultaDianID] FROM @Inicio;

    UPDATE [dian].[ConsultaDian]
    SET [FechaInicioUTC] = DATEADD(second, -600, SYSUTCDATETIME())
    WHERE [ConsultaDianID] = @ConsultaAnteriorID;

    DELETE FROM @Inicio;
    INSERT INTO @Inicio
    EXEC [dian].[sp_IniciarConsultaDocumento]
        @DocumentoID = @DocumentoID,
        @ClienteID = @ClienteID,
        @CargaArchivoID = @CargaArchivoID,
        @DocumentoVersionID = @DocumentoVersionID,
        @ClaveDocumento = @Clave,
        @TiempoReclamoSegundos = 540;
    SELECT @ConsultaDianID = [ConsultaDianID] FROM @Inicio;

    IF NOT EXISTS
    (
        SELECT 1 FROM @Inicio
        WHERE [Resultado] = 'CONSULTA_INICIADA'
          AND [NumeroIntento] = 2
          AND [DebeConsultar] = 1
    )
       OR NOT EXISTS
    (
        SELECT 1 FROM [dian].[ConsultaDian]
        WHERE [ConsultaDianID] = @ConsultaAnteriorID
          AND [Estado] = 'REINTENTO'
          AND [ErrorTipo] = N'RECLAMO_EXPIRADO'
    )
        THROW 51413, 'El reclamo vencido no fue recuperado.', 1;

    DELETE FROM @Fin;
    INSERT INTO @Fin
    EXEC [dian].[sp_FinalizarConsultaDocumento]
        @ConsultaDianID = @ConsultaAnteriorID,
        @Resultado = 'ERROR';

    IF NOT EXISTS
    (
        SELECT 1 FROM @Fin
        WHERE [Operacion] = 'YA_FINALIZADA'
          AND [EstadoProceso] = 'CONSULTANDO_DIAN'
    )
        THROW 51414, 'Un trabajador vencido modifico el reclamo nuevo.', 1;

    DELETE FROM @Fin;
    INSERT INTO @Fin
    EXEC [dian].[sp_FinalizarConsultaDocumento]
        @ConsultaDianID = @ConsultaDianID,
        @Resultado = 'ERROR';

    -- Caso 5: una revision posterior no puede perder su estado.
    SELECT @DocumentoID = [DocumentoID],
           @DocumentoVersionID = [DocumentoVersionID],
           @Clave = [Clave]
    FROM @Documentos WHERE [Numero] = 5;

    DELETE FROM @Inicio;
    INSERT INTO @Inicio
    EXEC [dian].[sp_IniciarConsultaDocumento]
        @DocumentoID = @DocumentoID,
        @ClienteID = @ClienteID,
        @CargaArchivoID = @CargaArchivoID,
        @DocumentoVersionID = @DocumentoVersionID,
        @ClaveDocumento = @Clave;
    SELECT @ConsultaDianID = [ConsultaDianID] FROM @Inicio;

    UPDATE [dian].[Documento]
    SET [EstadoProceso] = 'REQUIERE_REVISION',
        [EstadoRevision] = 'PENDIENTE'
    WHERE [DocumentoID] = @DocumentoID;

    DELETE FROM @Fin;
    INSERT INTO @Fin
    EXEC [dian].[sp_FinalizarConsultaDocumento]
        @ConsultaDianID = @ConsultaDianID,
        @Resultado = 'ERROR';

    IF NOT EXISTS
    (
        SELECT 1 FROM @Fin
        WHERE [EstadoProceso] = 'REQUIERE_REVISION'
          AND [Reintentar] = 0
    )
        THROW 51415, 'La finalizacion borro el estado de revision.', 1;

    -- Caso 6: Blob y SQL registraron el XML, pero la ejecucion cayo antes
    -- de finalizar. La nueva entrega repara el estado sin otra consulta.
    SELECT @DocumentoID = [DocumentoID],
           @DocumentoVersionID = [DocumentoVersionID],
           @Clave = [Clave]
    FROM @Documentos WHERE [Numero] = 6;

    DELETE FROM @Inicio;
    INSERT INTO @Inicio
    EXEC [dian].[sp_IniciarConsultaDocumento]
        @DocumentoID = @DocumentoID,
        @ClienteID = @ClienteID,
        @CargaArchivoID = @CargaArchivoID,
        @DocumentoVersionID = @DocumentoVersionID,
        @ClaveDocumento = @Clave;
    SELECT @ConsultaDianID = [ConsultaDianID] FROM @Inicio;

    SET @BlobUri = CONCAT(
        N'https://stdianxmlcpabaasdev.blob.core.windows.net/',
        N'xml-dian/clientes/', @ClienteID,
        N'/documentos/', @DocumentoID,
        N'/', @HashXml, N'.xml'
    );

    DELETE FROM @Xml;
    INSERT INTO @Xml
    EXEC [dian].[sp_RegistrarXmlDocumento]
        @DocumentoID = @DocumentoID,
        @ConsultaDianID = @ConsultaDianID,
        @BlobUri = @BlobUri,
        @HashXmlSha256 = @HashXml,
        @TamanoBytes = 25,
        @TipoXmlDetectado = N'Invoice';

    DELETE FROM @Inicio;
    INSERT INTO @Inicio
    EXEC [dian].[sp_IniciarConsultaDocumento]
        @DocumentoID = @DocumentoID,
        @ClienteID = @ClienteID,
        @CargaArchivoID = @CargaArchivoID,
        @DocumentoVersionID = @DocumentoVersionID,
        @ClaveDocumento = @Clave;

    IF NOT EXISTS
    (
        SELECT 1 FROM @Inicio
        WHERE [Resultado] = 'XML_YA_REGISTRADO'
          AND [EstadoProceso] = 'XML_DESCARGADO'
          AND [DebeConsultar] = 0
    )
       OR NOT EXISTS
    (
        SELECT 1 FROM [dian].[ConsultaDian]
        WHERE [ConsultaDianID] = @ConsultaDianID
          AND [Estado] = 'OK'
          AND [FechaFinUTC] IS NOT NULL
    )
        THROW 51416, 'No se recupero el XML guardado antes de finalizar.', 1;

    IF (SELECT COUNT(*) FROM [dian].[DocumentoProcesoHistorial]
        WHERE [DocumentoID] IN
              (SELECT [DocumentoID] FROM @Documentos)
          AND [TipoEvento] = 'CONSULTA_INICIADA') <> 8
        THROW 51417, 'Falta trazabilidad de los intentos iniciados.', 1;

    ROLLBACK TRANSACTION;
    SELECT N'OK' AS [ResultadoPrueba];
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
