SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE [dian].[sp_IniciarConsultaDocumento]
    @DocumentoID bigint,
    @ClienteID bigint,
    @CargaArchivoID bigint,
    @DocumentoVersionID bigint,
    @ClaveDocumento varchar(128),
    @MaximoIntentos smallint = 5,
    @TiempoReclamoSegundos int = 540
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Clave varchar(128) = LOWER(NULLIF(LTRIM(RTRIM(@ClaveDocumento)), ''));
    DECLARE @ClienteActual bigint;
    DECLARE @ClaveActual char(96);
    DECLARE @Estado varchar(30);
    DECLARE @EstadoAnterior varchar(30);
    DECLARE @ConsultaDianID bigint;
    DECLARE @ConsultaAbiertaID bigint;
    DECLARE @InicioAbierto datetime2(3);
    DECLARE @DocumentoXmlID bigint;
    DECLARE @NumeroIntento int;
    DECLARE @Resultado varchar(30);
    DECLARE @DebeConsultar bit = 0;
    DECLARE @PuedeIniciar bit = 1;
    DECLARE @LockResult int;
    DECLARE @LockResource nvarchar(255);

    IF @DocumentoID IS NULL OR @DocumentoID <= 0
       OR @ClienteID IS NULL OR @ClienteID <= 0
       OR @CargaArchivoID IS NULL OR @CargaArchivoID <= 0
       OR @DocumentoVersionID IS NULL OR @DocumentoVersionID <= 0
        THROW 50401, 'Los identificadores deben ser positivos.', 1;

    IF @Clave IS NULL
       OR LEN(@Clave) <> 96
       OR @Clave COLLATE Latin1_General_100_BIN2 LIKE '%[^0-9a-f]%'
        THROW 50402, 'El CUFE/CUDE no es valido.', 1;

    IF @MaximoIntentos IS NULL OR @MaximoIntentos < 1
       OR @TiempoReclamoSegundos IS NULL
       OR @TiempoReclamoSegundos NOT BETWEEN 1 AND 86400
        THROW 50403, 'La configuracion de reintentos no es valida.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        SET @LockResource = CONCAT(N'dian:consulta-documento:', @DocumentoID);

        EXEC @LockResult = sys.sp_getapplock
            @Resource = @LockResource,
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult < 0
            THROW 50404, 'No se pudo reclamar el documento.', 1;

        SELECT
            @ClienteActual = [ClienteID],
            @ClaveActual = [ClaveDocumento],
            @Estado = [EstadoProceso]
        FROM [dian].[Documento] WITH (UPDLOCK, HOLDLOCK)
        WHERE [DocumentoID] = @DocumentoID;

        IF @ClienteActual IS NULL
            THROW 50405, 'El documento no existe.', 1;

        IF @ClienteActual <> @ClienteID
           OR @ClaveActual <> CONVERT(char(96), @Clave)
            THROW 50406, 'El mensaje no coincide con el documento.', 1;

        IF NOT EXISTS
        (
            SELECT 1
            FROM [dian].[CargaDocumento]
            WHERE [CargaArchivoID] = @CargaArchivoID
              AND [DocumentoID] = @DocumentoID
              AND [DocumentoVersionID] = @DocumentoVersionID
              AND [EsValida] = 1
        )
            THROW 50407, 'La carga o version no corresponde al documento.', 1;

        SELECT TOP (1) @DocumentoXmlID = [DocumentoXmlID]
        FROM [dian].[DocumentoXml] WITH (UPDLOCK, HOLDLOCK)
        WHERE [DocumentoID] = @DocumentoID
          AND [EsVigente] = 1;

        IF @DocumentoXmlID IS NOT NULL
        BEGIN
            SET @Resultado = 'XML_YA_REGISTRADO';
            SET @PuedeIniciar = 0;

            -- Recupera una ejecucion que guardo el XML pero no alcanzo a finalizar.
            UPDATE [dian].[ConsultaDian]
            SET [Estado] = 'OK',
                [FechaFinUTC] = COALESCE([FechaFinUTC], SYSUTCDATETIME()),
                [ErrorTipo] = NULL
            WHERE [DocumentoID] = @DocumentoID
              AND [Estado] = 'INICIADA';

            IF @Estado IN ('PENDIENTE_DESCARGA', 'CONSULTANDO_DIAN', 'ERROR')
            BEGIN
                SET @EstadoAnterior = @Estado;
                SET @Estado = 'XML_DESCARGADO';

                UPDATE [dian].[Documento]
                SET [EstadoProceso] = @Estado,
                    [FechaActualizacionUTC] = SYSUTCDATETIME()
                WHERE [DocumentoID] = @DocumentoID;

                INSERT INTO [dian].[DocumentoProcesoHistorial]
                (
                    [DocumentoID], [CargaArchivoID], [EstadoAnterior],
                    [EstadoNuevo], [TipoEvento], [Origen], [Actor], [DetalleJson]
                )
                VALUES
                (
                    @DocumentoID, @CargaArchivoID, @EstadoAnterior,
                    @Estado, 'XML_YA_REGISTRADO', 'SISTEMA', N'Azure Function',
                    CONCAT(N'{"documentoXmlId":', @DocumentoXmlID, N'}')
                );
            END;
        END
        ELSE IF @Estado = 'CONSULTANDO_DIAN'
        BEGIN
            SELECT TOP (1)
                @ConsultaAbiertaID = [ConsultaDianID],
                @InicioAbierto = [FechaInicioUTC],
                @NumeroIntento = [NumeroIntento]
            FROM [dian].[ConsultaDian] WITH (UPDLOCK, HOLDLOCK)
            WHERE [DocumentoID] = @DocumentoID
              AND [Estado] = 'INICIADA'
            ORDER BY [NumeroIntento] DESC;

            IF @ConsultaAbiertaID IS NOT NULL
               AND @InicioAbierto > DATEADD(
                    second, -@TiempoReclamoSegundos, SYSUTCDATETIME()
               )
            BEGIN
                SET @ConsultaDianID = @ConsultaAbiertaID;
                SET @Resultado = 'CONSULTA_EN_PROGRESO';
                SET @PuedeIniciar = 0;
            END
            ELSE
            BEGIN
                IF @ConsultaAbiertaID IS NOT NULL
                    UPDATE [dian].[ConsultaDian]
                    SET [Estado] = 'REINTENTO',
                        [FechaFinUTC] = SYSUTCDATETIME(),
                        [MensajeDianSanitizado] = N'El reclamo anterior expiro.',
                        [ErrorTipo] = N'RECLAMO_EXPIRADO'
                    WHERE [ConsultaDianID] = @ConsultaAbiertaID;

                UPDATE [dian].[Documento]
                SET [EstadoProceso] = 'PENDIENTE_DESCARGA',
                    [FechaActualizacionUTC] = SYSUTCDATETIME()
                WHERE [DocumentoID] = @DocumentoID;

                INSERT INTO [dian].[DocumentoProcesoHistorial]
                (
                    [DocumentoID], [CargaArchivoID], [EstadoAnterior],
                    [EstadoNuevo], [TipoEvento], [Origen], [Actor], [DetalleJson]
                )
                VALUES
                (
                    @DocumentoID, @CargaArchivoID,
                    'CONSULTANDO_DIAN', 'PENDIENTE_DESCARGA',
                    'CONSULTA_EXPIRADA', 'SISTEMA', N'Azure Function',
                    CONCAT(
                        N'{"consultaDianId":',
                        COALESCE(CONVERT(nvarchar(20), @ConsultaAbiertaID), N'null'),
                        N'}'
                    )
                );

                SET @Estado = 'PENDIENTE_DESCARGA';
            END;
        END
        ELSE IF @Estado <> 'PENDIENTE_DESCARGA'
        BEGIN
            SET @Resultado = 'ESTADO_NO_ELEGIBLE';
            SET @PuedeIniciar = 0;
        END;

        IF @PuedeIniciar = 1
        BEGIN
            SELECT @NumeroIntento = COALESCE(MAX(CONVERT(int, [NumeroIntento])), 0)
            FROM [dian].[ConsultaDian] WITH (UPDLOCK, HOLDLOCK)
            WHERE [DocumentoID] = @DocumentoID;

            IF @NumeroIntento >= @MaximoIntentos
            BEGIN
                SET @Resultado = 'MAXIMO_INTENTOS';
                SET @Estado = 'ERROR';

                UPDATE [dian].[Documento]
                SET [EstadoProceso] = @Estado,
                    [FechaActualizacionUTC] = SYSUTCDATETIME()
                WHERE [DocumentoID] = @DocumentoID;

                INSERT INTO [dian].[DocumentoProcesoHistorial]
                (
                    [DocumentoID], [CargaArchivoID], [EstadoAnterior],
                    [EstadoNuevo], [TipoEvento], [Origen], [Actor], [DetalleJson]
                )
                VALUES
                (
                    @DocumentoID, @CargaArchivoID,
                    'PENDIENTE_DESCARGA', @Estado,
                    'MAXIMO_INTENTOS', 'SISTEMA', N'Azure Function',
                    CONCAT(N'{"numeroIntentos":', @NumeroIntento, N'}')
                );
            END
            ELSE
            BEGIN
                SET @NumeroIntento = @NumeroIntento + 1;

                INSERT INTO [dian].[ConsultaDian]
                    ([DocumentoID], [NumeroIntento], [Estado])
                VALUES
                    (@DocumentoID, @NumeroIntento, 'INICIADA');

                SET @ConsultaDianID = SCOPE_IDENTITY();
                SET @Estado = 'CONSULTANDO_DIAN';
                SET @Resultado = 'CONSULTA_INICIADA';
                SET @DebeConsultar = 1;

                UPDATE [dian].[Documento]
                SET [EstadoProceso] = @Estado,
                    [FechaActualizacionUTC] = SYSUTCDATETIME()
                WHERE [DocumentoID] = @DocumentoID;

                INSERT INTO [dian].[DocumentoProcesoHistorial]
                (
                    [DocumentoID], [CargaArchivoID], [EstadoAnterior],
                    [EstadoNuevo], [TipoEvento], [Origen], [Actor], [DetalleJson]
                )
                VALUES
                (
                    @DocumentoID, @CargaArchivoID,
                    'PENDIENTE_DESCARGA', @Estado,
                    'CONSULTA_INICIADA', 'FUNCTION', N'Azure Function',
                    CONCAT(
                        N'{"consultaDianId":', @ConsultaDianID,
                        N',"numeroIntento":', @NumeroIntento, N'}'
                    )
                );
            END;
        END;

        COMMIT TRANSACTION;

        SELECT
            @DocumentoID AS [DocumentoID],
            @ClienteID AS [ClienteID],
            @ClaveActual AS [ClaveDocumento],
            @ConsultaDianID AS [ConsultaDianID],
            @NumeroIntento AS [NumeroIntento],
            @Estado AS [EstadoProceso],
            @Resultado AS [Resultado],
            @DebeConsultar AS [DebeConsultar];
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

GRANT EXECUTE ON OBJECT::[dian].[sp_IniciarConsultaDocumento] TO [dian_runtime];
GO
