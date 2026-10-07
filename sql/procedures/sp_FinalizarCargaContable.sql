CREATE OR ALTER PROCEDURE [contabilidad].[sp_FinalizarCargaContable]
    @CargaArchivoID bigint,
    @TotalFilasEsperadas int = NULL,
    @Mensaje nvarchar(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Estado varchar(20);
    DECLARE @Resultado varchar(30);
    DECLARE @TotalFilas int;
    DECLARE @FilasProcesadas int;
    DECLARE @FilasPendientes int;
    DECLARE @FilasNuevas int;
    DECLARE @FilasDuplicadas int;
    DECLARE @FilasConflicto int;
    DECLARE @FilasRechazadas int;
    DECLARE @FechaMinima date;
    DECLARE @FechaMaxima date;
    DECLARE @MensajeFinal nvarchar(2000);

    IF @CargaArchivoID IS NULL OR @CargaArchivoID <= 0
        THROW 50850, 'CargaArchivoID debe ser positivo.', 1;
    IF @TotalFilasEsperadas IS NOT NULL AND @TotalFilasEsperadas < 0
        THROW 50851, 'TotalFilasEsperadas no puede ser negativo.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Estado = [Estado],
               @TotalFilas = [TotalFilas],
               @FilasNuevas = [FilasNuevas],
               @FilasDuplicadas = [FilasDuplicadas],
               @FilasConflicto = [FilasConflicto],
               @FilasRechazadas = [FilasRechazadas],
               @FechaMinima = [FechaMinima],
               @FechaMaxima = [FechaMaxima],
               @MensajeFinal = [Mensaje]
        FROM [contabilidad].[CargaArchivo] WITH (UPDLOCK, HOLDLOCK)
        WHERE [CargaArchivoID] = @CargaArchivoID;

        IF @Estado IS NULL
            THROW 50852, 'La carga contable no existe.', 1;

        IF @Estado IN ('OK', 'PARCIAL', 'ERROR')
        BEGIN
            SELECT @FilasProcesadas = COUNT(*)
            FROM [contabilidad].[CargaMovimiento]
            WHERE [CargaArchivoID] = @CargaArchivoID;
            SET @FilasPendientes = CASE
                WHEN COALESCE(@TotalFilas, @FilasProcesadas) > @FilasProcesadas
                    THEN COALESCE(@TotalFilas, @FilasProcesadas) - @FilasProcesadas
                ELSE 0
            END;
            SET @Resultado = 'YA_FINALIZADA';
        END
        ELSE
        BEGIN
            SELECT @FilasProcesadas = COUNT(*),
                   @FilasNuevas = COALESCE(SUM(CASE WHEN [Resultado] = 'NUEVO' THEN 1 ELSE 0 END), 0),
                   @FilasDuplicadas = COALESCE(SUM(CASE WHEN [Resultado] = 'DUPLICADO' THEN 1 ELSE 0 END), 0),
                   @FilasConflicto = COALESCE(SUM(CASE WHEN [Resultado] = 'ID_CON_CONTENIDO_DISTINTO' THEN 1 ELSE 0 END), 0),
                   @FilasRechazadas = COALESCE(SUM(CASE WHEN [Resultado] = 'RECHAZADO' THEN 1 ELSE 0 END), 0)
            FROM [contabilidad].[CargaMovimiento]
            WHERE [CargaArchivoID] = @CargaArchivoID;

            SET @TotalFilas = COALESCE(@TotalFilasEsperadas, @FilasProcesadas);
            IF @TotalFilas < @FilasProcesadas
                THROW 50853, 'TotalFilasEsperadas es menor que las filas registradas.', 1;
            SET @FilasPendientes = @TotalFilas - @FilasProcesadas;

            SELECT @FechaMinima = MIN(m.[Fecha]),
                   @FechaMaxima = MAX(m.[Fecha])
            FROM [contabilidad].[CargaMovimiento] AS cm
            JOIN [contabilidad].[MovimientoHistorico] AS m
              ON m.[MovimientoID] = cm.[MovimientoID]
            WHERE cm.[CargaArchivoID] = @CargaArchivoID
              AND cm.[Resultado] IN ('NUEVO', 'DUPLICADO');

            SET @Estado = CASE
                WHEN @TotalFilas = 0 OR @FilasProcesadas = 0 THEN 'ERROR'
                WHEN @FilasPendientes > 0 OR @FilasConflicto > 0
                     OR @FilasRechazadas > 0 THEN 'PARCIAL'
                ELSE 'OK'
            END;

            SET @MensajeFinal = COALESCE
            (
                NULLIF(LTRIM(RTRIM(@Mensaje)), N''),
                CONCAT(N'Carga finalizada. Esperadas: ', @TotalFilas,
                       N'; procesadas: ', @FilasProcesadas,
                       N'; nuevas: ', @FilasNuevas,
                       N'; duplicadas: ', @FilasDuplicadas,
                       N'; conflictos: ', @FilasConflicto,
                       N'; rechazadas: ', @FilasRechazadas,
                       N'; pendientes: ', @FilasPendientes, N'.')
            );

            UPDATE [contabilidad].[CargaArchivo]
            SET [Estado] = @Estado,
                [TotalFilas] = @TotalFilas,
                [FilasNuevas] = @FilasNuevas,
                [FilasDuplicadas] = @FilasDuplicadas,
                [FilasConflicto] = @FilasConflicto,
                [FilasRechazadas] = @FilasRechazadas,
                [FechaMinima] = @FechaMinima,
                [FechaMaxima] = @FechaMaxima,
                [Mensaje] = @MensajeFinal,
                [FechaFinUTC] = SYSUTCDATETIME()
            WHERE [CargaArchivoID] = @CargaArchivoID;
            SET @Resultado = 'FINALIZADA';
        END;

        COMMIT TRANSACTION;

        SELECT @CargaArchivoID AS [CargaArchivoID],
               @Estado AS [Estado],
               @TotalFilas AS [TotalFilas],
               @FilasProcesadas AS [FilasProcesadas],
               @FilasPendientes AS [FilasPendientes],
               @FilasNuevas AS [FilasNuevas],
               @FilasDuplicadas AS [FilasDuplicadas],
               @FilasConflicto AS [FilasConflicto],
               @FilasRechazadas AS [FilasRechazadas],
               @FechaMinima AS [FechaMinima],
               @FechaMaxima AS [FechaMaxima],
               @Resultado AS [Resultado],
               @MensajeFinal AS [Mensaje];
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
