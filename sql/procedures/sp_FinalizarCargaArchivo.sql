SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE [dian].[sp_FinalizarCargaArchivo]
    @CargaArchivoID bigint,
    @TotalFilasEsperadas int = NULL,
    @Mensaje nvarchar(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Estado varchar(30);
    DECLARE @Resultado varchar(30);
    DECLARE @TotalFilas int;
    DECLARE @FilasProcesadas int;
    DECLARE @FilasPendientes int;
    DECLARE @FilasValidas int;
    DECLARE @FilasDuplicadas int;
    DECLARE @FilasRevision int;
    DECLARE @FilasError int;
    DECLARE @MensajeFinal nvarchar(2000);
    DECLARE @LockResult int;
    DECLARE @LockResource nvarchar(255);

    IF @CargaArchivoID IS NULL
        THROW 50301, 'La carga es obligatoria.', 1;

    IF @TotalFilasEsperadas IS NOT NULL AND @TotalFilasEsperadas < 0
        THROW 50302, 'El total de filas esperadas no puede ser negativo.', 1;

    BEGIN TRANSACTION;

    SET @LockResource = CONCAT(N'dian:finalizar-carga:', @CargaArchivoID);

    EXEC @LockResult = sys.sp_getapplock
        @Resource = @LockResource,
        @LockMode = 'Exclusive',
        @LockOwner = 'Transaction',
        @LockTimeout = 10000;

    IF @LockResult < 0
        THROW 50303, 'No fue posible bloquear la carga para finalizarla.', 1;

    SELECT
        @Estado = [Estado],
        @TotalFilas = [TotalFilas],
        @FilasValidas = [FilasValidas],
        @FilasDuplicadas = [FilasDuplicadas],
        @FilasRevision = [FilasRevision],
        @FilasError = [FilasError],
        @MensajeFinal = [Mensaje]
    FROM [dian].[CargaArchivo] WITH (UPDLOCK, HOLDLOCK)
    WHERE [CargaArchivoID] = @CargaArchivoID;

    IF @Estado IS NULL
        THROW 50304, 'La carga indicada no existe.', 1;

    IF @Estado IN ('OK', 'PARCIAL', 'SIN_CAMBIOS', 'REQUIERE_REVISION', 'ERROR')
    BEGIN
        SELECT @FilasProcesadas = COUNT(*)
        FROM [dian].[CargaDocumento]
        WHERE [CargaArchivoID] = @CargaArchivoID;

        SET @FilasPendientes = CASE
            WHEN COALESCE(@TotalFilas, @FilasProcesadas) > @FilasProcesadas
            THEN COALESCE(@TotalFilas, @FilasProcesadas) - @FilasProcesadas
            ELSE 0
        END;
        SET @Resultado = 'YA_FINALIZADA';

        COMMIT TRANSACTION;

        SELECT
            @CargaArchivoID AS [CargaArchivoID],
            @Estado AS [Estado],
            @TotalFilas AS [TotalFilas],
            @FilasProcesadas AS [FilasProcesadas],
            @FilasPendientes AS [FilasPendientes],
            @FilasValidas AS [FilasValidas],
            @FilasDuplicadas AS [FilasDuplicadas],
            @FilasRevision AS [FilasRevision],
            @FilasError AS [FilasError],
            @Resultado AS [Resultado],
            @MensajeFinal AS [Mensaje];
        RETURN;
    END;

    SELECT
        @FilasProcesadas = COUNT(*),
        @FilasValidas = COALESCE(SUM(CASE WHEN [EsValida] = 1 THEN 1 ELSE 0 END), 0),
        @FilasDuplicadas = COALESCE(SUM(CASE WHEN [Resultado] = 'DUPLICADO' THEN 1 ELSE 0 END), 0),
        @FilasRevision = COALESCE(SUM(CASE WHEN [Resultado] = 'NUEVA_REVISION' THEN 1 ELSE 0 END), 0),
        @FilasError = COALESCE(SUM(CASE WHEN [EsValida] = 0 OR [Resultado] = 'RECHAZADO' THEN 1 ELSE 0 END), 0)
    FROM [dian].[CargaDocumento]
    WHERE [CargaArchivoID] = @CargaArchivoID;

    SET @TotalFilas = COALESCE(@TotalFilasEsperadas, @FilasProcesadas);

    IF @TotalFilas < @FilasProcesadas
        THROW 50305, 'El total esperado no puede ser inferior a las filas ya procesadas.', 1;

    SET @FilasPendientes = @TotalFilas - @FilasProcesadas;

    SET @Estado = CASE
        WHEN @TotalFilas = 0 OR @FilasValidas = 0 THEN 'ERROR'
        WHEN @FilasPendientes > 0 OR @FilasError > 0 THEN 'PARCIAL'
        WHEN @FilasRevision > 0 THEN 'REQUIERE_REVISION'
        ELSE 'OK'
    END;

    SET @MensajeFinal = COALESCE
    (
        NULLIF(LTRIM(RTRIM(@Mensaje)), N''),
        CONCAT
        (
            N'Carga finalizada. Esperadas: ', @TotalFilas,
            N'; procesadas: ', @FilasProcesadas,
            N'; válidas: ', @FilasValidas,
            N'; duplicadas: ', @FilasDuplicadas,
            N'; revisiones: ', @FilasRevision,
            N'; errores: ', @FilasError,
            N'; pendientes: ', @FilasPendientes, N'.'
        )
    );

    UPDATE [dian].[CargaArchivo]
    SET [FechaFinUTC] = sysutcdatetime(),
        [Estado] = @Estado,
        [TotalFilas] = @TotalFilas,
        [FilasValidas] = @FilasValidas,
        [FilasDuplicadas] = @FilasDuplicadas,
        [FilasRevision] = @FilasRevision,
        [FilasError] = @FilasError,
        [Mensaje] = @MensajeFinal
    WHERE [CargaArchivoID] = @CargaArchivoID;

    SET @Resultado = 'FINALIZADA';

    COMMIT TRANSACTION;

    SELECT
        @CargaArchivoID AS [CargaArchivoID],
        @Estado AS [Estado],
        @TotalFilas AS [TotalFilas],
        @FilasProcesadas AS [FilasProcesadas],
        @FilasPendientes AS [FilasPendientes],
        @FilasValidas AS [FilasValidas],
        @FilasDuplicadas AS [FilasDuplicadas],
        @FilasRevision AS [FilasRevision],
        @FilasError AS [FilasError],
        @Resultado AS [Resultado],
        @MensajeFinal AS [Mensaje];
END;
GO

GRANT EXECUTE ON OBJECT::[dian].[sp_FinalizarCargaArchivo] TO [dian_runtime];
GO
