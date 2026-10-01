SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

BEGIN TRANSACTION;
GO

DECLARE @NitPrueba nvarchar(20) = CONCAT(N'T', LEFT(REPLACE(CONVERT(nvarchar(36), NEWID()), N'-', N''), 19));
DECLARE @ClienteID bigint;
DECLARE @CargaArchivoID bigint;
DECLARE @Estado varchar(30);
DECLARE @Resultado varchar(30);
DECLARE @TotalFilas int;
DECLARE @FilasProcesadas int;
DECLARE @FilasPendientes int;
DECLARE @FilasValidas int;
DECLARE @FilasError int;
DECLARE @ClaveDocumento varchar(96) = REPLICATE('e', 96);
DECLARE @HashArchivo varchar(64) = REPLICATE('6', 64);
DECLARE @HashFilaValida varchar(64) = REPLICATE('7', 64);
DECLARE @HashContenidoValido varchar(64) = REPLICATE('8', 64);
DECLARE @HashFilaInvalida varchar(64) = REPLICATE('9', 64);
DECLARE @HashContenidoInvalido varchar(64) = REPLICATE('a', 64);

DECLARE @ClienteResultado TABLE
(
    [ClienteID] bigint,
    [Nit] nvarchar(20),
    [RazonSocial] nvarchar(300),
    [Estado] varchar(10),
    [Resultado] varchar(30),
    [Creado] bit,
    [RequiereRevision] bit
);

DECLARE @CargaResultado TABLE
(
    [CargaArchivoID] bigint,
    [CargaOriginalID] bigint NULL,
    [Estado] varchar(30),
    [Resultado] varchar(30),
    [DebeProcesar] bit
);

DECLARE @FilaResultado TABLE
(
    [CargaArchivoID] bigint,
    [FilaOrigen] int,
    [DocumentoID] bigint NULL,
    [DocumentoVersionID] bigint NULL,
    [NumeroRevision] int NULL,
    [Resultado] varchar(30),
    [EstadoRevision] varchar(20) NULL,
    [EstadoProceso] varchar(30) NULL,
    [DebeDescargarXml] bit,
    [SolicitudExistente] bit,
    [ErrorValidacion] nvarchar(1000) NULL
);

DECLARE @FinalizacionResultado TABLE
(
    [CargaArchivoID] bigint,
    [Estado] varchar(30),
    [TotalFilas] int,
    [FilasProcesadas] int,
    [FilasPendientes] int,
    [FilasValidas] int,
    [FilasDuplicadas] int,
    [FilasRevision] int,
    [FilasError] int,
    [Resultado] varchar(30),
    [Mensaje] nvarchar(2000)
);

INSERT INTO @ClienteResultado
EXEC [dian].[sp_RegistrarCliente]
    @Nit = @NitPrueba,
    @RazonSocial = N'Cliente de prueba de finalización';

SELECT @ClienteID = [ClienteID]
FROM @ClienteResultado;

INSERT INTO @CargaResultado
EXEC [dian].[sp_IniciarCargaArchivo]
    @ClienteID = @ClienteID,
    @NombreArchivo = N'prueba-finalizacion.xlsx',
    @HashArchivoSha256 = @HashArchivo,
    @CargadoPor = N'prueba-sql';

SELECT @CargaArchivoID = [CargaArchivoID]
FROM @CargaResultado;

INSERT INTO @FilaResultado
EXEC [dian].[sp_RegistrarDocumentoCarga]
    @CargaArchivoID = @CargaArchivoID,
    @FilaOrigen = 2,
    @ClaveDocumento = @ClaveDocumento,
    @TipoClave = 'CUFE',
    @TipoDocumento = N'Factura electrónica',
    @Folio = N'FV-2001',
    @FechaEmision = '2026-09-01',
    @FechaRecepcion = '2026-09-02T10:30:00',
    @NitEmisor = N'900111222',
    @NombreEmisor = N'Proveedor de prueba',
    @NitReceptor = @NitPrueba,
    @NombreReceptor = N'Cliente de prueba de finalización',
    @Total = 100.0000,
    @EstadoDianOrigen = N'Aceptado',
    @GrupoOrigen = N'Recibidos',
    @HashFilaSha256 = @HashFilaValida,
    @HashContenidoSha256 = @HashContenidoValido,
    @FilaOrigenJson = N'{"fila":2,"valida":true}';

DELETE FROM @FilaResultado;

INSERT INTO @FilaResultado
EXEC [dian].[sp_RegistrarDocumentoCarga]
    @CargaArchivoID = @CargaArchivoID,
    @FilaOrigen = 3,
    @ClaveDocumento = 'invalida',
    @TipoClave = 'CUFE',
    @TipoDocumento = N'Factura electrónica',
    @Folio = N'FV-ERROR',
    @FechaEmision = '2026-09-01',
    @FechaRecepcion = '2026-09-02T10:30:00',
    @NitEmisor = N'900111222',
    @NombreEmisor = N'Proveedor de prueba',
    @NitReceptor = @NitPrueba,
    @NombreReceptor = N'Cliente de prueba de finalización',
    @Total = 10.0000,
    @EstadoDianOrigen = N'Aceptado',
    @GrupoOrigen = N'Recibidos',
    @HashFilaSha256 = @HashFilaInvalida,
    @HashContenidoSha256 = @HashContenidoInvalido,
    @FilaOrigenJson = N'{"fila":3,"valida":false}';

INSERT INTO @FinalizacionResultado
EXEC [dian].[sp_FinalizarCargaArchivo]
    @CargaArchivoID = @CargaArchivoID,
    @TotalFilasEsperadas = 3;

SELECT
    @Estado = [Estado],
    @Resultado = [Resultado],
    @TotalFilas = [TotalFilas],
    @FilasProcesadas = [FilasProcesadas],
    @FilasPendientes = [FilasPendientes],
    @FilasValidas = [FilasValidas],
    @FilasError = [FilasError]
FROM @FinalizacionResultado;

IF @Estado <> 'PARCIAL'
   OR @Resultado <> 'FINALIZADA'
   OR @TotalFilas <> 3
   OR @FilasProcesadas <> 2
   OR @FilasPendientes <> 1
   OR @FilasValidas <> 1
   OR @FilasError <> 1
    THROW 51301, 'La carga parcial no calculó correctamente sus contadores.', 1;

DELETE FROM @FinalizacionResultado;

INSERT INTO @FinalizacionResultado
EXEC [dian].[sp_FinalizarCargaArchivo]
    @CargaArchivoID = @CargaArchivoID,
    @TotalFilasEsperadas = 3;

SELECT
    @Estado = [Estado],
    @Resultado = [Resultado]
FROM @FinalizacionResultado;

IF @Estado <> 'PARCIAL' OR @Resultado <> 'YA_FINALIZADA'
    THROW 51302, 'La finalización repetida no fue idempotente.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM [dian].[CargaArchivo]
    WHERE [CargaArchivoID] = @CargaArchivoID
      AND [Estado] = 'PARCIAL'
      AND [TotalFilas] = 3
      AND [FilasValidas] = 1
      AND [FilasError] = 1
      AND [FechaFinUTC] IS NOT NULL
)
    THROW 51303, 'La carga no conservó el resumen final esperado.', 1;

SELECT
    'OK' AS [ResultadoPrueba],
    @CargaArchivoID AS [CargaArchivoIDProbada],
    @Estado AS [EstadoProbado];
GO

ROLLBACK TRANSACTION;
GO
