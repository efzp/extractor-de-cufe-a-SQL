SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE [dian].[sp_FinalizarConsultaDocumento]
    @ConsultaDianID bigint,
    @Resultado varchar(20),
    @CodigoDian nvarchar(50) = NULL,
    @MensajeDianSanitizado nvarchar(1000) = NULL,
    @HttpStatus smallint = NULL,
    @DuracionMs int = NULL,
    @ErrorTipo nvarchar(100) = NULL,
    @MaximoIntentos smallint = 5
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ResultadoSolicitado varchar(20) =
        UPPER(NULLIF(LTRIM(RTRIM(@Resultado)), ''));
    DECLARE @ResultadoFinal varchar(20);
    DECLARE @DocumentoID bigint;
    DECLARE @NumeroIntento smallint;
    DECLARE @EstadoConsulta varchar(20);
    DECLARE @EstadoAnterior varchar(30);
    DECLARE @EstadoNuevo varchar(30);
    DECLARE @CargaArchivoID bigint;
    DECLARE @Reintentar bit = 0;
    DECLARE @Operacion varchar(20) = 'FINALIZADA';
    DECLARE @LockResult int;
    DECLARE @LockResource nvarchar(255);

    IF @ConsultaDianID IS NULL OR @ConsultaDianID <= 0
        THROW 50601, 'La consulta DIAN es obligatoria.', 1;

    IF @ResultadoSolicitado IS NULL
       OR @ResultadoSolicitado NOT IN ('OK', 'NO_ENCONTRADO', 'REINTENTO', 'ERROR')
        THROW 50602, 'El resultado no es valido.', 1;

    IF @DuracionMs IS NOT NULL AND @DuracionMs < 0
        THROW 50603, 'La duracion no puede ser negativa.', 1;

    IF @MaximoIntentos IS NULL OR @MaximoIntentos < 1
        THROW 50604, 'El maximo de intentos debe ser positivo.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @DocumentoID = [DocumentoID]
        FROM [dian].[ConsultaDian]
        WHERE [ConsultaDianID] = @ConsultaDianID;

        IF @DocumentoID IS NULL
            THROW 50605, 'La consulta no existe.', 1;

        SET @LockResource = CONCAT(N'dian:consulta-documento:', @DocumentoID);

        EXEC @LockResult = sys.sp_getapplock
            @Resource = @LockResource,
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult < 0
            THROW 50606, 'No se pudo bloquear el documento.', 1;

        SELECT
            @NumeroIntento = [NumeroIntento],
            @EstadoConsulta = [Estado]
        FROM [dian].[ConsultaDian] WITH (UPDLOCK, HOLDLOCK)
        WHERE [ConsultaDianID] = @ConsultaDianID;

        SELECT
            @EstadoAnterior = [EstadoProceso],
            @CargaArchivoID = [UltimaCargaID]
        FROM [dian].[Documento] WITH (UPDLOCK, HOLDLOCK)
        WHERE [DocumentoID] = @DocumentoID;

        SET @EstadoNuevo = @EstadoAnterior;

        IF @EstadoConsulta <> 'INICIADA'
        BEGIN
            SET @ResultadoFinal = @EstadoConsulta;
            SET @Operacion = 'YA_FINALIZADA';
        END
        ELSE
        BEGIN
            SET @ResultadoFinal = @ResultadoSolicitado;

            -- Si el XML ya se registro para este intento, prevalece el exito.
            IF EXISTS
            (
                SELECT 1
                FROM [dian].[DocumentoXml]
                WHERE [ConsultaDianID] = @ConsultaDianID
                  AND [DocumentoID] = @DocumentoID
                  AND [EsVigente] = 1
            )
                SET @ResultadoFinal = 'OK';

            IF @ResultadoFinal = 'OK'
               AND NOT EXISTS
               (
                   SELECT 1
                   FROM [dian].[DocumentoXml]
                   WHERE [ConsultaDianID] = @ConsultaDianID
                     AND [DocumentoID] = @DocumentoID
                     AND [EsVigente] = 1
               )
                THROW 50607, 'No hay XML vigente para finalizar en OK.', 1;

            IF @ResultadoFinal = 'REINTENTO'
               AND @NumeroIntento >= @MaximoIntentos
                SET @ResultadoFinal = 'ERROR';

            IF @EstadoAnterior = 'CONSULTANDO_DIAN'
            BEGIN
                SET @EstadoNuevo = CASE @ResultadoFinal
                    WHEN 'OK' THEN 'XML_DESCARGADO'
                    WHEN 'NO_ENCONTRADO' THEN 'NO_ENCONTRADO'
                    WHEN 'REINTENTO' THEN 'PENDIENTE_DESCARGA'
                    ELSE 'ERROR'
                END;

                IF @ResultadoFinal = 'REINTENTO'
                    SET @Reintentar = 1;
            END
            ELSE IF @EstadoAnterior <> 'REQUIERE_REVISION'
            BEGIN
                -- Un intento antiguo no puede sobrescribir un estado posterior.
                SET @ResultadoFinal = 'ERROR';
            END;

            UPDATE [dian].[ConsultaDian]
            SET [Estado] = @ResultadoFinal,
                [FechaFinUTC] = SYSUTCDATETIME(),
                [CodigoDian] = NULLIF(LTRIM(RTRIM(@CodigoDian)), N''),
                [MensajeDianSanitizado] =
                    NULLIF(LTRIM(RTRIM(@MensajeDianSanitizado)), N''),
                [HttpStatus] = @HttpStatus,
                [DuracionMs] = @DuracionMs,
                [ErrorTipo] = NULLIF(LTRIM(RTRIM(@ErrorTipo)), N'')
            WHERE [ConsultaDianID] = @ConsultaDianID;

            IF @EstadoNuevo <> @EstadoAnterior
                UPDATE [dian].[Documento]
                SET [EstadoProceso] = @EstadoNuevo,
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
                @EstadoAnterior, @EstadoNuevo,
                CASE @ResultadoFinal
                    WHEN 'OK' THEN 'XML_DESCARGADO'
                    WHEN 'NO_ENCONTRADO' THEN 'NO_ENCONTRADO'
                    WHEN 'REINTENTO' THEN 'CONSULTA_REINTENTO'
                    ELSE 'CONSULTA_ERROR'
                END,
                CASE
                    WHEN @ResultadoFinal IN ('OK', 'NO_ENCONTRADO') THEN 'DIAN'
                    ELSE 'FUNCTION'
                END,
                N'Azure Function',
                CONCAT(
                    N'{"consultaDianId":', @ConsultaDianID,
                    N',"numeroIntento":', @NumeroIntento, N'}'
                )
            );
        END;

        COMMIT TRANSACTION;

        SELECT
            @ConsultaDianID AS [ConsultaDianID],
            @DocumentoID AS [DocumentoID],
            @NumeroIntento AS [NumeroIntento],
            @ResultadoFinal AS [Resultado],
            @EstadoNuevo AS [EstadoProceso],
            @Reintentar AS [Reintentar],
            @Operacion AS [Operacion];
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

GRANT EXECUTE ON OBJECT::[dian].[sp_FinalizarConsultaDocumento] TO [dian_runtime];
GO
