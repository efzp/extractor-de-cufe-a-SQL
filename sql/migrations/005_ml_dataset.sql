-- Objetos de almacenamiento para snapshots de entrenamiento ML.
-- El instalador integrado controla la transaccion y las precondiciones.
IF SCHEMA_ID(N'ml') IS NULL
    EXEC(N'CREATE SCHEMA [ml] AUTHORIZATION [dbo];');

CREATE TABLE [ml].[DatasetVersion]
(
    [DatasetVersionID] bigint IDENTITY(1,1) NOT NULL,
    [ClienteID] bigint NOT NULL,
    [FuenteContable] nvarchar(80) NOT NULL,
    [VersionContrato] smallint CONSTRAINT [DF_MlDatasetVersion_Contrato] DEFAULT (1) NOT NULL,
    [HashCodigoSha256] char(64) NOT NULL,
    [HashFacturasSha256] char(64) NOT NULL,
    [HashMovimientosSha256] char(64) NOT NULL,
    [HashFilasSha256] binary(32) NOT NULL,
    [TotalFacturasOrigen] int NOT NULL,
    [TotalFilas] int NOT NULL,
    [FechaCreacionUTC] datetime2(3) CONSTRAINT [DF_MlDatasetVersion_Fecha] DEFAULT (SYSUTCDATETIME()) NOT NULL,
    CONSTRAINT [PK_MlDatasetVersion] PRIMARY KEY CLUSTERED ([DatasetVersionID]),
    CONSTRAINT [FK_MlDatasetVersion_Cliente] FOREIGN KEY ([ClienteID]) REFERENCES [dian].[Cliente] ([ClienteID]),
    CONSTRAINT [UQ_MlDatasetVersion_Hash] UNIQUE
        ([ClienteID], [FuenteContable], [HashCodigoSha256], [HashFacturasSha256],
         [HashMovimientosSha256], [HashFilasSha256], [TotalFacturasOrigen]),
    CONSTRAINT [CK_MlDatasetVersion_Contrato] CHECK ([VersionContrato] = 1),
    CONSTRAINT [CK_MlDatasetVersion_Conteos] CHECK
        ([TotalFacturasOrigen] >= [TotalFilas] AND [TotalFilas] > 0),
    CONSTRAINT [CK_MlDatasetVersion_Fuente] CHECK
        (NULLIF(LTRIM(RTRIM([FuenteContable])), N'') IS NOT NULL),
    CONSTRAINT [CK_MlDatasetVersion_HashCodigo] CHECK
        (LEN([HashCodigoSha256]) = 64 AND [HashCodigoSha256] COLLATE Latin1_General_100_BIN2 NOT LIKE '%[^0-9a-f]%'),
    CONSTRAINT [CK_MlDatasetVersion_HashFacturas] CHECK
        (LEN([HashFacturasSha256]) = 64 AND [HashFacturasSha256] COLLATE Latin1_General_100_BIN2 NOT LIKE '%[^0-9a-f]%'),
    CONSTRAINT [CK_MlDatasetVersion_HashMovimientos] CHECK
        (LEN([HashMovimientosSha256]) = 64 AND [HashMovimientosSha256] COLLATE Latin1_General_100_BIN2 NOT LIKE '%[^0-9a-f]%')
);

CREATE TABLE [ml].[DatasetFila]
(
    [DatasetVersionID] bigint NOT NULL,
    [DocumentoXmlID] bigint NOT NULL,
    [VersionExtractor] smallint NOT NULL,
    [DocumentoID] bigint NOT NULL,
    [ClaveDocumento] char(96) NOT NULL,
    [HashXmlSha256] char(64) NOT NULL,
    [EstadoMatch] varchar(20) NOT NULL,
    [LlaveAsiento] nvarchar(max) NOT NULL,
    [NitProveedorNorm] nvarchar(max) NULL,
    [CiudadProveedorModelo] nvarchar(max) NULL,
    [TaxLevelProveedorLimpio] nvarchar(max) NULL,
    [TaxSchemeIdLimpio] nvarchar(max) NULL,
    [TaxSchemeNombreLimpio] nvarchar(max) NULL,
    [CodigoIndustriaProveedorLimpio] nvarchar(max) NULL,
    [FechaEmision] date NOT NULL,
    [PayableAmount] decimal(38,18) NOT NULL,
    [DescuentoTotal] decimal(38,18) NULL,
    [RecargoTotal] decimal(38,18) NULL,
    [TieneIva] bit NULL,
    [TieneInc] bit NULL,
    [FlagDescuento] bit NULL,
    [FlagRecargo] bit NULL,
    [FlagUmbralRfServicios] bit NULL,
    [FlagUmbralReteicaBogotaServicios] bit NULL,
    [FlagUmbralReteicaBogotaCompras] bit NULL,
    [FlagDiferenciaPayableTaxInclusive] bit NULL,
    [StandardItemIdentificationLimpio] nvarchar(max) NULL,
    [TargetPlantillaCuentas] nvarchar(max) NOT NULL,
    CONSTRAINT [PK_MlDatasetFila] PRIMARY KEY CLUSTERED ([DatasetVersionID], [DocumentoXmlID]),
    CONSTRAINT [FK_MlDatasetFila_Version] FOREIGN KEY ([DatasetVersionID])
        REFERENCES [ml].[DatasetVersion] ([DatasetVersionID]),
    CONSTRAINT [FK_MlDatasetFila_Extraccion] FOREIGN KEY ([DocumentoXmlID], [VersionExtractor])
        REFERENCES [dian].[XmlExtraccion] ([DocumentoXmlID], [VersionExtractor]),
    CONSTRAINT [CK_MlDatasetFila_Extractor] CHECK ([VersionExtractor] = 1),
    CONSTRAINT [CK_MlDatasetFila_Estado] CHECK ([EstadoMatch] IN ('OK_UNICO', 'OK_TEXTO', 'OK_VALOR')),
    CONSTRAINT [CK_MlDatasetFila_Clave] CHECK
        (LEN([ClaveDocumento]) = 96 AND [ClaveDocumento] COLLATE Latin1_General_100_BIN2 NOT LIKE '%[^0-9a-f]%'),
    CONSTRAINT [CK_MlDatasetFila_Target] CHECK
        (NULLIF(LTRIM(RTRIM([TargetPlantillaCuentas])), N'') IS NOT NULL),
    CONSTRAINT [CK_MlDatasetFila_Asiento] CHECK
        (NULLIF(LTRIM(RTRIM([LlaveAsiento])), N'') IS NOT NULL)
);

CREATE UNIQUE INDEX [UX_MlDatasetFila_Clave]
    ON [ml].[DatasetFila] ([DatasetVersionID], [ClaveDocumento]);
