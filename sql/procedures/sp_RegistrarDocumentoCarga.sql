SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE [dian].[sp_RegistrarDocumentoCarga]
    @CargaArchivoID bigint,
    @FilaOrigen int,
    @ClaveDocumento varchar(128),
    @TipoClave varchar(20) = 'CUFE',
    @TipoDocumento nvarchar(200),
    @Folio nvarchar(100),
    @Prefijo nvarchar(100) = NULL,
    @Divisa nvarchar(50) = NULL,
    @FormaPago nvarchar(100) = NULL,
    @MedioPago nvarchar(100) = NULL,
    @FechaEmision date,
    @FechaRecepcion datetime2(0),
    @NitEmisor nvarchar(50),
    @NombreEmisor nvarchar(500),
    @NitReceptor nvarchar(50),
    @NombreReceptor nvarchar(500),
    @Iva decimal(19,4) = 0,
    @Ica decimal(19,4) = 0,
    @Ic decimal(19,4) = 0,
    @Inc decimal(19,4) = 0,
    @Timbre decimal(19,4) = 0,
    @IncBolsas decimal(19,4) = 0,
    @InCarbono decimal(19,4) = 0,
    @InCombustibles decimal(19,4) = 0,
    @IcDatos decimal(19,4) = 0,
    @Icl decimal(19,4) = 0,
    @Inpp decimal(19,4) = 0,
    @Ibua decimal(19,4) = 0,
    @Icui decimal(19,4) = 0,
    @ReteIva decimal(19,4) = 0,
    @ReteRenta decimal(19,4) = 0,
    @ReteIca decimal(19,4) = 0,
    @Total decimal(19,4),
    @EstadoDianOrigen nvarchar(200),
    @GrupoOrigen nvarchar(100),
    @HashFilaSha256 varchar(128),
    @HashContenidoSha256 varchar(128),
    @FilaOrigenJson nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ClienteID bigint;
    DECLARE @EstadoCarga varchar(30);
    DECLARE @Actor nvarchar(256);
    DECLARE @DocumentoID bigint;
    DECLARE @DocumentoVersionID bigint;
    DECLARE @NumeroRevision int;
    DECLARE @RevisionActual int;
    DECLARE @EstadoRevision varchar(20);
    DECLARE @EstadoProceso varchar(30);
    DECLARE @EstadoProcesoAnterior varchar(30);
    DECLARE @Resultado varchar(30);
    DECLARE @ErrorValidacion nvarchar(1000) = N'';
    DECLARE @DebeDescargarXml bit = 0;
    DECLARE @SolicitudExistente bit = 0;
    DECLARE @LockResult int;
    DECLARE @LockResource nvarchar(255);
    DECLARE @DetalleJson nvarchar(max);

    DECLARE @ClaveNormalizada varchar(128) = LOWER(NULLIF(LTRIM(RTRIM(@ClaveDocumento)), ''));
    DECLARE @TipoClaveNormalizado varchar(20) = UPPER(NULLIF(LTRIM(RTRIM(@TipoClave)), ''));
    DECLARE @TipoDocumentoNormalizado nvarchar(200) = NULLIF(LTRIM(RTRIM(@TipoDocumento)), N'');
    DECLARE @FolioNormalizado nvarchar(100) = NULLIF(LTRIM(RTRIM(@Folio)), N'');
    DECLARE @PrefijoNormalizado nvarchar(100) = NULLIF(LTRIM(RTRIM(@Prefijo)), N'');
    DECLARE @DivisaNormalizada nvarchar(50) = NULLIF(UPPER(LTRIM(RTRIM(@Divisa))), N'');
    DECLARE @FormaPagoNormalizada nvarchar(100) = NULLIF(LTRIM(RTRIM(@FormaPago)), N'');
    DECLARE @MedioPagoNormalizado nvarchar(100) = NULLIF(LTRIM(RTRIM(@MedioPago)), N'');
    DECLARE @NitEmisorNormalizado nvarchar(50) = NULLIF(UPPER(LTRIM(RTRIM(@NitEmisor))), N'');
    DECLARE @NombreEmisorNormalizado nvarchar(500) = NULLIF(LTRIM(RTRIM(@NombreEmisor)), N'');
    DECLARE @NitReceptorNormalizado nvarchar(50) = NULLIF(UPPER(LTRIM(RTRIM(@NitReceptor))), N'');
    DECLARE @NombreReceptorNormalizado nvarchar(500) = NULLIF(LTRIM(RTRIM(@NombreReceptor)), N'');
    DECLARE @EstadoDianNormalizado nvarchar(200) = NULLIF(LTRIM(RTRIM(@EstadoDianOrigen)), N'');
    DECLARE @GrupoNormalizado nvarchar(100) = NULLIF(LTRIM(RTRIM(@GrupoOrigen)), N'');
    DECLARE @HashFilaNormalizado varchar(128) = LOWER(NULLIF(LTRIM(RTRIM(@HashFilaSha256)), ''));
    DECLARE @HashContenidoNormalizado varchar(128) = LOWER(NULLIF(LTRIM(RTRIM(@HashContenidoSha256)), ''));
    DECLARE @JsonPersistido nvarchar(max) = @FilaOrigenJson;

    IF @CargaArchivoID IS NULL
        THROW 50201, 'La carga es obligatoria.', 1;

    IF @FilaOrigen IS NULL OR @FilaOrigen < 2
        THROW 50202, 'La fila de origen debe ser igual o superior a 2.', 1;

    BEGIN TRANSACTION;

    SET @LockResource = CONCAT(N'dian:carga-fila:', @CargaArchivoID, N':', @FilaOrigen);

    EXEC @LockResult = sys.sp_getapplock
        @Resource = @LockResource,
        @LockMode = 'Exclusive',
        @LockOwner = 'Transaction',
        @LockTimeout = 10000;

    IF @LockResult < 0
        THROW 50203, 'No fue posible bloquear la fila para su registro.', 1;

    SELECT
        @ClienteID = [ClienteID],
        @EstadoCarga = [Estado],
        @Actor = [CargadoPor]
    FROM [dian].[CargaArchivo] WITH (UPDLOCK, HOLDLOCK)
    WHERE [CargaArchivoID] = @CargaArchivoID;

    IF @ClienteID IS NULL
        THROW 50204, 'La carga indicada no existe.', 1;

    SELECT
        @DocumentoID = cd.[DocumentoID],
        @DocumentoVersionID = cd.[DocumentoVersionID],
        @NumeroRevision = dv.[NumeroRevision],
        @Resultado = cd.[Resultado],
        @ErrorValidacion = cd.[ErrorValidacion],
        @EstadoRevision = d.[EstadoRevision],
        @EstadoProceso = d.[EstadoProceso]
    FROM [dian].[CargaDocumento] AS cd WITH (UPDLOCK, HOLDLOCK)
    LEFT JOIN [dian].[DocumentoVersion] AS dv
        ON dv.[DocumentoVersionID] = cd.[DocumentoVersionID]
    LEFT JOIN [dian].[Documento] AS d
        ON d.[DocumentoID] = cd.[DocumentoID]
    WHERE cd.[CargaArchivoID] = @CargaArchivoID
      AND cd.[FilaOrigen] = @FilaOrigen;

    IF @Resultado IS NOT NULL
    BEGIN
        SET @SolicitudExistente = 1;
        SET @DebeDescargarXml = 0;

        COMMIT TRANSACTION;

        SELECT
            @CargaArchivoID AS [CargaArchivoID],
            @FilaOrigen AS [FilaOrigen],
            @DocumentoID AS [DocumentoID],
            @DocumentoVersionID AS [DocumentoVersionID],
            @NumeroRevision AS [NumeroRevision],
            @Resultado AS [Resultado],
            @EstadoRevision AS [EstadoRevision],
            @EstadoProceso AS [EstadoProceso],
            @DebeDescargarXml AS [DebeDescargarXml],
            @SolicitudExistente AS [SolicitudExistente],
            NULLIF(@ErrorValidacion, N'') AS [ErrorValidacion];
        RETURN;
    END;

    IF @EstadoCarga NOT IN ('RECIBIDA', 'PROCESANDO')
        THROW 50205, 'La carga no está disponible para registrar nuevas filas.', 1;

    IF @ClaveNormalizada IS NULL
       OR LEN(@ClaveNormalizada) <> 96
       OR @ClaveNormalizada COLLATE Latin1_General_100_BIN2 LIKE '%[^0-9a-f]%'
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N'CUFE/CUDE inválido; ');

    IF @TipoClaveNormalizado IS NULL OR @TipoClaveNormalizado NOT IN ('CUFE', 'CUDE')
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N'Tipo de clave inválido; ');

    IF @TipoDocumentoNormalizado IS NULL OR LEN(@TipoDocumentoNormalizado) > 80
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N'Tipo de documento inválido; ');

    IF @FolioNormalizado IS NULL OR LEN(@FolioNormalizado) > 50
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N'Folio inválido; ');

    IF LEN(COALESCE(@PrefijoNormalizado, N'')) > 30
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N'Prefijo demasiado largo; ');

    IF LEN(COALESCE(@DivisaNormalizada, N'')) > 10
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N'Divisa demasiado larga; ');

    IF LEN(COALESCE(@FormaPagoNormalizada, N'')) > 20
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N'Forma de pago demasiado larga; ');

    IF LEN(COALESCE(@MedioPagoNormalizado, N'')) > 20
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N'Medio de pago demasiado largo; ');

    IF @FechaEmision IS NULL
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N'Fecha de emisión obligatoria; ');

    IF @FechaRecepcion IS NULL
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N'Fecha de recepción obligatoria; ');

    IF @NitEmisorNormalizado IS NULL OR LEN(@NitEmisorNormalizado) > 20
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N'NIT del emisor inválido; ');

    IF @NombreEmisorNormalizado IS NULL OR LEN(@NombreEmisorNormalizado) > 300
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N'Nombre del emisor inválido; ');

    IF @NitReceptorNormalizado IS NULL OR LEN(@NitReceptorNormalizado) > 20
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N'NIT del receptor inválido; ');

    IF @NombreReceptorNormalizado IS NULL OR LEN(@NombreReceptorNormalizado) > 300
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N'Nombre del receptor inválido; ');

    IF @Total IS NULL
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N'Total obligatorio; ');

    IF @EstadoDianNormalizado IS NULL OR LEN(@EstadoDianNormalizado) > 100
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N'Estado DIAN inválido; ');

    IF @GrupoNormalizado IS NULL OR LEN(@GrupoNormalizado) > 50
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N'Grupo de origen inválido; ');

    IF @HashFilaNormalizado IS NULL
       OR LEN(@HashFilaNormalizado) <> 64
       OR @HashFilaNormalizado COLLATE Latin1_General_100_BIN2 LIKE '%[^0-9a-f]%'
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N'Hash de fila inválido; ');

    IF @HashContenidoNormalizado IS NULL
       OR LEN(@HashContenidoNormalizado) <> 64
       OR @HashContenidoNormalizado COLLATE Latin1_General_100_BIN2 LIKE '%[^0-9a-f]%'
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N'Hash de contenido inválido; ');

    IF COALESCE(ISJSON(@FilaOrigenJson), 0) <> 1
    BEGIN
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N'JSON de origen inválido; ');
        SET @JsonPersistido = N'{"error":"FilaOrigenJson no es JSON válido"}';
    END;

    IF @ErrorValidacion <> N''
    BEGIN
        SET @ErrorValidacion = LEFT(@ErrorValidacion, LEN(@ErrorValidacion) - 2);
        SET @Resultado = 'RECHAZADO';

        INSERT INTO [dian].[CargaDocumento]
        (
            [CargaArchivoID],
            [FilaOrigen],
            [HashFilaSha256],
            [FilaOrigenJson],
            [EsValida],
            [Resultado],
            [ErrorValidacion]
        )
        VALUES
        (
            @CargaArchivoID,
            @FilaOrigen,
            CASE
                WHEN LEN(@HashFilaNormalizado) = 64
                 AND @HashFilaNormalizado COLLATE Latin1_General_100_BIN2 NOT LIKE '%[^0-9a-f]%'
                THEN CONVERT(char(64), @HashFilaNormalizado)
                ELSE NULL
            END,
            COALESCE(@JsonPersistido, N'{"error":"FilaOrigenJson no fue suministrado"}'),
            0,
            @Resultado,
            @ErrorValidacion
        );

        UPDATE [dian].[CargaArchivo]
        SET [Estado] = 'PROCESANDO',
            [Mensaje] = N'Procesando filas del archivo.'
        WHERE [CargaArchivoID] = @CargaArchivoID;

        COMMIT TRANSACTION;

        SELECT
            @CargaArchivoID AS [CargaArchivoID],
            @FilaOrigen AS [FilaOrigen],
            CAST(NULL AS bigint) AS [DocumentoID],
            CAST(NULL AS bigint) AS [DocumentoVersionID],
            CAST(NULL AS int) AS [NumeroRevision],
            @Resultado AS [Resultado],
            CAST(NULL AS varchar(20)) AS [EstadoRevision],
            CAST(NULL AS varchar(30)) AS [EstadoProceso],
            CAST(0 AS bit) AS [DebeDescargarXml],
            CAST(0 AS bit) AS [SolicitudExistente],
            @ErrorValidacion AS [ErrorValidacion];
        RETURN;
    END;

    SET @LockResource = CONCAT(N'dian:documento:', @ClienteID, N':', @ClaveNormalizada);

    EXEC @LockResult = sys.sp_getapplock
        @Resource = @LockResource,
        @LockMode = 'Exclusive',
        @LockOwner = 'Transaction',
        @LockTimeout = 10000;

    IF @LockResult < 0
        THROW 50206, 'No fue posible bloquear el documento para su registro.', 1;

    SELECT
        @DocumentoID = [DocumentoID],
        @RevisionActual = [RevisionActual],
        @EstadoRevision = [EstadoRevision],
        @EstadoProceso = [EstadoProceso]
    FROM [dian].[Documento] WITH (UPDLOCK, HOLDLOCK)
    WHERE [ClienteID] = @ClienteID
      AND [ClaveDocumento] = CONVERT(char(96), @ClaveNormalizada);

    IF @DocumentoID IS NULL
    BEGIN
        INSERT INTO [dian].[Documento]
        (
            [ClienteID],
            [ClaveDocumento],
            [TipoClave],
            [TipoDocumento],
            [RevisionActual],
            [EstadoRevision],
            [EstadoProceso],
            [PrimeraCargaID],
            [UltimaCargaID]
        )
        VALUES
        (
            @ClienteID,
            CONVERT(char(96), @ClaveNormalizada),
            CONVERT(varchar(4), @TipoClaveNormalizado),
            CONVERT(nvarchar(80), @TipoDocumentoNormalizado),
            1,
            'NO_REQUIERE',
            'PENDIENTE_DESCARGA',
            @CargaArchivoID,
            @CargaArchivoID
        );

        SET @DocumentoID = SCOPE_IDENTITY();
        SET @NumeroRevision = 1;
        SET @EstadoRevision = 'NO_REQUIERE';
        SET @EstadoProceso = 'PENDIENTE_DESCARGA';
        SET @Resultado = 'NUEVO';
        SET @DebeDescargarXml = 1;

        INSERT INTO [dian].[DocumentoVersion]
        (
            [DocumentoID], [NumeroRevision], [HashContenidoSha256],
            [TipoDocumentoOrigen], [Folio], [Prefijo], [Divisa],
            [FormaPago], [MedioPago], [FechaEmision], [FechaRecepcion],
            [NitEmisor], [NombreEmisor], [NitReceptor], [NombreReceptor],
            [Iva], [Ica], [Ic], [Inc], [Timbre], [IncBolsas],
            [InCarbono], [InCombustibles], [IcDatos], [Icl], [Inpp],
            [Ibua], [Icui], [ReteIva], [ReteRenta], [ReteIca], [Total],
            [EstadoDianOrigen], [GrupoOrigen], [EstadoRevision],
            [EsRevisionVigente], [CargaCreacionID]
        )
        VALUES
        (
            @DocumentoID, @NumeroRevision, CONVERT(char(64), @HashContenidoNormalizado),
            CONVERT(nvarchar(80), @TipoDocumentoNormalizado), CONVERT(nvarchar(50), @FolioNormalizado),
            CONVERT(nvarchar(30), @PrefijoNormalizado), CONVERT(nvarchar(10), @DivisaNormalizada),
            CONVERT(nvarchar(20), @FormaPagoNormalizada), CONVERT(nvarchar(20), @MedioPagoNormalizado),
            @FechaEmision, @FechaRecepcion,
            CONVERT(nvarchar(20), @NitEmisorNormalizado), CONVERT(nvarchar(300), @NombreEmisorNormalizado),
            CONVERT(nvarchar(20), @NitReceptorNormalizado), CONVERT(nvarchar(300), @NombreReceptorNormalizado),
            COALESCE(@Iva, 0), COALESCE(@Ica, 0), COALESCE(@Ic, 0), COALESCE(@Inc, 0),
            COALESCE(@Timbre, 0), COALESCE(@IncBolsas, 0), COALESCE(@InCarbono, 0),
            COALESCE(@InCombustibles, 0), COALESCE(@IcDatos, 0), COALESCE(@Icl, 0),
            COALESCE(@Inpp, 0), COALESCE(@Ibua, 0), COALESCE(@Icui, 0),
            COALESCE(@ReteIva, 0), COALESCE(@ReteRenta, 0), COALESCE(@ReteIca, 0), @Total,
            CONVERT(nvarchar(100), @EstadoDianNormalizado), CONVERT(nvarchar(50), @GrupoNormalizado),
            @EstadoRevision, 1, @CargaArchivoID
        );

        SET @DocumentoVersionID = SCOPE_IDENTITY();
        SET @DetalleJson = CONCAT(N'{"cargaArchivoId":', @CargaArchivoID,
            N',"filaOrigen":', @FilaOrigen, N',"resultado":"NUEVO"}');

        INSERT INTO [dian].[DocumentoProcesoHistorial]
        (
            [DocumentoID], [CargaArchivoID], [EstadoAnterior], [EstadoNuevo],
            [TipoEvento], [Origen], [Actor], [DetalleJson]
        )
        VALUES
        (
            @DocumentoID, @CargaArchivoID, NULL, @EstadoProceso,
            'REGISTRO', 'FUNCTION', COALESCE(@Actor, N'Azure Function'), @DetalleJson
        );
    END
    ELSE
    BEGIN
        SET @EstadoProcesoAnterior = @EstadoProceso;

        SELECT
            @DocumentoVersionID = [DocumentoVersionID],
            @NumeroRevision = [NumeroRevision]
        FROM [dian].[DocumentoVersion] WITH (UPDLOCK, HOLDLOCK)
        WHERE [DocumentoID] = @DocumentoID
          AND [HashContenidoSha256] = CONVERT(char(64), @HashContenidoNormalizado);

        IF @DocumentoVersionID IS NOT NULL
        BEGIN
            SET @Resultado = 'DUPLICADO';
            SET @DebeDescargarXml = 0;

            UPDATE [dian].[Documento]
            SET [UltimaCargaID] = @CargaArchivoID,
                [FechaActualizacionUTC] = sysutcdatetime()
            WHERE [DocumentoID] = @DocumentoID;

            SET @DetalleJson = CONCAT(N'{"cargaArchivoId":', @CargaArchivoID,
                N',"filaOrigen":', @FilaOrigen, N',"resultado":"DUPLICADO"}');

            INSERT INTO [dian].[DocumentoProcesoHistorial]
            (
                [DocumentoID], [CargaArchivoID], [EstadoAnterior], [EstadoNuevo],
                [TipoEvento], [Origen], [Actor], [DetalleJson]
            )
            VALUES
            (
                @DocumentoID, @CargaArchivoID, @EstadoProcesoAnterior, @EstadoProcesoAnterior,
                'DOCUMENTO_DUPLICADO', 'FUNCTION', COALESCE(@Actor, N'Azure Function'), @DetalleJson
            );
        END
        ELSE
        BEGIN
            SET @NumeroRevision = @RevisionActual + 1;
            SET @Resultado = 'NUEVA_REVISION';
            SET @EstadoRevision = 'PENDIENTE';
            SET @EstadoProceso = 'REQUIERE_REVISION';
            SET @DebeDescargarXml = 0;

            UPDATE [dian].[DocumentoVersion]
            SET [EsRevisionVigente] = 0
            WHERE [DocumentoID] = @DocumentoID
              AND [EsRevisionVigente] = 1;

            INSERT INTO [dian].[DocumentoVersion]
            (
                [DocumentoID], [NumeroRevision], [HashContenidoSha256],
                [TipoDocumentoOrigen], [Folio], [Prefijo], [Divisa],
                [FormaPago], [MedioPago], [FechaEmision], [FechaRecepcion],
                [NitEmisor], [NombreEmisor], [NitReceptor], [NombreReceptor],
                [Iva], [Ica], [Ic], [Inc], [Timbre], [IncBolsas],
                [InCarbono], [InCombustibles], [IcDatos], [Icl], [Inpp],
                [Ibua], [Icui], [ReteIva], [ReteRenta], [ReteIca], [Total],
                [EstadoDianOrigen], [GrupoOrigen], [EstadoRevision], [MotivoRevision],
                [EsRevisionVigente], [CargaCreacionID]
            )
            VALUES
            (
                @DocumentoID, @NumeroRevision, CONVERT(char(64), @HashContenidoNormalizado),
                CONVERT(nvarchar(80), @TipoDocumentoNormalizado), CONVERT(nvarchar(50), @FolioNormalizado),
                CONVERT(nvarchar(30), @PrefijoNormalizado), CONVERT(nvarchar(10), @DivisaNormalizada),
                CONVERT(nvarchar(20), @FormaPagoNormalizada), CONVERT(nvarchar(20), @MedioPagoNormalizado),
                @FechaEmision, @FechaRecepcion,
                CONVERT(nvarchar(20), @NitEmisorNormalizado), CONVERT(nvarchar(300), @NombreEmisorNormalizado),
                CONVERT(nvarchar(20), @NitReceptorNormalizado), CONVERT(nvarchar(300), @NombreReceptorNormalizado),
                COALESCE(@Iva, 0), COALESCE(@Ica, 0), COALESCE(@Ic, 0), COALESCE(@Inc, 0),
                COALESCE(@Timbre, 0), COALESCE(@IncBolsas, 0), COALESCE(@InCarbono, 0),
                COALESCE(@InCombustibles, 0), COALESCE(@IcDatos, 0), COALESCE(@Icl, 0),
                COALESCE(@Inpp, 0), COALESCE(@Ibua, 0), COALESCE(@Icui, 0),
                COALESCE(@ReteIva, 0), COALESCE(@ReteRenta, 0), COALESCE(@ReteIca, 0), @Total,
                CONVERT(nvarchar(100), @EstadoDianNormalizado), CONVERT(nvarchar(50), @GrupoNormalizado),
                @EstadoRevision, N'El mismo CUFE/CUDE fue recibido con contenido diferente.',
                1, @CargaArchivoID
            );

            SET @DocumentoVersionID = SCOPE_IDENTITY();

            UPDATE [dian].[Documento]
            SET [TipoDocumento] = CONVERT(nvarchar(80), @TipoDocumentoNormalizado),
                [RevisionActual] = @NumeroRevision,
                [EstadoRevision] = @EstadoRevision,
                [MotivoRevision] = N'El mismo CUFE/CUDE fue recibido con contenido diferente.',
                [EstadoProceso] = @EstadoProceso,
                [UltimaCargaID] = @CargaArchivoID,
                [FechaActualizacionUTC] = sysutcdatetime()
            WHERE [DocumentoID] = @DocumentoID;

            SET @DetalleJson = CONCAT(N'{"cargaArchivoId":', @CargaArchivoID,
                N',"filaOrigen":', @FilaOrigen, N',"numeroRevision":', @NumeroRevision,
                N',"resultado":"NUEVA_REVISION"}');

            INSERT INTO [dian].[DocumentoProcesoHistorial]
            (
                [DocumentoID], [CargaArchivoID], [EstadoAnterior], [EstadoNuevo],
                [TipoEvento], [Origen], [Actor], [DetalleJson]
            )
            VALUES
            (
                @DocumentoID, @CargaArchivoID, @EstadoProcesoAnterior, @EstadoProceso,
                'NUEVA_REVISION', 'FUNCTION', COALESCE(@Actor, N'Azure Function'), @DetalleJson
            );
        END;
    END;

    INSERT INTO [dian].[CargaDocumento]
    (
        [CargaArchivoID], [FilaOrigen], [DocumentoID], [DocumentoVersionID],
        [HashFilaSha256], [FilaOrigenJson], [EsValida], [Resultado]
    )
    VALUES
    (
        @CargaArchivoID, @FilaOrigen, @DocumentoID, @DocumentoVersionID,
        CONVERT(char(64), @HashFilaNormalizado), @JsonPersistido, 1, @Resultado
    );

    UPDATE [dian].[CargaArchivo]
    SET [Estado] = 'PROCESANDO',
        [Mensaje] = N'Procesando filas del archivo.'
    WHERE [CargaArchivoID] = @CargaArchivoID;

    COMMIT TRANSACTION;

    SELECT
        @CargaArchivoID AS [CargaArchivoID],
        @FilaOrigen AS [FilaOrigen],
        @DocumentoID AS [DocumentoID],
        @DocumentoVersionID AS [DocumentoVersionID],
        @NumeroRevision AS [NumeroRevision],
        @Resultado AS [Resultado],
        @EstadoRevision AS [EstadoRevision],
        @EstadoProceso AS [EstadoProceso],
        @DebeDescargarXml AS [DebeDescargarXml],
        @SolicitudExistente AS [SolicitudExistente],
        CAST(NULL AS nvarchar(1000)) AS [ErrorValidacion];
END;
GO

GRANT EXECUTE ON OBJECT::[dian].[sp_RegistrarDocumentoCarga] TO [dian_runtime];
GO
