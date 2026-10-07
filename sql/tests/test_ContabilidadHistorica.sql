-- Prueba transaccional: no conserva datos. Ejecutar despues de tablas,
-- procedimientos y permisos. Requiere acceso administrativo directo.
SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @ClienteID bigint;
    DECLARE @CargaArchivoID bigint;
    DECLARE @HashArchivo char(64) = REPLICATE('a', 64);
    DECLARE @Fila nvarchar(max) = N'{"Fecha":"2026-02-28","Documento":"DOC-1","TipoDoc":"CE","NumDoc":"0001","Cuenta":"510505","Concepto":"Prueba","Naturaleza":"D","Centro":null,"CC":null,"Debito":"100.00","Credito":"0","IdentidadTercero":"900123456","DocFuente":null,"IndContabilidad":"id-1"}';
    DECLARE @FilaCorregida nvarchar(max) = REPLACE(@Fila, N'"Debito":"100.00"', N'"Debito":"120.00"');
    DECLARE @FilaIdNuevo nvarchar(max) = REPLACE(@Fila, N'"IndContabilidad":"id-1"', N'"IndContabilidad":"id-2"');

    INSERT INTO [dian].[Cliente] ([Nit], [RazonSocial], [Estado])
    VALUES (CONCAT(N'TC-', LEFT(CONVERT(varchar(36), NEWID()), 16)),
            N'Prueba carga contable', 'ACTIVO');
    SET @ClienteID = CONVERT(bigint, SCOPE_IDENTITY());

    EXEC [contabilidad].[sp_IniciarCargaContable]
        @ClienteID = @ClienteID,
        @FuenteContable = N'ERP_PRUEBA',
        @NombreArchivo = N'contabilidad-prueba.xlsx',
        @NombreHoja = N'Sheet1',
        @BlobUri = N'https://ejemplo.blob.core.windows.net/cargas/contabilidad-prueba.xlsx',
        @TamanoBytes = 100,
        @HashArchivoSha256 = @HashArchivo;

    SELECT @CargaArchivoID = [CargaArchivoID]
    FROM [contabilidad].[CargaArchivo]
    WHERE [ClienteID] = @ClienteID AND [FuenteContable] = N'ERP_PRUEBA';
    IF @CargaArchivoID IS NULL
        THROW 50880, 'No se creo la carga.', 1;

    EXEC [contabilidad].[sp_IniciarCargaContable]
        @ClienteID = @ClienteID,
        @FuenteContable = N'ERP_PRUEBA',
        @NombreArchivo = N'contabilidad-prueba.xlsx',
        @NombreHoja = N'Sheet1',
        @BlobUri = N'https://ejemplo.blob.core.windows.net/cargas/contabilidad-prueba.xlsx',
        @TamanoBytes = 100,
        @HashArchivoSha256 = @HashArchivo;
    IF (SELECT COUNT(*) FROM [contabilidad].[CargaArchivo]
        WHERE [ClienteID] = @ClienteID) <> 1
        THROW 50886, 'El reenvio exacto creo una carga duplicada.', 1;

    EXEC [contabilidad].[sp_RegistrarMovimientoContable]
        @CargaArchivoID = @CargaArchivoID, @FilaOrigen = 2, @FilaJson = @Fila;
    EXEC [contabilidad].[sp_RegistrarMovimientoContable]
        @CargaArchivoID = @CargaArchivoID, @FilaOrigen = 2, @FilaJson = @Fila;
    EXEC [contabilidad].[sp_RegistrarMovimientoContable]
        @CargaArchivoID = @CargaArchivoID, @FilaOrigen = 3, @FilaJson = @Fila;
    EXEC [contabilidad].[sp_RegistrarMovimientoContable]
        @CargaArchivoID = @CargaArchivoID, @FilaOrigen = 4,
        @FilaJson = @FilaCorregida;
    EXEC [contabilidad].[sp_RegistrarMovimientoContable]
        @CargaArchivoID = @CargaArchivoID, @FilaOrigen = 5,
        @FilaJson = @FilaIdNuevo;
    EXEC [contabilidad].[sp_RegistrarMovimientoContable]
        @CargaArchivoID = @CargaArchivoID, @FilaOrigen = 6, @FilaJson = N'{}';

    IF (SELECT COUNT(*) FROM [contabilidad].[MovimientoHistorico]
        WHERE [ClienteID] = @ClienteID) <> 2
        THROW 50881, 'Se esperaban dos movimientos.', 1;
    IF (SELECT COUNT(*) FROM [contabilidad].[CargaMovimiento]
        WHERE [CargaArchivoID] = @CargaArchivoID) <> 5
        THROW 50882, 'Se esperaban cinco filas auditadas.', 1;
    IF (SELECT [Debito] FROM [contabilidad].[MovimientoHistorico]
        WHERE [ClienteID] = @ClienteID AND [IndContabilidad] = N'id-1') <> 100
        THROW 50883, 'El conflicto modifico la primera version.', 1;
    IF EXISTS
    (
        SELECT 1 FROM [contabilidad].[CargaMovimiento]
        WHERE [CargaArchivoID] = @CargaArchivoID
          AND (([FilaOrigen] = 2 AND [Resultado] <> 'NUEVO')
            OR ([FilaOrigen] = 3 AND [Resultado] <> 'DUPLICADO')
            OR ([FilaOrigen] = 4 AND [Resultado] <> 'ID_CON_CONTENIDO_DISTINTO')
            OR ([FilaOrigen] = 5 AND [Resultado] <> 'NUEVO')
            OR ([FilaOrigen] = 6 AND [Resultado] <> 'RECHAZADO'))
    )
        THROW 50884, 'Un resultado de fila es incorrecto.', 1;

    EXEC [contabilidad].[sp_FinalizarCargaContable]
        @CargaArchivoID = @CargaArchivoID,
        @TotalFilasEsperadas = 5;
    EXEC [contabilidad].[sp_FinalizarCargaContable]
        @CargaArchivoID = @CargaArchivoID,
        @TotalFilasEsperadas = 5;

    IF NOT EXISTS
    (
        SELECT 1 FROM [contabilidad].[CargaArchivo]
        WHERE [CargaArchivoID] = @CargaArchivoID
          AND [Estado] = 'PARCIAL' AND [TotalFilas] = 5
          AND [FilasNuevas] = 2 AND [FilasDuplicadas] = 1
          AND [FilasConflicto] = 1 AND [FilasRechazadas] = 1
    )
        THROW 50885, 'Los contadores finales son incorrectos.', 1;

    ROLLBACK TRANSACTION;
    SELECT N'OK' AS [ResultadoPruebaContabilidad];
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
