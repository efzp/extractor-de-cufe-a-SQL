-- Recreacion del esquema DIAN desde los archivos fuente de sql/.
-- No elimina objetos ni datos: requiere que el bloque de limpieza haya terminado.
-- Compatible con una sola ejecucion en el editor web de Azure SQL (sin GO).
-- Origen: sql/README.md. No usar junto con el script de reintentos.
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'sqldb-dian-xml-cpabaas-dev'
    THROW 51040, 'Conectado a una base distinta de sqldb-dian-xml-cpabaas-dev.', 1;

IF EXISTS (SELECT 1 FROM sys.tables WHERE schema_id = SCHEMA_ID(N'dian'))
   OR EXISTS (SELECT 1 FROM sys.procedures WHERE schema_id = SCHEMA_ID(N'dian'))
    THROW 51041, 'El esquema dian aun tiene tablas o procedimientos; no se modifico nada.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    -- Fuente: sql/migrations/001_create_schema.sql
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE [name] = N'dian')
        EXEC(N'CREATE SCHEMA [dian] AUTHORIZATION [dbo];');

    -- Fuente: sql/security/dian_runtime.sql
    SET XACT_ABORT ON;
    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.database_principals
        WHERE [name] = N'dian_runtime'
          AND [type] = 'R'
    )
        EXEC(N'CREATE ROLE [dian_runtime] AUTHORIZATION [dbo];');
    -- No se conceden permisos generales sobre tablas al rol. Cada procedimiento
    -- autorizado debe conceder EXECUTE explícitamente en su propio script.

    -- Fuente: sql/tables/Cliente.sql
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;
    CREATE TABLE [dian].[Cliente]
    (
        [ClienteID] bigint IDENTITY(1,1) NOT NULL,
        [Nit] nvarchar(20) NOT NULL,
        [RazonSocial] nvarchar(300) NOT NULL,
        [Estado] varchar(10) CONSTRAINT [DF_DianCliente_Estado] DEFAULT ('ACTIVO') NOT NULL,
        [FechaCreacionUTC] datetime2(3) CONSTRAINT [DF_DianCliente_FechaCreacion] DEFAULT (sysutcdatetime()) NOT NULL,
        [FechaActualizacionUTC] datetime2(3) CONSTRAINT [DF_DianCliente_FechaActualizacion] DEFAULT (sysutcdatetime()) NOT NULL,
        [RowVersion] rowversion NOT NULL,
        CONSTRAINT [PK_DianCliente] PRIMARY KEY CLUSTERED ([ClienteID]),
        CONSTRAINT [UQ_DianCliente_Nit] UNIQUE ([Nit]),
        CONSTRAINT [CK_DianCliente_Estado] CHECK ([Estado] IN ('ACTIVO', 'INACTIVO'))
    );

    -- Fuente: sql/tables/CargaArchivo.sql
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;
    CREATE TABLE [dian].[CargaArchivo]
    (
        [CargaArchivoID] bigint IDENTITY(1,1) NOT NULL,
        [ClienteID] bigint NOT NULL,
        [CargaOriginalID] bigint NULL,
        [NombreArchivo] nvarchar(260) NOT NULL,
        [SharePointItemID] nvarchar(150) NULL,
        [SharePointUrl] nvarchar(1000) NULL,
        [ETag] nvarchar(200) NULL,
        [HashArchivoSha256] char(64) NULL,
        [NombreTablaOrigen] nvarchar(128) NULL,
        [CargadoPor] nvarchar(256) NULL,
        [FechaInicioUTC] datetime2(3) CONSTRAINT [DF_DianCargaArchivo_FechaInicio] DEFAULT (sysutcdatetime()) NOT NULL,
        [FechaFinUTC] datetime2(3) NULL,
        [Estado] varchar(30) CONSTRAINT [DF_DianCargaArchivo_Estado] DEFAULT ('RECIBIDA') NOT NULL,
        [TotalFilas] int NULL,
        [FilasValidas] int NULL,
        [FilasDuplicadas] int NULL,
        [FilasRevision] int NULL,
        [FilasError] int NULL,
        [Mensaje] nvarchar(2000) NULL,
        [RowVersion] rowversion NOT NULL,
        CONSTRAINT [PK_DianCargaArchivo] PRIMARY KEY CLUSTERED ([CargaArchivoID]),
        CONSTRAINT [FK_DianCargaArchivo_Cliente] FOREIGN KEY ([ClienteID]) REFERENCES [dian].[Cliente] ([ClienteID]),
        CONSTRAINT [FK_DianCargaArchivo_Original] FOREIGN KEY ([CargaOriginalID]) REFERENCES [dian].[CargaArchivo] ([CargaArchivoID]),
        CONSTRAINT [CK_DianCargaArchivo_Estado] CHECK ([Estado] IN ('RECIBIDA', 'PROCESANDO', 'OK', 'PARCIAL', 'SIN_CAMBIOS', 'REQUIERE_REVISION', 'ERROR')),
        CONSTRAINT [CK_DianCargaArchivo_Conteos] CHECK
        (
            ([TotalFilas] IS NULL OR [TotalFilas] >= 0) AND
            ([FilasValidas] IS NULL OR [FilasValidas] >= 0) AND
            ([FilasDuplicadas] IS NULL OR [FilasDuplicadas] >= 0) AND
            ([FilasRevision] IS NULL OR [FilasRevision] >= 0) AND
            ([FilasError] IS NULL OR [FilasError] >= 0)
        )
    );
    CREATE INDEX [IX_DianCargaArchivo_ClienteHash]
        ON [dian].[CargaArchivo] ([ClienteID], [HashArchivoSha256], [Estado]);
    CREATE UNIQUE INDEX [UX_DianCargaArchivo_SharePointVersion]
        ON [dian].[CargaArchivo] ([ClienteID], [SharePointItemID], [ETag])
        WHERE [SharePointItemID] IS NOT NULL
          AND [ETag] IS NOT NULL;

    -- Fuente: sql/tables/Documento.sql
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;
    CREATE TABLE [dian].[Documento]
    (
        [DocumentoID] bigint IDENTITY(1,1) NOT NULL,
        [ClienteID] bigint NOT NULL,
        [ClaveDocumento] char(96) NOT NULL,
        [TipoClave] varchar(4) NOT NULL,
        [TipoDocumento] nvarchar(80) NOT NULL,
        [RevisionActual] int CONSTRAINT [DF_DianDocumento_RevisionActual] DEFAULT (1) NOT NULL,
        [EstadoRevision] varchar(20) CONSTRAINT [DF_DianDocumento_EstadoRevision] DEFAULT ('NO_REQUIERE') NOT NULL,
        [MotivoRevision] nvarchar(1000) NULL,
        [EstadoProceso] varchar(30) CONSTRAINT [DF_DianDocumento_EstadoProceso] DEFAULT ('REGISTRADO') NOT NULL,
        [PrimeraCargaID] bigint NOT NULL,
        [UltimaCargaID] bigint NOT NULL,
        [FechaCreacionUTC] datetime2(3) CONSTRAINT [DF_DianDocumento_FechaCreacion] DEFAULT (sysutcdatetime()) NOT NULL,
        [FechaActualizacionUTC] datetime2(3) CONSTRAINT [DF_DianDocumento_FechaActualizacion] DEFAULT (sysutcdatetime()) NOT NULL,
        [RowVersion] rowversion NOT NULL,
        CONSTRAINT [PK_DianDocumento] PRIMARY KEY CLUSTERED ([DocumentoID]),
        CONSTRAINT [UQ_DianDocumento_ClienteClave] UNIQUE ([ClienteID], [ClaveDocumento]),
        CONSTRAINT [FK_DianDocumento_Cliente] FOREIGN KEY ([ClienteID]) REFERENCES [dian].[Cliente] ([ClienteID]),
        CONSTRAINT [FK_DianDocumento_PrimeraCarga] FOREIGN KEY ([PrimeraCargaID]) REFERENCES [dian].[CargaArchivo] ([CargaArchivoID]),
        CONSTRAINT [FK_DianDocumento_UltimaCarga] FOREIGN KEY ([UltimaCargaID]) REFERENCES [dian].[CargaArchivo] ([CargaArchivoID]),
        CONSTRAINT [CK_DianDocumento_Clave] CHECK
        (
            LEN([ClaveDocumento]) = 96 AND
            [ClaveDocumento] COLLATE Latin1_General_100_BIN2 NOT LIKE '%[^0-9a-f]%'
        ),
        CONSTRAINT [CK_DianDocumento_TipoClave] CHECK ([TipoClave] IN ('CUFE', 'CUDE')),
        CONSTRAINT [CK_DianDocumento_RevisionActual] CHECK ([RevisionActual] >= 1),
        CONSTRAINT [CK_DianDocumento_EstadoRevision] CHECK ([EstadoRevision] IN ('NO_REQUIERE', 'PENDIENTE', 'APROBADO', 'RECHAZADO')),
        CONSTRAINT [CK_DianDocumento_EstadoProceso] CHECK ([EstadoProceso] IN ('REGISTRADO', 'PENDIENTE_DESCARGA', 'CONSULTANDO_DIAN', 'XML_DESCARGADO', 'PROCESADO', 'NO_ENCONTRADO', 'REQUIERE_REVISION', 'ERROR'))
    );
    CREATE INDEX [IX_DianDocumento_Cola]
        ON [dian].[Documento] ([EstadoProceso], [ClienteID], [DocumentoID]);
    CREATE INDEX [IX_DianDocumento_Revision]
        ON [dian].[Documento] ([EstadoRevision], [ClienteID], [DocumentoID]);

    -- Fuente: sql/tables/DocumentoVersion.sql
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;
    CREATE TABLE [dian].[DocumentoVersion]
    (
        [DocumentoVersionID] bigint IDENTITY(1,1) NOT NULL,
        [DocumentoID] bigint NOT NULL,
        [NumeroRevision] int NOT NULL,
        [HashContenidoSha256] char(64) NOT NULL,
        [TipoDocumentoOrigen] nvarchar(80) NOT NULL,
        [Folio] nvarchar(50) NOT NULL,
        [Prefijo] nvarchar(30) NULL,
        [Divisa] nvarchar(10) NULL,
        [FormaPago] nvarchar(20) NULL,
        [MedioPago] nvarchar(20) NULL,
        [FechaEmision] date NOT NULL,
        [FechaRecepcion] datetime2(0) NOT NULL,
        [NitEmisor] nvarchar(20) NOT NULL,
        [NombreEmisor] nvarchar(300) NOT NULL,
        [NitReceptor] nvarchar(20) NOT NULL,
        [NombreReceptor] nvarchar(300) NOT NULL,
        [Iva] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_Iva] DEFAULT (0) NOT NULL,
        [Ica] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_Ica] DEFAULT (0) NOT NULL,
        [Ic] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_Ic] DEFAULT (0) NOT NULL,
        [Inc] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_Inc] DEFAULT (0) NOT NULL,
        [Timbre] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_Timbre] DEFAULT (0) NOT NULL,
        [IncBolsas] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_IncBolsas] DEFAULT (0) NOT NULL,
        [InCarbono] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_InCarbono] DEFAULT (0) NOT NULL,
        [InCombustibles] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_InCombustibles] DEFAULT (0) NOT NULL,
        [IcDatos] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_IcDatos] DEFAULT (0) NOT NULL,
        [Icl] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_Icl] DEFAULT (0) NOT NULL,
        [Inpp] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_Inpp] DEFAULT (0) NOT NULL,
        [Ibua] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_Ibua] DEFAULT (0) NOT NULL,
        [Icui] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_Icui] DEFAULT (0) NOT NULL,
        [ReteIva] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_ReteIva] DEFAULT (0) NOT NULL,
        [ReteRenta] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_ReteRenta] DEFAULT (0) NOT NULL,
        [ReteIca] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_ReteIca] DEFAULT (0) NOT NULL,
        [Total] decimal(19,4) NOT NULL,
        [EstadoDianOrigen] nvarchar(100) NOT NULL,
        [GrupoOrigen] nvarchar(50) NOT NULL,
        [EstadoRevision] varchar(20) CONSTRAINT [DF_DianDocumentoVersion_EstadoRevision] DEFAULT ('NO_REQUIERE') NOT NULL,
        [MotivoRevision] nvarchar(1000) NULL,
        [RevisadoPor] nvarchar(256) NULL,
        [FechaRevisionUTC] datetime2(3) NULL,
        [EsRevisionVigente] bit CONSTRAINT [DF_DianDocumentoVersion_EsVigente] DEFAULT (0) NOT NULL,
        [CargaCreacionID] bigint NOT NULL,
        [FechaCreacionUTC] datetime2(3) CONSTRAINT [DF_DianDocumentoVersion_FechaCreacion] DEFAULT (sysutcdatetime()) NOT NULL,
        [RowVersion] rowversion NOT NULL,
        CONSTRAINT [PK_DianDocumentoVersion] PRIMARY KEY CLUSTERED ([DocumentoVersionID]),
        CONSTRAINT [UQ_DianDocumentoVersion_Numero] UNIQUE ([DocumentoID], [NumeroRevision]),
        CONSTRAINT [UQ_DianDocumentoVersion_Hash] UNIQUE ([DocumentoID], [HashContenidoSha256]),
        CONSTRAINT [FK_DianDocumentoVersion_Documento] FOREIGN KEY ([DocumentoID]) REFERENCES [dian].[Documento] ([DocumentoID]),
        CONSTRAINT [FK_DianDocumentoVersion_Carga] FOREIGN KEY ([CargaCreacionID]) REFERENCES [dian].[CargaArchivo] ([CargaArchivoID]),
        CONSTRAINT [CK_DianDocumentoVersion_Numero] CHECK ([NumeroRevision] >= 1),
        CONSTRAINT [CK_DianDocumentoVersion_EstadoRevision] CHECK ([EstadoRevision] IN ('NO_REQUIERE', 'PENDIENTE', 'APROBADO', 'RECHAZADO'))
    );
    CREATE UNIQUE INDEX [UX_DianDocumentoVersion_Vigente]
        ON [dian].[DocumentoVersion] ([DocumentoID])
        WHERE [EsRevisionVigente] = 1;

    -- Fuente: sql/tables/CargaDocumento.sql
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;
    CREATE TABLE [dian].[CargaDocumento]
    (
        [CargaArchivoID] bigint NOT NULL,
        [FilaOrigen] int NOT NULL,
        [DocumentoID] bigint NULL,
        [DocumentoVersionID] bigint NULL,
        [HashFilaSha256] char(64) NULL,
        [FilaOrigenJson] nvarchar(max) NOT NULL,
        [EsValida] bit CONSTRAINT [DF_DianCargaDocumento_EsValida] DEFAULT (0) NOT NULL,
        [Resultado] varchar(20) NOT NULL,
        [ErrorValidacion] nvarchar(1000) NULL,
        [FechaRegistroUTC] datetime2(3) CONSTRAINT [DF_DianCargaDocumento_FechaRegistro] DEFAULT (sysutcdatetime()) NOT NULL,
        [RowVersion] rowversion NOT NULL,
        CONSTRAINT [PK_DianCargaDocumento] PRIMARY KEY CLUSTERED ([CargaArchivoID], [FilaOrigen]),
        CONSTRAINT [FK_DianCargaDocumento_Carga] FOREIGN KEY ([CargaArchivoID]) REFERENCES [dian].[CargaArchivo] ([CargaArchivoID]),
        CONSTRAINT [FK_DianCargaDocumento_Documento] FOREIGN KEY ([DocumentoID]) REFERENCES [dian].[Documento] ([DocumentoID]),
        CONSTRAINT [FK_DianCargaDocumento_Version] FOREIGN KEY ([DocumentoVersionID]) REFERENCES [dian].[DocumentoVersion] ([DocumentoVersionID]),
        CONSTRAINT [CK_DianCargaDocumento_Fila] CHECK ([FilaOrigen] >= 2),
        CONSTRAINT [CK_DianCargaDocumento_Json] CHECK (ISJSON([FilaOrigenJson]) = 1),
        CONSTRAINT [CK_DianCargaDocumento_Resultado] CHECK ([Resultado] IN ('NUEVO', 'DUPLICADO', 'NUEVA_REVISION', 'RECHAZADO'))
    );
    CREATE INDEX [IX_DianCargaDocumento_Documento]
        ON [dian].[CargaDocumento] ([DocumentoID], [CargaArchivoID]);

    -- Fuente: sql/tables/DocumentoProcesoHistorial.sql
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;
    CREATE TABLE [dian].[DocumentoProcesoHistorial]
    (
        [ProcesoHistorialID] bigint IDENTITY(1,1) NOT NULL,
        [DocumentoID] bigint NOT NULL,
        [CargaArchivoID] bigint NULL,
        [EstadoAnterior] varchar(30) NULL,
        [EstadoNuevo] varchar(30) NOT NULL,
        [TipoEvento] varchar(40) NOT NULL,
        [Origen] varchar(30) NOT NULL,
        [Actor] nvarchar(256) NULL,
        [DetalleJson] nvarchar(max) NULL,
        [FechaEventoUTC] datetime2(3) CONSTRAINT [DF_DianDocumentoProceso_Fecha] DEFAULT (sysutcdatetime()) NOT NULL,
        CONSTRAINT [PK_DianDocumentoProcesoHistorial] PRIMARY KEY CLUSTERED ([ProcesoHistorialID]),
        CONSTRAINT [FK_DianDocumentoProceso_Documento] FOREIGN KEY ([DocumentoID]) REFERENCES [dian].[Documento] ([DocumentoID]),
        CONSTRAINT [FK_DianDocumentoProceso_Carga] FOREIGN KEY ([CargaArchivoID]) REFERENCES [dian].[CargaArchivo] ([CargaArchivoID]),
        CONSTRAINT [CK_DianDocumentoProceso_Origen] CHECK ([Origen] IN ('POWER_AUTOMATE', 'FUNCTION', 'DIAN', 'USUARIO', 'SISTEMA')),
        CONSTRAINT [CK_DianDocumentoProceso_DetalleJson] CHECK ([DetalleJson] IS NULL OR ISJSON([DetalleJson]) = 1)
    );
    CREATE INDEX [IX_DianDocumentoProceso_DocumentoFecha]
        ON [dian].[DocumentoProcesoHistorial] ([DocumentoID], [FechaEventoUTC] DESC);

    -- Fuente: sql/tables/ConsultaDian.sql
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;
    CREATE TABLE [dian].[ConsultaDian]
    (
        [ConsultaDianID] bigint IDENTITY(1,1) NOT NULL,
        [DocumentoID] bigint NOT NULL,
        [NumeroIntento] smallint NOT NULL,
        [FechaInicioUTC] datetime2(3) CONSTRAINT [DF_DianConsulta_FechaInicio] DEFAULT (sysutcdatetime()) NOT NULL,
        [FechaFinUTC] datetime2(3) NULL,
        [Estado] varchar(20) NOT NULL,
        [CodigoDian] nvarchar(50) NULL,
        [MensajeDianSanitizado] nvarchar(1000) NULL,
        [HttpStatus] smallint NULL,
        [DuracionMs] int NULL,
        [CorrelationID] uniqueidentifier CONSTRAINT [DF_DianConsulta_Correlation] DEFAULT (newsequentialid()) NOT NULL,
        [ErrorTipo] nvarchar(100) NULL,
        [RowVersion] rowversion NOT NULL,
        CONSTRAINT [PK_DianConsulta] PRIMARY KEY CLUSTERED ([ConsultaDianID]),
        CONSTRAINT [UQ_DianConsulta_Intento] UNIQUE ([DocumentoID], [NumeroIntento]),
        CONSTRAINT [UQ_DianConsulta_Correlation] UNIQUE ([CorrelationID]),
        CONSTRAINT [FK_DianConsulta_Documento] FOREIGN KEY ([DocumentoID]) REFERENCES [dian].[Documento] ([DocumentoID]),
        CONSTRAINT [CK_DianConsulta_NumeroIntento] CHECK ([NumeroIntento] >= 1),
        CONSTRAINT [CK_DianConsulta_Estado] CHECK ([Estado] IN ('INICIADA', 'OK', 'NO_ENCONTRADO', 'ERROR', 'REINTENTO')),
        CONSTRAINT [CK_DianConsulta_Duracion] CHECK ([DuracionMs] IS NULL OR [DuracionMs] >= 0)
    );
    CREATE INDEX [IX_DianConsulta_DocumentoFecha]
        ON [dian].[ConsultaDian] ([DocumentoID], [FechaInicioUTC] DESC);

    -- Fuente: sql/tables/DocumentoXml.sql
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;
    CREATE TABLE [dian].[DocumentoXml]
    (
        [DocumentoXmlID] bigint IDENTITY(1,1) NOT NULL,
        [DocumentoID] bigint NOT NULL,
        [ConsultaDianID] bigint NOT NULL,
        [BlobUri] nvarchar(1000) NOT NULL,
        [HashXmlSha256] char(64) NOT NULL,
        [TamanoBytes] bigint NOT NULL,
        [TipoContenido] nvarchar(100) CONSTRAINT [DF_DianDocumentoXml_TipoContenido] DEFAULT ('application/xml') NOT NULL,
        [TipoXmlDetectado] nvarchar(80) NULL,
        [FechaAlmacenamientoUTC] datetime2(3) CONSTRAINT [DF_DianDocumentoXml_Fecha] DEFAULT (sysutcdatetime()) NOT NULL,
        [EsVigente] bit CONSTRAINT [DF_DianDocumentoXml_EsVigente] DEFAULT (1) NOT NULL,
        [RowVersion] rowversion NOT NULL,
        CONSTRAINT [PK_DianDocumentoXml] PRIMARY KEY CLUSTERED ([DocumentoXmlID]),
        CONSTRAINT [UQ_DianDocumentoXml_Hash] UNIQUE ([DocumentoID], [HashXmlSha256]),
        CONSTRAINT [FK_DianDocumentoXml_Documento] FOREIGN KEY ([DocumentoID]) REFERENCES [dian].[Documento] ([DocumentoID]),
        CONSTRAINT [FK_DianDocumentoXml_Consulta] FOREIGN KEY ([ConsultaDianID]) REFERENCES [dian].[ConsultaDian] ([ConsultaDianID]),
        CONSTRAINT [CK_DianDocumentoXml_Tamano] CHECK ([TamanoBytes] >= 0)
    );
    CREATE UNIQUE INDEX [UX_DianDocumentoXml_Vigente]
        ON [dian].[DocumentoXml] ([DocumentoID])
        WHERE [EsVigente] = 1;

    -- Fuente: sql/procedures/sp_RegistrarCliente.sql
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;
    DECLARE @Definicion1 nvarchar(max);
    SET @Definicion1 = CAST(N'CREATE OR ALTER PROCEDURE [dian].[sp_RegistrarCliente]
    @Nit nvarchar(100),
    @RazonSocial nvarchar(500),
    @Estado varchar(20) = ''ACTIVO''
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @NitNormalizado nvarchar(100) = UPPER(NULLIF(LTRIM(RTRIM(@Nit)), N''''));
    DECLARE @RazonSocialNormalizada nvarchar(500) = NULLIF(LTRIM(RTRIM(@RazonSocial)), N'''');
    DECLARE @EstadoNormalizado varchar(20) = UPPER(NULLIF(LTRIM(RTRIM(@Estado)), ''''));
    DECLARE @ClienteID bigint;
    DECLARE @NitExistente nvarchar(20);
    DECLARE @RazonSocialExistente nvarchar(300);
    DECLARE @EstadoExistente varchar(10);
    DECLARE @Resultado varchar(30);
    DECLARE @Creado bit;
    DECLARE @RequiereRevision bit;
    DECLARE @LockResult int;
    DECLARE @LockResource nvarchar(255);

    IF @NitNormalizado IS NULL
        THROW 50101, ''El NIT es obligatorio.'', 1;

    IF LEN(@NitNormalizado) > 20
        THROW 50102, ''El NIT no puede superar 20 caracteres.'', 1;

    IF @RazonSocialNormalizada IS NULL
        THROW 50103, ''La razón social es obligatoria.'', 1;

    IF LEN(@RazonSocialNormalizada) > 300
        THROW 50104, ''La razón social no puede superar 300 caracteres.'', 1;

    IF @EstadoNormalizado IS NULL
        SET @EstadoNormalizado = ''ACTIVO'';

    IF @EstadoNormalizado NOT IN (''ACTIVO'', ''INACTIVO'')
        THROW 50105, ''El estado debe ser ACTIVO o INACTIVO.'', 1;

    BEGIN TRANSACTION;

    SET @LockResource = CONCAT(N''dian:cliente:nit:'', @NitNormalizado);

    EXEC @LockResult = sys.sp_getapplock
        @Resource = @LockResource,
        @LockMode = ''Exclusive'',
        @LockOwner = ''Transaction'',
        @LockTimeout = 10000;

    IF @LockResult < 0
        THROW 50106, ''No fue posible obtener el bloqueo para registrar el cliente.'', 1;

    SELECT
        @ClienteID = [ClienteID],
        @NitExistente = [Nit],
        @RazonSocialExistente = [RazonSocial],
        @EstadoExistente = [Estado]
    FROM [dian].[Cliente] WITH (UPDLOCK, HOLDLOCK)
    WHERE [Nit' AS nvarchar(max))
        + N'] = CONVERT(nvarchar(20), @NitNormalizado);

    IF @ClienteID IS NULL
    BEGIN
        INSERT INTO [dian].[Cliente]
        (
            [Nit],
            [RazonSocial],
            [Estado]
        )
        VALUES
        (
            CONVERT(nvarchar(20), @NitNormalizado),
            CONVERT(nvarchar(300), @RazonSocialNormalizada),
            CONVERT(varchar(10), @EstadoNormalizado)
        );

        SET @ClienteID = SCOPE_IDENTITY();
        SET @NitExistente = CONVERT(nvarchar(20), @NitNormalizado);
        SET @RazonSocialExistente = CONVERT(nvarchar(300), @RazonSocialNormalizada);
        SET @EstadoExistente = CONVERT(varchar(10), @EstadoNormalizado);
        SET @Resultado = ''NUEVO'';
        SET @Creado = 1;
        SET @RequiereRevision = 0;
    END
    ELSE IF @RazonSocialExistente = CONVERT(nvarchar(300), @RazonSocialNormalizada)
        AND @EstadoExistente = CONVERT(varchar(10), @EstadoNormalizado)
    BEGIN
        SET @Resultado = ''EXISTENTE'';
        SET @Creado = 0;
        SET @RequiereRevision = 0;
    END
    ELSE
    BEGIN
        SET @Resultado = ''REQUIERE_REVISION'';
        SET @Creado = 0;
        SET @RequiereRevision = 1;
    END;

    COMMIT TRANSACTION;

    SELECT
        @ClienteID AS [ClienteID],
        @NitExistente AS [Nit],
        @RazonSocialExistente AS [RazonSocial],
        @EstadoExistente AS [Estado],
        @Resultado AS [Resultado],
        @Creado AS [Creado],
        @RequiereRevision AS [RequiereRevision];
END;';
    EXEC sys.sp_executesql @Definicion1;
    GRANT EXECUTE ON OBJECT::[dian].[sp_RegistrarCliente] TO [dian_runtime];

    -- Fuente: sql/procedures/sp_IniciarCargaArchivo.sql
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;
    DECLARE @Definicion2 nvarchar(max);
    SET @Definicion2 = CAST(N'CREATE OR ALTER PROCEDURE [dian].[sp_IniciarCargaArchivo]
    @ClienteID bigint,
    @NombreArchivo nvarchar(260),
    @HashArchivoSha256 varchar(128),
    @SharePointItemID nvarchar(150) = NULL,
    @SharePointUrl nvarchar(1000) = NULL,
    @ETag nvarchar(200) = NULL,
    @NombreTablaOrigen nvarchar(128) = NULL,
    @CargadoPor nvarchar(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @NombreArchivoNormalizado nvarchar(260) = NULLIF(LTRIM(RTRIM(@NombreArchivo)), N'''');
    DECLARE @HashNormalizado varchar(128) = LOWER(NULLIF(LTRIM(RTRIM(@HashArchivoSha256)), ''''));
    DECLARE @SharePointItemNormalizado nvarchar(150) = NULLIF(LTRIM(RTRIM(@SharePointItemID)), N'''');
    DECLARE @ETagNormalizado nvarchar(200) = NULLIF(LTRIM(RTRIM(@ETag)), N'''');
    DECLARE @CargaArchivoID bigint;
    DECLARE @CargaOriginalID bigint;
    DECLARE @Estado varchar(30);
    DECLARE @Resultado varchar(30);
    DECLARE @DebeProcesar bit;
    DECLARE @LockResult int;
    DECLARE @LockResource nvarchar(255);

    IF NOT EXISTS
    (
        SELECT 1
        FROM [dian].[Cliente]
        WHERE [ClienteID] = @ClienteID
          AND [Estado] = ''ACTIVO''
    )
        THROW 50001, ''El cliente no existe o no está activo.'', 1;

    IF @NombreArchivoNormalizado IS NULL
        THROW 50002, ''El nombre del archivo es obligatorio.'', 1;

    IF @HashNormalizado IS NULL
       OR LEN(@HashNormalizado) <> 64
       OR @HashNormalizado COLLATE Latin1_General_100_BIN2 LIKE ''%[^0-9a-f]%''
        THROW 50003, ''El hash del archivo debe ser SHA-256 hexadecimal de 64 caracteres.'', 1;

    BEGIN TRANSACTION;

    SET @LockResource = CONCAT(N''dian:carga:'', @ClienteID, N'':'', @HashNormalizado);

    EXEC @LockResult = sys.sp_getapplock
        @Resource = @LockResource,
        @LockMode = ''Exclusive'',
        @LockOwner = ''Transaction'',
        @LockTimeout = 10000;

    IF @LockResult < 0
        THROW 50004, ''No fue posible obtener el bloqueo para iniciar la carga.'', 1;

    IF @SharePoin' AS nvarchar(max))
        + N'tItemNormalizado IS NOT NULL AND @ETagNormalizado IS NOT NULL
    BEGIN
        SELECT TOP (1)
            @CargaArchivoID = [CargaArchivoID],
            @CargaOriginalID = [CargaOriginalID],
            @Estado = [Estado]
        FROM [dian].[CargaArchivo] WITH (UPDLOCK, HOLDLOCK)
        WHERE [ClienteID] = @ClienteID
          AND [SharePointItemID] = @SharePointItemNormalizado
          AND [ETag] = @ETagNormalizado
        ORDER BY [CargaArchivoID];
    END;

    IF @CargaArchivoID IS NOT NULL
    BEGIN
        IF @Estado = ''ERROR''
        BEGIN
            UPDATE [dian].[CargaArchivo]
            SET [Estado] = ''RECIBIDA'',
                [FechaInicioUTC] = sysutcdatetime(),
                [FechaFinUTC] = NULL,
                [Mensaje] = N''Reintento solicitado para la misma versión del archivo.''
            WHERE [CargaArchivoID] = @CargaArchivoID;

            SET @Estado = ''RECIBIDA'';
            SET @Resultado = ''REINTENTO'';
            SET @DebeProcesar = 1;
        END
        ELSE
        BEGIN
            SET @Resultado = ''SOLICITUD_EXISTENTE'';
            SET @DebeProcesar = CASE WHEN @Estado = ''RECIBIDA'' THEN 1 ELSE 0 END;
        END;

        COMMIT TRANSACTION;

        SELECT
            @CargaArchivoID AS [CargaArchivoID],
            @CargaOriginalID AS [CargaOriginalID],
            @Estado AS [Estado],
            @Resultado AS [Resultado],
            @DebeProcesar AS [DebeProcesar];
        RETURN;
    END;

    DECLARE @EstadoOriginal varchar(30);
    DECLARE @TotalFilasOriginal int;

    SELECT TOP (1)
        @CargaOriginalID = COALESCE([CargaOriginalID], [CargaArchivoID]),
        @EstadoOriginal = [Estado],
        @TotalFilasOriginal = [TotalFilas]
    FROM [dian].[CargaArchivo] WITH (UPDLOCK, HOLDLOCK)
    WHERE [ClienteID] = @ClienteID
      AND [HashArchivoSha256] = @HashNormalizado
      AND [Estado] <> ''ERROR''
    ORDER BY
        CASE WHEN [Estado] IN (''OK'', ''PARCIAL'', ''REQUIERE_REVISION'') THEN 0 ELSE 1 END,
        [CargaArch'
        + N'ivoID];

    IF @CargaOriginalID IS NOT NULL
    BEGIN
        INSERT INTO [dian].[CargaArchivo]
        (
            [ClienteID],
            [CargaOriginalID],
            [NombreArchivo],
            [SharePointItemID],
            [SharePointUrl],
            [ETag],
            [HashArchivoSha256],
            [NombreTablaOrigen],
            [CargadoPor],
            [FechaFinUTC],
            [Estado],
            [TotalFilas],
            [FilasDuplicadas],
            [Mensaje]
        )
        VALUES
        (
            @ClienteID,
            @CargaOriginalID,
            @NombreArchivoNormalizado,
            @SharePointItemNormalizado,
            NULLIF(LTRIM(RTRIM(@SharePointUrl)), N''''),
            @ETagNormalizado,
            @HashNormalizado,
            NULLIF(LTRIM(RTRIM(@NombreTablaOrigen)), N''''),
            NULLIF(LTRIM(RTRIM(@CargadoPor)), N''''),
            sysutcdatetime(),
            ''SIN_CAMBIOS'',
            @TotalFilasOriginal,
            @TotalFilasOriginal,
            N''El contenido del archivo ya había sido registrado.''
        );

        SET @CargaArchivoID = SCOPE_IDENTITY();
        SET @Estado = ''SIN_CAMBIOS'';
        SET @Resultado = ''SIN_CAMBIOS'';
        SET @DebeProcesar = 0;
    END
    ELSE
    BEGIN
        INSERT INTO [dian].[CargaArchivo]
        (
            [ClienteID],
            [NombreArchivo],
            [SharePointItemID],
            [SharePointUrl],
            [ETag],
            [HashArchivoSha256],
            [NombreTablaOrigen],
            [CargadoPor],
            [Estado],
            [Mensaje]
        )
        VALUES
        (
            @ClienteID,
            @NombreArchivoNormalizado,
            @SharePointItemNormalizado,
            NULLIF(LTRIM(RTRIM(@SharePointUrl)), N''''),
            @ETagNormalizado,
            @HashNormalizado,
            NULLIF(LTRIM(RTRIM(@NombreTablaOrigen)), N''''),
            NULLIF(LTRIM(RTRIM(@CargadoPor)), N''''),
            ''RECIBIDA'',
            N''Arch'
        + N'ivo registrado y pendiente de procesar.''
        );

        SET @CargaArchivoID = SCOPE_IDENTITY();
        SET @Estado = ''RECIBIDA'';
        SET @Resultado = ''NUEVA_CARGA'';
        SET @DebeProcesar = 1;
    END;

    COMMIT TRANSACTION;

    SELECT
        @CargaArchivoID AS [CargaArchivoID],
        @CargaOriginalID AS [CargaOriginalID],
        @Estado AS [Estado],
        @Resultado AS [Resultado],
        @DebeProcesar AS [DebeProcesar];
END;';
    EXEC sys.sp_executesql @Definicion2;
    GRANT EXECUTE ON OBJECT::[dian].[sp_IniciarCargaArchivo] TO [dian_runtime];

    -- Fuente: sql/procedures/sp_RegistrarDocumentoCarga.sql
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;
    DECLARE @Definicion3 nvarchar(max);
    SET @Definicion3 = CAST(N'CREATE OR ALTER PROCEDURE [dian].[sp_RegistrarDocumentoCarga]
    @CargaArchivoID bigint,
    @FilaOrigen int,
    @ClaveDocumento varchar(128),
    @TipoClave varchar(20) = ''CUFE'',
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
    DECLARE @ErrorValidacion nvarchar(1000) = N'''';
    DECLARE @DebeDescargarXml bit = 0;
    DECLARE @SolicitudExistente bit = 0;
    DECLARE @LockResult int;
    DECLARE @LockResource nvarchar(255);
    DECLARE @DetalleJson nvarchar(max);

    DECLARE @ClaveNormalizada va' AS nvarchar(max))
        + N'rchar(128) = LOWER(NULLIF(LTRIM(RTRIM(@ClaveDocumento)), ''''));
    DECLARE @TipoClaveNormalizado varchar(20) = UPPER(NULLIF(LTRIM(RTRIM(@TipoClave)), ''''));
    DECLARE @TipoDocumentoNormalizado nvarchar(200) = NULLIF(LTRIM(RTRIM(@TipoDocumento)), N'''');
    DECLARE @FolioNormalizado nvarchar(100) = NULLIF(LTRIM(RTRIM(@Folio)), N'''');
    DECLARE @PrefijoNormalizado nvarchar(100) = NULLIF(LTRIM(RTRIM(@Prefijo)), N'''');
    DECLARE @DivisaNormalizada nvarchar(50) = NULLIF(UPPER(LTRIM(RTRIM(@Divisa))), N'''');
    DECLARE @FormaPagoNormalizada nvarchar(100) = NULLIF(LTRIM(RTRIM(@FormaPago)), N'''');
    DECLARE @MedioPagoNormalizado nvarchar(100) = NULLIF(LTRIM(RTRIM(@MedioPago)), N'''');
    DECLARE @NitEmisorNormalizado nvarchar(50) = NULLIF(UPPER(LTRIM(RTRIM(@NitEmisor))), N'''');
    DECLARE @NombreEmisorNormalizado nvarchar(500) = NULLIF(LTRIM(RTRIM(@NombreEmisor)), N'''');
    DECLARE @NitReceptorNormalizado nvarchar(50) = NULLIF(UPPER(LTRIM(RTRIM(@NitReceptor))), N'''');
    DECLARE @NombreReceptorNormalizado nvarchar(500) = NULLIF(LTRIM(RTRIM(@NombreReceptor)), N'''');
    DECLARE @EstadoDianNormalizado nvarchar(200) = NULLIF(LTRIM(RTRIM(@EstadoDianOrigen)), N'''');
    DECLARE @GrupoNormalizado nvarchar(100) = NULLIF(LTRIM(RTRIM(@GrupoOrigen)), N'''');
    DECLARE @HashFilaNormalizado varchar(128) = LOWER(NULLIF(LTRIM(RTRIM(@HashFilaSha256)), ''''));
    DECLARE @HashContenidoNormalizado varchar(128) = LOWER(NULLIF(LTRIM(RTRIM(@HashContenidoSha256)), ''''));
    DECLARE @JsonPersistido nvarchar(max) = @FilaOrigenJson;

    IF @CargaArchivoID IS NULL
        THROW 50201, ''La carga es obligatoria.'', 1;

    IF @FilaOrigen IS NULL OR @FilaOrigen < 2
        THROW 50202, ''La fila de origen debe ser igual o superior a 2.'', 1;

    BEGIN TRANSACTION;

    SET @LockResource = CONCAT(N''dian:carga-fila:'', @CargaArchivoID, N'':'', @FilaOrigen);

    EXEC @LockResult = sys.sp_getapplock
        @Resource = @LockResource,
        @LockMode = ''Exclusive'',
        @LockOwner = ''Transaction'',
        '
        + N'@LockTimeout = 10000;

    IF @LockResult < 0
        THROW 50203, ''No fue posible bloquear la fila para su registro.'', 1;

    SELECT
        @ClienteID = [ClienteID],
        @EstadoCarga = [Estado],
        @Actor = [CargadoPor]
    FROM [dian].[CargaArchivo] WITH (UPDLOCK, HOLDLOCK)
    WHERE [CargaArchivoID] = @CargaArchivoID;

    IF @ClienteID IS NULL
        THROW 50204, ''La carga indicada no existe.'', 1;

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
            NULLIF(@ErrorValidacion, N'''') AS [ErrorValidacion];
        RETURN;
    END;

    IF @EstadoCarga NOT IN (''RECIBIDA'', ''PROCESANDO'')
        THROW 50205, ''La carga no está disponible para registrar nuevas filas.'', 1;

    IF @ClaveNormalizada IS NULL
     '
        + N'  OR LEN(@ClaveNormalizada) <> 96
       OR @ClaveNormalizada COLLATE Latin1_General_100_BIN2 LIKE ''%[^0-9a-f]%''
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N''CUFE/CUDE inválido; '');

    IF @TipoClaveNormalizado IS NULL OR @TipoClaveNormalizado NOT IN (''CUFE'', ''CUDE'')
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N''Tipo de clave inválido; '');

    IF @TipoDocumentoNormalizado IS NULL OR LEN(@TipoDocumentoNormalizado) > 80
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N''Tipo de documento inválido; '');

    IF @FolioNormalizado IS NULL OR LEN(@FolioNormalizado) > 50
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N''Folio inválido; '');

    IF LEN(COALESCE(@PrefijoNormalizado, N'''')) > 30
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N''Prefijo demasiado largo; '');

    IF LEN(COALESCE(@DivisaNormalizada, N'''')) > 10
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N''Divisa demasiado larga; '');

    IF LEN(COALESCE(@FormaPagoNormalizada, N'''')) > 20
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N''Forma de pago demasiado larga; '');

    IF LEN(COALESCE(@MedioPagoNormalizado, N'''')) > 20
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N''Medio de pago demasiado largo; '');

    IF @FechaEmision IS NULL
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N''Fecha de emisión obligatoria; '');

    IF @FechaRecepcion IS NULL
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N''Fecha de recepción obligatoria; '');

    IF @NitEmisorNormalizado IS NULL OR LEN(@NitEmisorNormalizado) > 20
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N''NIT del emisor inválido; '');

    IF @NombreEmisorNormalizado IS NULL OR LEN(@NombreEmisorNormalizado) > 300
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N''Nombre del emisor inválido; '');

    IF @NitReceptorNormalizado IS NULL OR LEN(@NitReceptorNormalizado) > 20
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N''NIT del receptor inválido; '');
'
        + N'
    IF @NombreReceptorNormalizado IS NULL OR LEN(@NombreReceptorNormalizado) > 300
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N''Nombre del receptor inválido; '');

    IF @Total IS NULL
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N''Total obligatorio; '');

    IF @EstadoDianNormalizado IS NULL OR LEN(@EstadoDianNormalizado) > 100
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N''Estado DIAN inválido; '');

    IF @GrupoNormalizado IS NULL OR LEN(@GrupoNormalizado) > 50
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N''Grupo de origen inválido; '');

    IF @HashFilaNormalizado IS NULL
       OR LEN(@HashFilaNormalizado) <> 64
       OR @HashFilaNormalizado COLLATE Latin1_General_100_BIN2 LIKE ''%[^0-9a-f]%''
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N''Hash de fila inválido; '');

    IF @HashContenidoNormalizado IS NULL
       OR LEN(@HashContenidoNormalizado) <> 64
       OR @HashContenidoNormalizado COLLATE Latin1_General_100_BIN2 LIKE ''%[^0-9a-f]%''
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N''Hash de contenido inválido; '');

    IF COALESCE(ISJSON(@FilaOrigenJson), 0) <> 1
    BEGIN
        SET @ErrorValidacion = CONCAT(@ErrorValidacion, N''JSON de origen inválido; '');
        SET @JsonPersistido = N''{"error":"FilaOrigenJson no es JSON válido"}'';
    END;

    IF @ErrorValidacion <> N''''
    BEGIN
        SET @ErrorValidacion = LEFT(@ErrorValidacion, LEN(@ErrorValidacion) - 2);
        SET @Resultado = ''RECHAZADO'';

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
                 AND @HashFilaNormalizado COLLATE Latin1_General_100_BIN2 NOT LIKE ''%[^0-9'
        + N'a-f]%''
                THEN CONVERT(char(64), @HashFilaNormalizado)
                ELSE NULL
            END,
            COALESCE(@JsonPersistido, N''{"error":"FilaOrigenJson no fue suministrado"}''),
            0,
            @Resultado,
            @ErrorValidacion
        );

        UPDATE [dian].[CargaArchivo]
        SET [Estado] = ''PROCESANDO'',
            [Mensaje] = N''Procesando filas del archivo.''
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

    SET @LockResource = CONCAT(N''dian:documento:'', @ClienteID, N'':'', @ClaveNormalizada);

    EXEC @LockResult = sys.sp_getapplock
        @Resource = @LockResource,
        @LockMode = ''Exclusive'',
        @LockOwner = ''Transaction'',
        @LockTimeout = 10000;

    IF @LockResult < 0
        THROW 50206, ''No fue posible bloquear el documento para su registro.'', 1;

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
      '
        + N'      [RevisionActual],
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
            ''NO_REQUIERE'',
            ''PENDIENTE_DESCARGA'',
            @CargaArchivoID,
            @CargaArchivoID
        );

        SET @DocumentoID = SCOPE_IDENTITY();
        SET @NumeroRevision = 1;
        SET @EstadoRevision = ''NO_REQUIERE'';
        SET @EstadoProceso = ''PENDIENTE_DESCARGA'';
        SET @Resultado = ''NUEVO'';
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
      '
        + N'      CONVERT(nvarchar(20), @NitReceptorNormalizado), CONVERT(nvarchar(300), @NombreReceptorNormalizado),
            COALESCE(@Iva, 0), COALESCE(@Ica, 0), COALESCE(@Ic, 0), COALESCE(@Inc, 0),
            COALESCE(@Timbre, 0), COALESCE(@IncBolsas, 0), COALESCE(@InCarbono, 0),
            COALESCE(@InCombustibles, 0), COALESCE(@IcDatos, 0), COALESCE(@Icl, 0),
            COALESCE(@Inpp, 0), COALESCE(@Ibua, 0), COALESCE(@Icui, 0),
            COALESCE(@ReteIva, 0), COALESCE(@ReteRenta, 0), COALESCE(@ReteIca, 0), @Total,
            CONVERT(nvarchar(100), @EstadoDianNormalizado), CONVERT(nvarchar(50), @GrupoNormalizado),
            @EstadoRevision, 1, @CargaArchivoID
        );

        SET @DocumentoVersionID = SCOPE_IDENTITY();
        SET @DetalleJson = CONCAT(N''{"cargaArchivoId":'', @CargaArchivoID,
            N'',"filaOrigen":'', @FilaOrigen, N'',"resultado":"NUEVO"}'');

        INSERT INTO [dian].[DocumentoProcesoHistorial]
        (
            [DocumentoID], [CargaArchivoID], [EstadoAnterior], [EstadoNuevo],
            [TipoEvento], [Origen], [Actor], [DetalleJson]
        )
        VALUES
        (
            @DocumentoID, @CargaArchivoID, NULL, @EstadoProceso,
            ''REGISTRO'', ''FUNCTION'', COALESCE(@Actor, N''Azure Function''), @DetalleJson
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
            SET @Resultado = ''DUPLICADO'';
            SET @DebeDescargarXml = 0;

            UPDATE [dian].[Documento]
            SET [UltimaCargaID] = @CargaArchivoID,
                [FechaActualizacionUTC] = sysutcdatetime()
            WHERE [DocumentoID] = @Docu'
        + N'mentoID;

            SET @DetalleJson = CONCAT(N''{"cargaArchivoId":'', @CargaArchivoID,
                N'',"filaOrigen":'', @FilaOrigen, N'',"resultado":"DUPLICADO"}'');

            INSERT INTO [dian].[DocumentoProcesoHistorial]
            (
                [DocumentoID], [CargaArchivoID], [EstadoAnterior], [EstadoNuevo],
                [TipoEvento], [Origen], [Actor], [DetalleJson]
            )
            VALUES
            (
                @DocumentoID, @CargaArchivoID, @EstadoProcesoAnterior, @EstadoProcesoAnterior,
                ''DOCUMENTO_DUPLICADO'', ''FUNCTION'', COALESCE(@Actor, N''Azure Function''), @DetalleJson
            );
        END
        ELSE
        BEGIN
            SET @NumeroRevision = @RevisionActual + 1;
            SET @Resultado = ''NUEVA_REVISION'';
            SET @EstadoRevision = ''PENDIENTE'';
            SET @EstadoProceso = ''REQUIERE_REVISION'';
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
                CONVERT(nvarchar(80), @Tip'
        + N'oDocumentoNormalizado), CONVERT(nvarchar(50), @FolioNormalizado),
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
                @EstadoRevision, N''El mismo CUFE/CUDE fue recibido con contenido diferente.'',
                1, @CargaArchivoID
            );

            SET @DocumentoVersionID = SCOPE_IDENTITY();

            UPDATE [dian].[Documento]
            SET [TipoDocumento] = CONVERT(nvarchar(80), @TipoDocumentoNormalizado),
                [RevisionActual] = @NumeroRevision,
                [EstadoRevision] = @EstadoRevision,
                [MotivoRevision] = N''El mismo CUFE/CUDE fue recibido con contenido diferente.'',
                [EstadoProceso] = @EstadoProceso,
                [UltimaCargaID] = @CargaArchivoID,
                [FechaActualizacionUTC] = sysutcdatetime()
            WHERE [DocumentoID] = @DocumentoID;

            SET @DetalleJson = CONCAT(N''{"cargaArchivoId":'', @CargaArchivoID,
                N'',"filaOrigen":'', @FilaOrigen, N'',"numeroRevision":'', @NumeroRevision,
    '
        + N'            N'',"resultado":"NUEVA_REVISION"}'');

            INSERT INTO [dian].[DocumentoProcesoHistorial]
            (
                [DocumentoID], [CargaArchivoID], [EstadoAnterior], [EstadoNuevo],
                [TipoEvento], [Origen], [Actor], [DetalleJson]
            )
            VALUES
            (
                @DocumentoID, @CargaArchivoID, @EstadoProcesoAnterior, @EstadoProceso,
                ''NUEVA_REVISION'', ''FUNCTION'', COALESCE(@Actor, N''Azure Function''), @DetalleJson
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
    SET [Estado] = ''PROCESANDO'',
        [Mensaje] = N''Procesando filas del archivo.''
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
END;';
    EXEC sys.sp_executesql @Definicion3;
    GRANT EXECUTE ON OBJECT::[dian].[sp_RegistrarDocumentoCarga] TO [dian_runtime];

    -- Fuente: sql/procedures/sp_FinalizarCargaArchivo.sql
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;
    DECLARE @Definicion4 nvarchar(max);
    SET @Definicion4 = CAST(N'CREATE OR ALTER PROCEDURE [dian].[sp_FinalizarCargaArchivo]
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
        THROW 50301, ''La carga es obligatoria.'', 1;

    IF @TotalFilasEsperadas IS NOT NULL AND @TotalFilasEsperadas < 0
        THROW 50302, ''El total de filas esperadas no puede ser negativo.'', 1;

    BEGIN TRANSACTION;

    SET @LockResource = CONCAT(N''dian:finalizar-carga:'', @CargaArchivoID);

    EXEC @LockResult = sys.sp_getapplock
        @Resource = @LockResource,
        @LockMode = ''Exclusive'',
        @LockOwner = ''Transaction'',
        @LockTimeout = 10000;

    IF @LockResult < 0
        THROW 50303, ''No fue posible bloquear la carga para finalizarla.'', 1;

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
        THROW 50304, ''La carga indicada no existe.'', 1;

    IF @Estado IN (''OK'', ''PARCIAL'', ''SIN_CAMBIOS'', ''REQUIERE_REVISION'', ''ERROR'')
    BEGIN
        SELECT @FilasProcesadas = COUNT(*)
        FROM [dian].[CargaDocumento]
        WHERE [CargaArchivoID] = @CargaArchivoID;

        SET @FilasPendientes = CASE
            WHEN COALESCE(@TotalFilas, @FilasProcesadas) >' AS nvarchar(max))
        + N' @FilasProcesadas
            THEN COALESCE(@TotalFilas, @FilasProcesadas) - @FilasProcesadas
            ELSE 0
        END;
        SET @Resultado = ''YA_FINALIZADA'';

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
        @FilasDuplicadas = COALESCE(SUM(CASE WHEN [Resultado] = ''DUPLICADO'' THEN 1 ELSE 0 END), 0),
        @FilasRevision = COALESCE(SUM(CASE WHEN [Resultado] = ''NUEVA_REVISION'' THEN 1 ELSE 0 END), 0),
        @FilasError = COALESCE(SUM(CASE WHEN [EsValida] = 0 OR [Resultado] = ''RECHAZADO'' THEN 1 ELSE 0 END), 0)
    FROM [dian].[CargaDocumento]
    WHERE [CargaArchivoID] = @CargaArchivoID;

    SET @TotalFilas = COALESCE(@TotalFilasEsperadas, @FilasProcesadas);

    IF @TotalFilas < @FilasProcesadas
        THROW 50305, ''El total esperado no puede ser inferior a las filas ya procesadas.'', 1;

    SET @FilasPendientes = @TotalFilas - @FilasProcesadas;

    SET @Estado = CASE
        WHEN @TotalFilas = 0 OR @FilasValidas = 0 THEN ''ERROR''
        WHEN @FilasPendientes > 0 OR @FilasError > 0 THEN ''PARCIAL''
        WHEN @FilasRevision > 0 THEN ''REQUIERE_REVISION''
        ELSE ''OK''
    END;

    SET @MensajeFinal = COALESCE
    (
        NULLIF(LTRIM(RTRIM(@Mensaje)), N''''),
        CONCAT
        (
            N''Carga finalizada. Esperadas: '', @TotalFilas,
            N''; procesadas: '', @FilasProcesadas,
            N''; válida'
        + N's: '', @FilasValidas,
            N''; duplicadas: '', @FilasDuplicadas,
            N''; revisiones: '', @FilasRevision,
            N''; errores: '', @FilasError,
            N''; pendientes: '', @FilasPendientes, N''.''
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

    SET @Resultado = ''FINALIZADA'';

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
END;';
    EXEC sys.sp_executesql @Definicion4;
    GRANT EXECUTE ON OBJECT::[dian].[sp_FinalizarCargaArchivo] TO [dian_runtime];

    -- Fuente: sql/procedures/sp_IniciarConsultaDocumento.sql
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;
    DECLARE @Definicion5 nvarchar(max);
    SET @Definicion5 = CAST(N'CREATE OR ALTER PROCEDURE [dian].[sp_IniciarConsultaDocumento]
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

    DECLARE @Clave varchar(128) = LOWER(NULLIF(LTRIM(RTRIM(@ClaveDocumento)), ''''));
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
        THROW 50401, ''Los identificadores deben ser positivos.'', 1;

    IF @Clave IS NULL
       OR LEN(@Clave) <> 96
       OR @Clave COLLATE Latin1_General_100_BIN2 LIKE ''%[^0-9a-f]%''
        THROW 50402, ''El CUFE/CUDE no es valido.'', 1;

    IF @MaximoIntentos IS NULL OR @MaximoIntentos < 1
       OR @TiempoReclamoSegundos IS NULL
       OR @TiempoReclamoSegundos NOT BETWEEN 1 AND 86400
        THROW 50403, ''La configuracion de reintentos no es valida.'', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        SET @LockResource = CONCAT(N''dian:consulta-documento:'', @DocumentoID);

        EXEC @LockResult = sys.sp_getapplock
            @Resource = @LockResource,
            @LockMode = ''Exclusive'',
            @LockOwner = ''Transaction'',
            @LockTimeout = 10000;

        IF @LockResult < 0
            THROW 50404, ''No se pudo reclamar el' AS nvarchar(max))
        + N' documento.'', 1;

        SELECT
            @ClienteActual = [ClienteID],
            @ClaveActual = [ClaveDocumento],
            @Estado = [EstadoProceso]
        FROM [dian].[Documento] WITH (UPDLOCK, HOLDLOCK)
        WHERE [DocumentoID] = @DocumentoID;

        IF @ClienteActual IS NULL
            THROW 50405, ''El documento no existe.'', 1;

        IF @ClienteActual <> @ClienteID
           OR @ClaveActual <> CONVERT(char(96), @Clave)
            THROW 50406, ''El mensaje no coincide con el documento.'', 1;

        IF NOT EXISTS
        (
            SELECT 1
            FROM [dian].[CargaDocumento]
            WHERE [CargaArchivoID] = @CargaArchivoID
              AND [DocumentoID] = @DocumentoID
              AND [DocumentoVersionID] = @DocumentoVersionID
              AND [EsValida] = 1
        )
            THROW 50407, ''La carga o version no corresponde al documento.'', 1;

        SELECT TOP (1) @DocumentoXmlID = [DocumentoXmlID]
        FROM [dian].[DocumentoXml] WITH (UPDLOCK, HOLDLOCK)
        WHERE [DocumentoID] = @DocumentoID
          AND [EsVigente] = 1;

        IF @DocumentoXmlID IS NOT NULL
        BEGIN
            SET @Resultado = ''XML_YA_REGISTRADO'';
            SET @PuedeIniciar = 0;

            -- Recupera una ejecucion que guardo el XML pero no alcanzo a finalizar.
            UPDATE [dian].[ConsultaDian]
            SET [Estado] = ''OK'',
                [FechaFinUTC] = COALESCE([FechaFinUTC], SYSUTCDATETIME()),
                [ErrorTipo] = NULL
            WHERE [DocumentoID] = @DocumentoID
              AND [Estado] = ''INICIADA'';

            IF @Estado IN (''PENDIENTE_DESCARGA'', ''CONSULTANDO_DIAN'', ''ERROR'')
            BEGIN
                SET @EstadoAnterior = @Estado;
                SET @Estado = ''XML_DESCARGADO'';

                UPDATE [dian].[Documento]
                SET [EstadoProceso] = @Estado,
                    [FechaActualizacionUTC] = SYSUTCDATETIME()
                WHERE [DocumentoID] = @DocumentoID;

                '
        + N'INSERT INTO [dian].[DocumentoProcesoHistorial]
                (
                    [DocumentoID], [CargaArchivoID], [EstadoAnterior],
                    [EstadoNuevo], [TipoEvento], [Origen], [Actor], [DetalleJson]
                )
                VALUES
                (
                    @DocumentoID, @CargaArchivoID, @EstadoAnterior,
                    @Estado, ''XML_YA_REGISTRADO'', ''SISTEMA'', N''Azure Function'',
                    CONCAT(N''{"documentoXmlId":'', @DocumentoXmlID, N''}'')
                );
            END;
        END
        ELSE IF @Estado = ''CONSULTANDO_DIAN''
        BEGIN
            SELECT TOP (1)
                @ConsultaAbiertaID = [ConsultaDianID],
                @InicioAbierto = [FechaInicioUTC],
                @NumeroIntento = [NumeroIntento]
            FROM [dian].[ConsultaDian] WITH (UPDLOCK, HOLDLOCK)
            WHERE [DocumentoID] = @DocumentoID
              AND [Estado] = ''INICIADA''
            ORDER BY [NumeroIntento] DESC;

            IF @ConsultaAbiertaID IS NOT NULL
               AND @InicioAbierto > DATEADD(
                    second, -@TiempoReclamoSegundos, SYSUTCDATETIME()
               )
            BEGIN
                SET @ConsultaDianID = @ConsultaAbiertaID;
                SET @Resultado = ''CONSULTA_EN_PROGRESO'';
                SET @PuedeIniciar = 0;
            END
            ELSE
            BEGIN
                IF @ConsultaAbiertaID IS NOT NULL
                    UPDATE [dian].[ConsultaDian]
                    SET [Estado] = ''REINTENTO'',
                        [FechaFinUTC] = SYSUTCDATETIME(),
                        [MensajeDianSanitizado] = N''El reclamo anterior expiro.'',
                        [ErrorTipo] = N''RECLAMO_EXPIRADO''
                    WHERE [ConsultaDianID] = @ConsultaAbiertaID;

                UPDATE [dian].[Documento]
                SET [EstadoProceso] = ''PENDIENTE_DESCARGA'',
                    [FechaActualizacionUTC] = SYSUTCDATETIME()
                WHERE [DocumentoID] = @Do'
        + N'cumentoID;

                INSERT INTO [dian].[DocumentoProcesoHistorial]
                (
                    [DocumentoID], [CargaArchivoID], [EstadoAnterior],
                    [EstadoNuevo], [TipoEvento], [Origen], [Actor], [DetalleJson]
                )
                VALUES
                (
                    @DocumentoID, @CargaArchivoID,
                    ''CONSULTANDO_DIAN'', ''PENDIENTE_DESCARGA'',
                    ''CONSULTA_EXPIRADA'', ''SISTEMA'', N''Azure Function'',
                    CONCAT(
                        N''{"consultaDianId":'',
                        COALESCE(CONVERT(nvarchar(20), @ConsultaAbiertaID), N''null''),
                        N''}''
                    )
                );

                SET @Estado = ''PENDIENTE_DESCARGA'';
            END;
        END
        ELSE IF @Estado <> ''PENDIENTE_DESCARGA''
        BEGIN
            SET @Resultado = ''ESTADO_NO_ELEGIBLE'';
            SET @PuedeIniciar = 0;
        END;

        IF @PuedeIniciar = 1
        BEGIN
            SELECT @NumeroIntento = COALESCE(MAX(CONVERT(int, [NumeroIntento])), 0)
            FROM [dian].[ConsultaDian] WITH (UPDLOCK, HOLDLOCK)
            WHERE [DocumentoID] = @DocumentoID;

            IF @NumeroIntento >= @MaximoIntentos
            BEGIN
                SET @Resultado = ''MAXIMO_INTENTOS'';
                SET @Estado = ''ERROR'';

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
                    ''PENDIENTE_DESCARGA'', @Estado,
                    ''MAXIMO_INTENTOS'''
        + N', ''SISTEMA'', N''Azure Function'',
                    CONCAT(N''{"numeroIntentos":'', @NumeroIntento, N''}'')
                );
            END
            ELSE
            BEGIN
                SET @NumeroIntento = @NumeroIntento + 1;

                INSERT INTO [dian].[ConsultaDian]
                    ([DocumentoID], [NumeroIntento], [Estado])
                VALUES
                    (@DocumentoID, @NumeroIntento, ''INICIADA'');

                SET @ConsultaDianID = SCOPE_IDENTITY();
                SET @Estado = ''CONSULTANDO_DIAN'';
                SET @Resultado = ''CONSULTA_INICIADA'';
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
                    ''PENDIENTE_DESCARGA'', @Estado,
                    ''CONSULTA_INICIADA'', ''FUNCTION'', N''Azure Function'',
                    CONCAT(
                        N''{"consultaDianId":'', @ConsultaDianID,
                        N'',"numeroIntento":'', @NumeroIntento, N''}''
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
        IF @@TRANCOUNT > 0 ROLLBACK TRANS'
        + N'ACTION;
        THROW;
    END CATCH;
END;';
    EXEC sys.sp_executesql @Definicion5;
    GRANT EXECUTE ON OBJECT::[dian].[sp_IniciarConsultaDocumento] TO [dian_runtime];

    -- Fuente: sql/procedures/sp_RegistrarXmlDocumento.sql
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;
    DECLARE @Definicion6 nvarchar(max);
    SET @Definicion6 = CAST(N'CREATE OR ALTER PROCEDURE [dian].[sp_RegistrarXmlDocumento]
    @DocumentoID bigint,
    @ConsultaDianID bigint,
    @BlobUri nvarchar(1000),
    @HashXmlSha256 varchar(128),
    @TamanoBytes bigint,
    @TipoXmlDetectado nvarchar(80) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Hash varchar(128) = LOWER(NULLIF(LTRIM(RTRIM(@HashXmlSha256)), ''''));
    DECLARE @Uri nvarchar(1000) = NULLIF(LTRIM(RTRIM(@BlobUri)), N'''');
    DECLARE @ClienteID bigint;
    DECLARE @DocumentoConsultaID bigint;
    DECLARE @EstadoConsulta varchar(20);
    DECLARE @EstadoDocumento varchar(30);
    DECLARE @DocumentoXmlID bigint;
    DECLARE @HashExistente char(64);
    DECLARE @UriExistente nvarchar(1000);
    DECLARE @TamanoExistente bigint;
    DECLARE @RutaEsperada nvarchar(300);
    DECLARE @Resultado varchar(30);
    DECLARE @LockResult int;
    DECLARE @LockResource nvarchar(255);

    IF @DocumentoID IS NULL OR @DocumentoID <= 0
       OR @ConsultaDianID IS NULL OR @ConsultaDianID <= 0
        THROW 50501, ''Los identificadores deben ser positivos.'', 1;

    IF @Hash IS NULL
       OR LEN(@Hash) <> 64
       OR @Hash COLLATE Latin1_General_100_BIN2 LIKE ''%[^0-9a-f]%''
        THROW 50502, ''El SHA-256 no es valido.'', 1;

    IF @TamanoBytes IS NULL OR @TamanoBytes <= 0
        THROW 50503, ''El XML debe tener contenido.'', 1;

    IF @Uri IS NULL OR LEFT(@Uri, 8) <> N''https://''
       OR CHARINDEX(N''?'', @Uri) > 0
        THROW 50504, ''La URI del Blob no es valida.'', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        SET @LockResource = CONCAT(N''dian:consulta-documento:'', @DocumentoID);

        EXEC @LockResult = sys.sp_getapplock
            @Resource = @LockResource,
            @LockMode = ''Exclusive'',
            @LockOwner = ''Transaction'',
            @LockTimeout = 10000;

        IF @LockResult < 0
            THROW 50505, ''No se pudo bloquear el documento.'', 1;

        SELECT
            @ClienteID = [ClienteID],
            @EstadoDocumento = [Estad' AS nvarchar(max))
        + N'oProceso]
        FROM [dian].[Documento] WITH (UPDLOCK, HOLDLOCK)
        WHERE [DocumentoID] = @DocumentoID;

        IF @ClienteID IS NULL
            THROW 50506, ''El documento no existe.'', 1;

        SELECT
            @DocumentoConsultaID = [DocumentoID],
            @EstadoConsulta = [Estado]
        FROM [dian].[ConsultaDian] WITH (UPDLOCK, HOLDLOCK)
        WHERE [ConsultaDianID] = @ConsultaDianID;

        IF @DocumentoConsultaID IS NULL
           OR @DocumentoConsultaID <> @DocumentoID
            THROW 50507, ''La consulta no corresponde al documento.'', 1;

        SET @RutaEsperada = CONCAT(
            N''/xml-dian/clientes/'', @ClienteID,
            N''/documentos/'', @DocumentoID,
            N''/'', @Hash, N''.xml''
        );

        IF RIGHT(@Uri, LEN(@RutaEsperada)) <> @RutaEsperada
            THROW 50508, ''La ruta del Blob no es deterministica.'', 1;

        SELECT TOP (1)
            @DocumentoXmlID = [DocumentoXmlID],
            @HashExistente = [HashXmlSha256],
            @UriExistente = [BlobUri],
            @TamanoExistente = [TamanoBytes]
        FROM [dian].[DocumentoXml] WITH (UPDLOCK, HOLDLOCK)
        WHERE [DocumentoID] = @DocumentoID
          AND [EsVigente] = 1;

        IF @DocumentoXmlID IS NOT NULL
        BEGIN
            IF @HashExistente <> CONVERT(char(64), @Hash)
               OR @UriExistente <> @Uri
               OR @TamanoExistente <> @TamanoBytes
                THROW 50509, ''Ya existe un XML vigente diferente.'', 1;

            SET @Resultado = ''XML_EXISTENTE'';
        END
        ELSE
        BEGIN
            IF @EstadoConsulta <> ''INICIADA''
               OR @EstadoDocumento <> ''CONSULTANDO_DIAN''
                THROW 50510, ''La consulta ya no admite registrar XML.'', 1;

            IF EXISTS
            (
                SELECT 1
                FROM [dian].[DocumentoXml]
                WHERE [DocumentoID] = @DocumentoID
                  AND [HashXmlSha256] = CONVERT(char(64), @Hash)
            )
             '
        + N'   THROW 50511, ''El hash ya existe en un XML no vigente.'', 1;

            INSERT INTO [dian].[DocumentoXml]
            (
                [DocumentoID], [ConsultaDianID], [BlobUri],
                [HashXmlSha256], [TamanoBytes], [TipoContenido],
                [TipoXmlDetectado], [EsVigente]
            )
            VALUES
            (
                @DocumentoID, @ConsultaDianID, @Uri,
                CONVERT(char(64), @Hash), @TamanoBytes,
                N''application/xml'', @TipoXmlDetectado, 1
            );

            SET @DocumentoXmlID = SCOPE_IDENTITY();
            SET @Resultado = ''XML_REGISTRADO'';
        END;

        COMMIT TRANSACTION;

        SELECT
            @DocumentoXmlID AS [DocumentoXmlID],
            @DocumentoID AS [DocumentoID],
            @ConsultaDianID AS [ConsultaDianID],
            @Hash AS [HashXmlSha256],
            @Resultado AS [Resultado];
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;';
    EXEC sys.sp_executesql @Definicion6;
    GRANT EXECUTE ON OBJECT::[dian].[sp_RegistrarXmlDocumento] TO [dian_runtime];

    -- Fuente: sql/procedures/sp_FinalizarConsultaDocumento.sql
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;
    DECLARE @Definicion7 nvarchar(max);
    SET @Definicion7 = CAST(N'CREATE OR ALTER PROCEDURE [dian].[sp_FinalizarConsultaDocumento]
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
        UPPER(NULLIF(LTRIM(RTRIM(@Resultado)), ''''));
    DECLARE @ResultadoFinal varchar(20);
    DECLARE @DocumentoID bigint;
    DECLARE @NumeroIntento smallint;
    DECLARE @EstadoConsulta varchar(20);
    DECLARE @EstadoAnterior varchar(30);
    DECLARE @EstadoNuevo varchar(30);
    DECLARE @CargaArchivoID bigint;
    DECLARE @Reintentar bit = 0;
    DECLARE @Operacion varchar(20) = ''FINALIZADA'';
    DECLARE @LockResult int;
    DECLARE @LockResource nvarchar(255);

    IF @ConsultaDianID IS NULL OR @ConsultaDianID <= 0
        THROW 50601, ''La consulta DIAN es obligatoria.'', 1;

    IF @ResultadoSolicitado IS NULL
       OR @ResultadoSolicitado NOT IN (''OK'', ''NO_ENCONTRADO'', ''REINTENTO'', ''ERROR'')
        THROW 50602, ''El resultado no es valido.'', 1;

    IF @DuracionMs IS NOT NULL AND @DuracionMs < 0
        THROW 50603, ''La duracion no puede ser negativa.'', 1;

    IF @MaximoIntentos IS NULL OR @MaximoIntentos < 1
        THROW 50604, ''El maximo de intentos debe ser positivo.'', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @DocumentoID = [DocumentoID]
        FROM [dian].[ConsultaDian]
        WHERE [ConsultaDianID] = @ConsultaDianID;

        IF @DocumentoID IS NULL
            THROW 50605, ''La consulta no existe.'', 1;

        SET @LockResource = CONCAT(N''dian:consulta-documento:'', @DocumentoID);

        EXEC @LockResult = sys.sp_getapplock
            @Resource = @LockResource,
            @LockMode = ''Exclusive'',
            @LockOwner = ''Transaction'',
            @LockTimeout = 10000;

        IF @LockResult ' AS nvarchar(max))
        + N'< 0
            THROW 50606, ''No se pudo bloquear el documento.'', 1;

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

        IF @EstadoConsulta <> ''INICIADA''
        BEGIN
            SET @ResultadoFinal = @EstadoConsulta;
            SET @Operacion = ''YA_FINALIZADA'';
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
                SET @ResultadoFinal = ''OK'';

            IF @ResultadoFinal = ''OK''
               AND NOT EXISTS
               (
                   SELECT 1
                   FROM [dian].[DocumentoXml]
                   WHERE [ConsultaDianID] = @ConsultaDianID
                     AND [DocumentoID] = @DocumentoID
                     AND [EsVigente] = 1
               )
                THROW 50607, ''No hay XML vigente para finalizar en OK.'', 1;

            IF @ResultadoFinal = ''REINTENTO''
               AND @NumeroIntento >= @MaximoIntentos
                SET @ResultadoFinal = ''ERROR'';

            IF @EstadoAnterior = ''CONSULTANDO_DIAN''
            BEGIN
                SET @EstadoNuevo = CASE @ResultadoFinal
                    WHEN ''OK'' THEN ''XML_DESCARGADO''
                    WHEN ''NO_ENCONTRADO'' THEN ''NO_ENCONTRADO''
                    WHEN ''REINTENT'
        + N'O'' THEN ''PENDIENTE_DESCARGA''
                    ELSE ''ERROR''
                END;

                IF @ResultadoFinal = ''REINTENTO''
                    SET @Reintentar = 1;
            END
            ELSE IF @EstadoAnterior <> ''REQUIERE_REVISION''
            BEGIN
                -- Un intento antiguo no puede sobrescribir un estado posterior.
                SET @ResultadoFinal = ''ERROR'';
            END;

            UPDATE [dian].[ConsultaDian]
            SET [Estado] = @ResultadoFinal,
                [FechaFinUTC] = SYSUTCDATETIME(),
                [CodigoDian] = NULLIF(LTRIM(RTRIM(@CodigoDian)), N''''),
                [MensajeDianSanitizado] =
                    NULLIF(LTRIM(RTRIM(@MensajeDianSanitizado)), N''''),
                [HttpStatus] = @HttpStatus,
                [DuracionMs] = @DuracionMs,
                [ErrorTipo] = NULLIF(LTRIM(RTRIM(@ErrorTipo)), N'''')
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
                    WHEN ''OK'' THEN ''XML_DESCARGADO''
                    WHEN ''NO_ENCONTRADO'' THEN ''NO_ENCONTRADO''
                    WHEN ''REINTENTO'' THEN ''CONSULTA_REINTENTO''
                    ELSE ''CONSULTA_ERROR''
                END,
                CASE
                    WHEN @ResultadoFinal IN (''OK'', ''NO_ENCONTRADO'') THEN ''DIAN''
                    ELSE ''FUNCTION''
                END,
      '
        + N'          N''Azure Function'',
                CONCAT(
                    N''{"consultaDianId":'', @ConsultaDianID,
                    N'',"numeroIntento":'', @NumeroIntento, N''}''
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
END;';
    EXEC sys.sp_executesql @Definicion7;
    GRANT EXECUTE ON OBJECT::[dian].[sp_FinalizarConsultaDocumento] TO [dian_runtime];

    IF (SELECT COUNT(*) FROM sys.tables WHERE schema_id = SCHEMA_ID(N'dian')) <> 8
       OR (SELECT COUNT(*) FROM sys.procedures WHERE schema_id = SCHEMA_ID(N'dian')) <> 7
        THROW 51042, 'El numero de objetos creados no coincide; se revierte todo.', 1;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;

SELECT DB_NAME() AS BaseActual,
       (SELECT COUNT(*) FROM sys.tables WHERE schema_id = SCHEMA_ID(N'dian')) AS TablasDian,
       (SELECT COUNT(*) FROM sys.procedures WHERE schema_id = SCHEMA_ID(N'dian')) AS ProcedimientosDian;
