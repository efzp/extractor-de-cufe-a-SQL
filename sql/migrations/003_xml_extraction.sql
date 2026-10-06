-- Ampliación aditiva para XML ya registrados. Ejecutar una sola vez antes de
-- instalar los procedimientos sp_*ExtraccionXml. No modifica datos existentes.
SET XACT_ABORT ON;
IF DB_NAME() <> N'sqldb-dian-xml-cpabaas-dev'
    THROW 50700, 'Base de datos inesperada para la migracion XML.', 1;

IF OBJECT_ID(N'dian.DocumentoXml', N'U') IS NULL
    THROW 50701, 'Falta la tabla dian.DocumentoXml.', 1;

BEGIN TRY
    BEGIN TRANSACTION;
    IF OBJECT_ID(N'dian.XmlExtraccion', N'U') IS NULL
    BEGIN
        CREATE TABLE [dian].[XmlExtraccion]
        (
            [DocumentoXmlID] bigint NOT NULL,
            [VersionExtractor] smallint NOT NULL,
            [DocumentoID] bigint NOT NULL,
            [HashXmlSha256] char(64) NOT NULL,
            [TipoXml] varchar(20) NOT NULL,
            [ClaveDocumento] char(96) NOT NULL,
            [NumeroDocumento] nvarchar(100) NOT NULL,
            [FechaEmision] date NOT NULL,
            [NitEmisor] nvarchar(20) NOT NULL,
            [NombreEmisor] nvarchar(300) NOT NULL,
            [CiudadEmisor] nvarchar(200) NULL,
            [TaxLevelEmisor] nvarchar(100) NULL,
            [TaxSchemeIdEmisor] nvarchar(100) NULL,
            [TaxSchemeNombreEmisor] nvarchar(200) NULL,
            [CodigoIndustriaEmisor] nvarchar(100) NULL,
            [NitReceptor] nvarchar(20) NOT NULL,
            [NombreReceptor] nvarchar(300) NOT NULL,
            [Divisa] varchar(10) NOT NULL,
            [CantidadLineas] int NOT NULL,
            [LineExtensionAmount] decimal(38,18) NOT NULL,
            [TaxExclusiveAmount] decimal(38,18) NOT NULL,
            [TaxInclusiveAmount] decimal(38,18) NOT NULL,
            [PayableAmount] decimal(38,18) NOT NULL,
            [IvaTotal] decimal(38,18) NOT NULL,
            [IncTotal] decimal(38,18) NOT NULL,
            [AllowanceTotal] decimal(38,18) NOT NULL,
            [ChargeTotal] decimal(38,18) NOT NULL,
            [DescuentoHistorico] decimal(38,18) NOT NULL,
            [RecargoHistorico] decimal(38,18) NOT NULL,
            [DiferenciaSemanticaDescuento] AS
                (CONVERT(bit, CASE WHEN [AllowanceTotal] <> [DescuentoHistorico] THEN 1 ELSE 0 END)) PERSISTED,
            [DiferenciaSemanticaRecargo] AS
                (CONVERT(bit, CASE WHEN [ChargeTotal] <> [RecargoHistorico] THEN 1 ELSE 0 END)) PERSISTED,
            [PrimeraDescripcion] nvarchar(2000) NULL,
            [FechaExtraccionUTC] datetime2(3) NOT NULL
                CONSTRAINT [DF_DianXmlExtraccion_Fecha] DEFAULT (SYSUTCDATETIME()),
            CONSTRAINT [PK_DianXmlExtraccion] PRIMARY KEY CLUSTERED
                ([DocumentoXmlID], [VersionExtractor]),
            CONSTRAINT [FK_DianXmlExtraccion_Xml] FOREIGN KEY ([DocumentoXmlID])
                REFERENCES [dian].[DocumentoXml] ([DocumentoXmlID]),
            CONSTRAINT [FK_DianXmlExtraccion_Documento] FOREIGN KEY ([DocumentoID])
                REFERENCES [dian].[Documento] ([DocumentoID]),
            CONSTRAINT [CK_DianXmlExtraccion_Tipo] CHECK ([TipoXml] IN ('Invoice', 'CreditNote')),
            CONSTRAINT [CK_DianXmlExtraccion_Cantidad] CHECK ([CantidadLineas] > 0)
        );
        CREATE INDEX [IX_DianXmlExtraccion_Documento]
            ON [dian].[XmlExtraccion] ([DocumentoID], [VersionExtractor]);
    END;

    IF OBJECT_ID(N'dian.XmlLinea', N'U') IS NULL
    BEGIN
        CREATE TABLE [dian].[XmlLinea]
        (
            [DocumentoXmlID] bigint NOT NULL,
            [VersionExtractor] smallint NOT NULL,
            [Ordinal] int NOT NULL,
            [IdLinea] nvarchar(100) NOT NULL,
            [Descripcion] nvarchar(2000) NULL,
            [CodigoEstandar] nvarchar(100) NULL,
            [Cantidad] decimal(38,18) NOT NULL,
            [Unidad] nvarchar(20) NULL,
            [Precio] decimal(38,18) NOT NULL,
            [ImporteLinea] decimal(38,18) NOT NULL,
            CONSTRAINT [PK_DianXmlLinea] PRIMARY KEY CLUSTERED
                ([DocumentoXmlID], [VersionExtractor], [Ordinal]),
            CONSTRAINT [FK_DianXmlLinea_Extraccion] FOREIGN KEY
                ([DocumentoXmlID], [VersionExtractor]) REFERENCES
                [dian].[XmlExtraccion] ([DocumentoXmlID], [VersionExtractor]),
            CONSTRAINT [CK_DianXmlLinea_Ordinal] CHECK ([Ordinal] >= 1)
        );
    END;

    IF OBJECT_ID(N'dian.XmlExtraccionError', N'U') IS NULL
    BEGIN
        CREATE TABLE [dian].[XmlExtraccionError]
        (
            [DocumentoXmlID] bigint NOT NULL,
            [VersionExtractor] smallint NOT NULL,
            [Codigo] varchar(60) NOT NULL,
            [Detalle] nvarchar(1000) NOT NULL,
            [FechaErrorUTC] datetime2(3) NOT NULL
                CONSTRAINT [DF_DianXmlExtraccionError_Fecha] DEFAULT (SYSUTCDATETIME()),
            CONSTRAINT [PK_DianXmlExtraccionError] PRIMARY KEY CLUSTERED
                ([DocumentoXmlID], [VersionExtractor]),
            CONSTRAINT [FK_DianXmlExtraccionError_Xml] FOREIGN KEY ([DocumentoXmlID])
                REFERENCES [dian].[DocumentoXml] ([DocumentoXmlID])
        );
    END;
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
