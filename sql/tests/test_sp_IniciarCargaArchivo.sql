SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

BEGIN TRANSACTION;
GO

DECLARE @ClienteID bigint;
DECLARE @PrimeraCargaID bigint;
DECLARE @ReintentoCargaID bigint;
DECLARE @DuplicadoCargaID bigint;
DECLARE @DuplicadoOriginalID bigint;
DECLARE @DebeProcesar bit;
DECLARE @Resultado varchar(30);
DECLARE @ResultadoTabla TABLE
(
    [CargaArchivoID] bigint,
    [CargaOriginalID] bigint NULL,
    [Estado] varchar(30),
    [Resultado] varchar(30),
    [DebeProcesar] bit
);

INSERT INTO [dian].[Cliente] ([Nit], [RazonSocial])
VALUES (CONCAT(N'T', LEFT(REPLACE(CONVERT(nvarchar(36), NEWID()), N'-', N''), 19)), N'Cliente de prueba transaccional');

SET @ClienteID = SCOPE_IDENTITY();

INSERT INTO @ResultadoTabla
EXEC [dian].[sp_IniciarCargaArchivo]
    @ClienteID = @ClienteID,
    @NombreArchivo = N'archivo-1.xlsx',
    @HashArchivoSha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    @SharePointItemID = N'item-1',
    @SharePointUrl = N'https://example.invalid/archivo-1.xlsx',
    @ETag = N'etag-1',
    @NombreTablaOrigen = N'Tabla1',
    @CargadoPor = N'prueba';

SELECT
    @PrimeraCargaID = [CargaArchivoID],
    @Resultado = [Resultado],
    @DebeProcesar = [DebeProcesar]
FROM @ResultadoTabla;

IF @Resultado <> 'NUEVA_CARGA' OR @DebeProcesar <> 1
    THROW 51001, 'La primera llamada no fue registrada como NUEVA_CARGA.', 1;

DELETE FROM @ResultadoTabla;

INSERT INTO @ResultadoTabla
EXEC [dian].[sp_IniciarCargaArchivo]
    @ClienteID = @ClienteID,
    @NombreArchivo = N'archivo-1.xlsx',
    @HashArchivoSha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    @SharePointItemID = N'item-1',
    @SharePointUrl = N'https://example.invalid/archivo-1.xlsx',
    @ETag = N'etag-1',
    @NombreTablaOrigen = N'Tabla1',
    @CargadoPor = N'prueba';

SELECT
    @ReintentoCargaID = [CargaArchivoID],
    @Resultado = [Resultado],
    @DebeProcesar = [DebeProcesar]
FROM @ResultadoTabla;

IF @Resultado <> 'SOLICITUD_EXISTENTE'
   OR @ReintentoCargaID <> @PrimeraCargaID
   OR @DebeProcesar <> 1
    THROW 51002, 'El reintento no devolvió la carga original.', 1;

DELETE FROM @ResultadoTabla;

INSERT INTO @ResultadoTabla
EXEC [dian].[sp_IniciarCargaArchivo]
    @ClienteID = @ClienteID,
    @NombreArchivo = N'archivo-2.xlsx',
    @HashArchivoSha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    @SharePointItemID = N'item-2',
    @SharePointUrl = N'https://example.invalid/archivo-2.xlsx',
    @ETag = N'etag-2',
    @NombreTablaOrigen = N'Tabla2',
    @CargadoPor = N'prueba';

SELECT
    @DuplicadoCargaID = [CargaArchivoID],
    @DuplicadoOriginalID = [CargaOriginalID],
    @Resultado = [Resultado],
    @DebeProcesar = [DebeProcesar]
FROM @ResultadoTabla;

IF @Resultado <> 'SIN_CAMBIOS'
   OR @DuplicadoCargaID = @PrimeraCargaID
   OR @DuplicadoOriginalID <> @PrimeraCargaID
   OR @DebeProcesar <> 0
    THROW 51003, 'El archivo repetido no fue registrado como SIN_CAMBIOS.', 1;

UPDATE [dian].[CargaArchivo]
SET [Estado] = 'ERROR',
    [FechaFinUTC] = sysutcdatetime(),
    [Mensaje] = N'Error simulado por la prueba.'
WHERE [CargaArchivoID] = @PrimeraCargaID;

DELETE FROM @ResultadoTabla;

INSERT INTO @ResultadoTabla
EXEC [dian].[sp_IniciarCargaArchivo]
    @ClienteID = @ClienteID,
    @NombreArchivo = N'archivo-1.xlsx',
    @HashArchivoSha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    @SharePointItemID = N'item-1',
    @SharePointUrl = N'https://example.invalid/archivo-1.xlsx',
    @ETag = N'etag-1',
    @NombreTablaOrigen = N'Tabla1',
    @CargadoPor = N'prueba';

SELECT
    @ReintentoCargaID = [CargaArchivoID],
    @Resultado = [Resultado],
    @DebeProcesar = [DebeProcesar]
FROM @ResultadoTabla;

IF @Resultado <> 'REINTENTO'
   OR @ReintentoCargaID <> @PrimeraCargaID
   OR @DebeProcesar <> 1
    THROW 51004, 'La carga en ERROR no fue reactivada como REINTENTO.', 1;

BEGIN TRY
    EXEC [dian].[sp_IniciarCargaArchivo]
        @ClienteID = @ClienteID,
        @NombreArchivo = N'invalido.xlsx',
        @HashArchivoSha256 = 'hash-invalido';

    THROW 51005, 'El procedimiento aceptó un hash inválido.', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 50003
        THROW;
END CATCH;

BEGIN TRY
    EXEC [dian].[sp_IniciarCargaArchivo]
        @ClienteID = @ClienteID,
        @NombreArchivo = N'invalido-largo.xlsx',
        @HashArchivoSha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

    THROW 51006, 'El procedimiento truncó y aceptó un hash de 65 caracteres.', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 50003
        THROW;
END CATCH;

IF (SELECT COUNT(*) FROM [dian].[CargaArchivo] WHERE [ClienteID] = @ClienteID) <> 2
    THROW 51007, 'La cantidad de cargas creada no corresponde al comportamiento esperado.', 1;

ROLLBACK TRANSACTION;
GO

SELECT N'OK' AS [ResultadoPrueba];
GO
