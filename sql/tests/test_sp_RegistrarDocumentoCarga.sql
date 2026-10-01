SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

BEGIN TRANSACTION;
GO

DECLARE @NitPrueba nvarchar(20) = CONCAT(N'T', LEFT(REPLACE(CONVERT(nvarchar(36), NEWID()), N'-', N''), 19));
DECLARE @ClienteID bigint;
DECLARE @CargaArchivoID bigint;
DECLARE @DocumentoID bigint;
DECLARE @DocumentoVersionID bigint;
DECLARE @NumeroRevision int;
DECLARE @Resultado varchar(30);
DECLARE @DebeDescargarXml bit;
DECLARE @SolicitudExistente bit;
DECLARE @ClaveDocumento varchar(96) = REPLICATE('a', 96);
DECLARE @HashArchivo varchar(64) = REPLICATE('1', 64);
DECLARE @HashFila1 varchar(64) = REPLICATE('2', 64);
DECLARE @HashFila2 varchar(64) = REPLICATE('3', 64);
DECLARE @HashFila3 varchar(64) = REPLICATE('4', 64);
DECLARE @HashFila4 varchar(64) = REPLICATE('5', 64);
DECLARE @HashContenido1 varchar(64) = REPLICATE('b', 64);
DECLARE @HashContenido2 varchar(64) = REPLICATE('c', 64);
DECLARE @HashContenido3 varchar(64) = REPLICATE('d', 64);

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

INSERT INTO @ClienteResultado
EXEC [dian].[sp_RegistrarCliente]
    @Nit = @NitPrueba,
    @RazonSocial = N'Cliente de prueba de documentos';

SELECT @ClienteID = [ClienteID]
FROM @ClienteResultado;

INSERT INTO @CargaResultado
EXEC [dian].[sp_IniciarCargaArchivo]
    @ClienteID = @ClienteID,
    @NombreArchivo = N'prueba-documentos.xlsx',
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
    @Folio = N'FV-1001',
    @Prefijo = N'FV',
    @Divisa = N'COP',
    @FormaPago = N'Contado',
    @MedioPago = N'Transferencia',
    @FechaEmision = '2026-09-01',
    @FechaRecepcion = '2026-09-02T10:30:00',
    @NitEmisor = N'900111222',
    @NombreEmisor = N'Proveedor de prueba',
    @NitReceptor = @NitPrueba,
    @NombreReceptor = N'Cliente de prueba de documentos',
    @Iva = 19.0000,
    @Total = 119.0000,
    @EstadoDianOrigen = N'Aceptado',
    @GrupoOrigen = N'Recibidos',
    @HashFilaSha256 = @HashFila1,
    @HashContenidoSha256 = @HashContenido1,
    @FilaOrigenJson = N'{"fila":2,"folio":"FV-1001"}';

SELECT
    @DocumentoID = [DocumentoID],
    @DocumentoVersionID = [DocumentoVersionID],
    @NumeroRevision = [NumeroRevision],
    @Resultado = [Resultado],
    @DebeDescargarXml = [DebeDescargarXml],
    @SolicitudExistente = [SolicitudExistente]
FROM @FilaResultado;

IF @DocumentoID IS NULL
   OR @DocumentoVersionID IS NULL
   OR @NumeroRevision <> 1
   OR @Resultado <> 'NUEVO'
   OR @DebeDescargarXml <> 1
   OR @SolicitudExistente <> 0
    THROW 51201, 'La primera fila no creó correctamente el documento.', 1;

DELETE FROM @FilaResultado;

INSERT INTO @FilaResultado
EXEC [dian].[sp_RegistrarDocumentoCarga]
    @CargaArchivoID = @CargaArchivoID,
    @FilaOrigen = 2,
    @ClaveDocumento = @ClaveDocumento,
    @TipoClave = 'CUFE',
    @TipoDocumento = N'Factura electrónica',
    @Folio = N'FV-1001',
    @FechaEmision = '2026-09-01',
    @FechaRecepcion = '2026-09-02T10:30:00',
    @NitEmisor = N'900111222',
    @NombreEmisor = N'Proveedor de prueba',
    @NitReceptor = @NitPrueba,
    @NombreReceptor = N'Cliente de prueba de documentos',
    @Total = 119.0000,
    @EstadoDianOrigen = N'Aceptado',
    @GrupoOrigen = N'Recibidos',
    @HashFilaSha256 = @HashFila1,
    @HashContenidoSha256 = @HashContenido1,
    @FilaOrigenJson = N'{"fila":2,"reintento":true}';

SELECT
    @Resultado = [Resultado],
    @DebeDescargarXml = [DebeDescargarXml],
    @SolicitudExistente = [SolicitudExistente]
FROM @FilaResultado;

IF @Resultado <> 'NUEVO'
   OR @DebeDescargarXml <> 0
   OR @SolicitudExistente <> 1
    THROW 51202, 'El reintento de la misma fila no fue idempotente.', 1;

DELETE FROM @FilaResultado;

INSERT INTO @FilaResultado
EXEC [dian].[sp_RegistrarDocumentoCarga]
    @CargaArchivoID = @CargaArchivoID,
    @FilaOrigen = 3,
    @ClaveDocumento = @ClaveDocumento,
    @TipoClave = 'CUFE',
    @TipoDocumento = N'Factura electrónica',
    @Folio = N'FV-1001',
    @FechaEmision = '2026-09-01',
    @FechaRecepcion = '2026-09-02T10:30:00',
    @NitEmisor = N'900111222',
    @NombreEmisor = N'Proveedor de prueba',
    @NitReceptor = @NitPrueba,
    @NombreReceptor = N'Cliente de prueba de documentos',
    @Total = 119.0000,
    @EstadoDianOrigen = N'Aceptado',
    @GrupoOrigen = N'Recibidos',
    @HashFilaSha256 = @HashFila2,
    @HashContenidoSha256 = @HashContenido1,
    @FilaOrigenJson = N'{"fila":3,"duplicado":true}';

SELECT
    @Resultado = [Resultado],
    @DebeDescargarXml = [DebeDescargarXml],
    @SolicitudExistente = [SolicitudExistente]
FROM @FilaResultado;

IF @Resultado <> 'DUPLICADO'
   OR @DebeDescargarXml <> 0
   OR @SolicitudExistente <> 0
    THROW 51203, 'El contenido repetido no fue identificado como DUPLICADO.', 1;

DELETE FROM @FilaResultado;

INSERT INTO @FilaResultado
EXEC [dian].[sp_RegistrarDocumentoCarga]
    @CargaArchivoID = @CargaArchivoID,
    @FilaOrigen = 4,
    @ClaveDocumento = @ClaveDocumento,
    @TipoClave = 'CUFE',
    @TipoDocumento = N'Factura electrónica',
    @Folio = N'FV-1001',
    @FechaEmision = '2026-09-01',
    @FechaRecepcion = '2026-09-02T10:30:00',
    @NitEmisor = N'900111222',
    @NombreEmisor = N'Proveedor de prueba corregido',
    @NitReceptor = @NitPrueba,
    @NombreReceptor = N'Cliente de prueba de documentos',
    @Total = 120.0000,
    @EstadoDianOrigen = N'Aceptado',
    @GrupoOrigen = N'Recibidos',
    @HashFilaSha256 = @HashFila3,
    @HashContenidoSha256 = @HashContenido2,
    @FilaOrigenJson = N'{"fila":4,"revision":2}';

SELECT
    @NumeroRevision = [NumeroRevision],
    @Resultado = [Resultado],
    @DebeDescargarXml = [DebeDescargarXml]
FROM @FilaResultado;

IF @Resultado <> 'NUEVA_REVISION'
   OR @NumeroRevision <> 2
   OR @DebeDescargarXml <> 0
    THROW 51204, 'El contenido modificado no creó la segunda revisión.', 1;

DELETE FROM @FilaResultado;

INSERT INTO @FilaResultado
EXEC [dian].[sp_RegistrarDocumentoCarga]
    @CargaArchivoID = @CargaArchivoID,
    @FilaOrigen = 5,
    @ClaveDocumento = 'clave-invalida',
    @TipoClave = 'CUFE',
    @TipoDocumento = N'Factura electrónica',
    @Folio = N'FV-ERROR',
    @FechaEmision = '2026-09-01',
    @FechaRecepcion = '2026-09-02T10:30:00',
    @NitEmisor = N'900111222',
    @NombreEmisor = N'Proveedor de prueba',
    @NitReceptor = @NitPrueba,
    @NombreReceptor = N'Cliente de prueba de documentos',
    @Total = 10.0000,
    @EstadoDianOrigen = N'Aceptado',
    @GrupoOrigen = N'Recibidos',
    @HashFilaSha256 = @HashFila4,
    @HashContenidoSha256 = @HashContenido3,
    @FilaOrigenJson = N'{"fila":5,"invalida":true}';

SELECT @Resultado = [Resultado]
FROM @FilaResultado;

IF @Resultado <> 'RECHAZADO'
    THROW 51205, 'La fila con clave inválida no fue rechazada.', 1;

IF (SELECT COUNT(*) FROM [dian].[Documento] WHERE [DocumentoID] = @DocumentoID) <> 1
    THROW 51206, 'La prueba no conserva un único documento lógico.', 1;

IF (SELECT COUNT(*) FROM [dian].[DocumentoVersion] WHERE [DocumentoID] = @DocumentoID) <> 2
    THROW 51207, 'La prueba no generó exactamente dos versiones.', 1;

IF (SELECT COUNT(*) FROM [dian].[DocumentoVersion] WHERE [DocumentoID] = @DocumentoID AND [EsRevisionVigente] = 1) <> 1
    THROW 51208, 'Debe existir exactamente una revisión vigente.', 1;

IF (SELECT COUNT(*) FROM [dian].[CargaDocumento] WHERE [CargaArchivoID] = @CargaArchivoID) <> 4
    THROW 51209, 'La idempotencia de fila produjo una cantidad incorrecta de registros.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM [dian].[Documento]
    WHERE [DocumentoID] = @DocumentoID
      AND [RevisionActual] = 2
      AND [EstadoRevision] = 'PENDIENTE'
      AND [EstadoProceso] = 'REQUIERE_REVISION'
)
    THROW 51210, 'El documento no quedó pendiente de revisión.', 1;

SELECT
    'OK' AS [ResultadoPrueba],
    @ClienteID AS [ClienteIDProbado],
    @CargaArchivoID AS [CargaArchivoIDProbada],
    @DocumentoID AS [DocumentoIDProbado];
GO

ROLLBACK TRANSACTION;
GO
