-- Carga historica contable, aditiva y sin GO para el editor web de Azure SQL.
-- Ejecutar una sola vez. No modifica los objetos ni los datos del esquema dian.
-- La primera version de (ClienteID, FuenteContable, IndContabilidad) prevalece.
-- El hash de contenido es informativo y NO es una clave unica de movimiento.
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'sqldb-dian-xml-cpabaas-dev'
    THROW 50800, 'Conectado a una base distinta de sqldb-dian-xml-cpabaas-dev.', 1;

IF OBJECT_ID(N'dian.Cliente', N'U') IS NULL
    THROW 50801, 'Falta la tabla dian.Cliente; no se modifico nada.', 1;

IF OBJECT_ID(N'contabilidad.CargaArchivo', N'U') IS NOT NULL
   OR OBJECT_ID(N'contabilidad.MovimientoHistorico', N'U') IS NOT NULL
   OR OBJECT_ID(N'contabilidad.CargaMovimiento', N'U') IS NOT NULL
    THROW 50802, 'Ya existe alguna tabla contable; no se modifico nada.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    IF SCHEMA_ID(N'contabilidad') IS NULL
        EXEC(N'CREATE SCHEMA [contabilidad] AUTHORIZATION [dbo];');

    CREATE TABLE [contabilidad].[CargaArchivo]
    (
        [CargaArchivoID] bigint IDENTITY(1,1) NOT NULL,
        [ClienteID] bigint NOT NULL,
        [FuenteContable] nvarchar(80) NOT NULL,
        [NombreArchivo] nvarchar(260) NOT NULL,
        [NombreHoja] nvarchar(128) NOT NULL,
        [SharePointItemID] nvarchar(150) NULL,
        [SharePointUrl] nvarchar(1000) NULL,
        [ETag] nvarchar(200) NULL,
        [CargadoPor] nvarchar(256) NULL,
        [BlobUri] nvarchar(1000) NOT NULL,
        [TamanoBytes] bigint NOT NULL,
        [HashArchivoSha256] char(64) NOT NULL,
        [Estado] varchar(20) NOT NULL
            CONSTRAINT [DF_ContCarga_Estado] DEFAULT ('RECIBIDA'),
        [TotalFilas] int NULL,
        [FilasNuevas] int NULL,
        [FilasDuplicadas] int NULL,
        [FilasConflicto] int NULL,
        [FilasRechazadas] int NULL,
        [FechaMinima] date NULL,
        [FechaMaxima] date NULL,
        [Mensaje] nvarchar(2000) NULL,
        [FechaInicioUTC] datetime2(3) NOT NULL
            CONSTRAINT [DF_ContCarga_FechaInicio] DEFAULT (SYSUTCDATETIME()),
        [FechaFinUTC] datetime2(3) NULL,
        [RowVersion] rowversion NOT NULL,
        CONSTRAINT [PK_ContCarga] PRIMARY KEY CLUSTERED ([CargaArchivoID]),
        CONSTRAINT [FK_ContCarga_Cliente] FOREIGN KEY ([ClienteID])
            REFERENCES [dian].[Cliente] ([ClienteID]),
        CONSTRAINT [UQ_ContCarga_Alcance] UNIQUE
            ([CargaArchivoID], [ClienteID], [FuenteContable]),
        CONSTRAINT [CK_ContCarga_Estado] CHECK
            ([Estado] IN ('RECIBIDA', 'PROCESANDO', 'OK', 'PARCIAL', 'ERROR')),
        CONSTRAINT [CK_ContCarga_Tamano] CHECK ([TamanoBytes] > 0),
        CONSTRAINT [CK_ContCarga_Identificadores] CHECK
        (
            NULLIF(LTRIM(RTRIM([FuenteContable])), N'') IS NOT NULL AND
            NULLIF(LTRIM(RTRIM([NombreArchivo])), N'') IS NOT NULL AND
            NULLIF(LTRIM(RTRIM([NombreHoja])), N'') IS NOT NULL AND
            NULLIF(LTRIM(RTRIM([BlobUri])), N'') IS NOT NULL
        ),
        CONSTRAINT [CK_ContCarga_Hash] CHECK
        (
            LEN([HashArchivoSha256]) = 64 AND
            [HashArchivoSha256] COLLATE Latin1_General_100_BIN2
                NOT LIKE '%[^0-9a-f]%'
        ),
        CONSTRAINT [CK_ContCarga_Conteos] CHECK
        (
            ([TotalFilas] IS NULL OR [TotalFilas] >= 0) AND
            ([FilasNuevas] IS NULL OR [FilasNuevas] >= 0) AND
            ([FilasDuplicadas] IS NULL OR [FilasDuplicadas] >= 0) AND
            ([FilasConflicto] IS NULL OR [FilasConflicto] >= 0) AND
            ([FilasRechazadas] IS NULL OR [FilasRechazadas] >= 0)
        ),
        CONSTRAINT [CK_ContCarga_Fechas] CHECK
            ([FechaMinima] IS NULL OR [FechaMaxima] IS NULL
             OR [FechaMinima] <= [FechaMaxima])
    );

    -- Reenvios exactos devuelven la carga existente; no se crea otra carga.
    CREATE UNIQUE INDEX [UX_ContCarga_Archivo]
        ON [contabilidad].[CargaArchivo]
            ([ClienteID], [FuenteContable], [HashArchivoSha256]);

    CREATE UNIQUE INDEX [UX_ContCarga_SharePointVersion]
        ON [contabilidad].[CargaArchivo]
            ([ClienteID], [FuenteContable], [SharePointItemID], [ETag])
        WHERE [SharePointItemID] IS NOT NULL AND [ETag] IS NOT NULL;

    CREATE TABLE [contabilidad].[MovimientoHistorico]
    (
        [MovimientoID] bigint IDENTITY(1,1) NOT NULL,
        [ClienteID] bigint NOT NULL,
        [FuenteContable] nvarchar(80) NOT NULL,
        [IndContabilidad] nvarchar(100) NOT NULL,
        [VersionHash] smallint NOT NULL
            CONSTRAINT [DF_ContMov_VersionHash] DEFAULT (1),
        [HashContenidoSha256] char(64) NOT NULL,
        [CargaPrimeraID] bigint NOT NULL,
        [FilaPrimera] int NOT NULL,
        [Fecha] date NOT NULL,
        [Documento] nvarchar(100) NOT NULL,
        [TipoDoc] nvarchar(50) NOT NULL,
        [NumDoc] nvarchar(100) NOT NULL,
        [Cuenta] nvarchar(50) NOT NULL,
        [NomCuenta] nvarchar(300) NULL,
        [Concepto] nvarchar(2000) NULL,
        [Naturaleza] char(1) NOT NULL,
        [Centro] nvarchar(100) NULL,
        [CodigoCtaBancaria] nvarchar(100) NULL,
        [CodigoUsuario] nvarchar(100) NULL,
        [Debito] decimal(19,4) NOT NULL,
        [Credito] decimal(19,4) NOT NULL,
        [IdentidadTercero] nvarchar(100) NOT NULL,
        [DocFuente] nvarchar(100) NULL,
        [FechaSistema] datetime2(3) NULL,
        [Dv] nvarchar(20) NULL,
        [NombreTercero] nvarchar(300) NULL,
        [CuentaBancaria] nvarchar(100) NULL,
        [NomCentro] nvarchar(300) NULL,
        [DescripcionCorta] nvarchar(1000) NULL,
        [Direccion] nvarchar(500) NULL,
        [Telefonos] nvarchar(200) NULL,
        [NumeroMovil] nvarchar(100) NULL,
        [NomCiudad] nvarchar(200) NULL,
        [CC] nvarchar(100) NULL,
        [FechaRegistroUTC] datetime2(3) NOT NULL
            CONSTRAINT [DF_ContMov_FechaRegistro] DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT [PK_ContMov] PRIMARY KEY CLUSTERED ([MovimientoID]),
        CONSTRAINT [UQ_ContMov_OrigenID] UNIQUE
            ([ClienteID], [FuenteContable], [IndContabilidad]),
        CONSTRAINT [UQ_ContMov_Alcance] UNIQUE
            ([MovimientoID], [ClienteID], [FuenteContable]),
        CONSTRAINT [FK_ContMov_Carga] FOREIGN KEY
            ([CargaPrimeraID], [ClienteID], [FuenteContable])
            REFERENCES [contabilidad].[CargaArchivo]
                ([CargaArchivoID], [ClienteID], [FuenteContable]),
        CONSTRAINT [CK_ContMov_Fila] CHECK ([FilaPrimera] >= 2),
        CONSTRAINT [CK_ContMov_Ind] CHECK
            (NULLIF(LTRIM(RTRIM([IndContabilidad])), N'') IS NOT NULL),
        CONSTRAINT [CK_ContMov_Naturaleza] CHECK ([Naturaleza] IN ('D', 'C')),
        CONSTRAINT [CK_ContMov_VersionHash] CHECK ([VersionHash] = 1),
        CONSTRAINT [CK_ContMov_Hash] CHECK
        (
            LEN([HashContenidoSha256]) = 64 AND
            [HashContenidoSha256] COLLATE Latin1_General_100_BIN2
                NOT LIKE '%[^0-9a-f]%'
        )
    );

    CREATE INDEX [IX_ContMov_Fecha]
        ON [contabilidad].[MovimientoHistorico]
            ([ClienteID], [FuenteContable], [Fecha]);

    -- No es unico: movimientos legitimos pueden compartir contenido.
    CREATE INDEX [IX_ContMov_Hash]
        ON [contabilidad].[MovimientoHistorico]
            ([ClienteID], [FuenteContable], [HashContenidoSha256]);

    CREATE TABLE [contabilidad].[CargaMovimiento]
    (
        [CargaArchivoID] bigint NOT NULL,
        [FilaOrigen] int NOT NULL,
        [ClienteID] bigint NOT NULL,
        [FuenteContable] nvarchar(80) NOT NULL,
        [IndContabilidad] nvarchar(100) NULL,
        [HashContenidoSha256] char(64) NULL,
        [MovimientoID] bigint NULL,
        [Resultado] varchar(30) NOT NULL,
        [Detalle] nvarchar(1000) NULL,
        [FechaRegistroUTC] datetime2(3) NOT NULL
            CONSTRAINT [DF_ContCargaMov_Fecha] DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT [PK_ContCargaMov] PRIMARY KEY CLUSTERED
            ([CargaArchivoID], [FilaOrigen]),
        CONSTRAINT [FK_ContCargaMov_Carga] FOREIGN KEY
            ([CargaArchivoID], [ClienteID], [FuenteContable])
            REFERENCES [contabilidad].[CargaArchivo]
                ([CargaArchivoID], [ClienteID], [FuenteContable]),
        CONSTRAINT [FK_ContCargaMov_Movimiento] FOREIGN KEY
            ([MovimientoID], [ClienteID], [FuenteContable])
            REFERENCES [contabilidad].[MovimientoHistorico]
                ([MovimientoID], [ClienteID], [FuenteContable]),
        CONSTRAINT [CK_ContCargaMov_Fila] CHECK ([FilaOrigen] >= 2),
        CONSTRAINT [CK_ContCargaMov_Resultado] CHECK
            ([Resultado] IN
                ('NUEVO', 'DUPLICADO', 'ID_CON_CONTENIDO_DISTINTO', 'RECHAZADO')),
        CONSTRAINT [CK_ContCargaMov_Vinculo] CHECK
        (
            ([Resultado] = 'RECHAZADO' AND [MovimientoID] IS NULL)
            OR ([Resultado] <> 'RECHAZADO' AND [MovimientoID] IS NOT NULL
                AND [IndContabilidad] IS NOT NULL
                AND [HashContenidoSha256] IS NOT NULL)
        ),
        CONSTRAINT [CK_ContCargaMov_Hash] CHECK
        (
            [HashContenidoSha256] IS NULL OR
            (
                LEN([HashContenidoSha256]) = 64 AND
                [HashContenidoSha256] COLLATE Latin1_General_100_BIN2
                    NOT LIKE '%[^0-9a-f]%'
            )
        )
    );

    CREATE INDEX [IX_ContCargaMov_Movimiento]
        ON [contabilidad].[CargaMovimiento] ([MovimientoID])
        WHERE [MovimientoID] IS NOT NULL;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;

SELECT DB_NAME() AS BaseActual,
       (SELECT COUNT(*) FROM sys.tables
        WHERE schema_id = SCHEMA_ID(N'contabilidad')) AS TablasContabilidad;
