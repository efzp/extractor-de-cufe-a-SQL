-- Instalación aditiva de extracción XML DIAN, en un solo envío al editor web de Azure SQL.
-- No usa GO, no elimina objetos ni datos y se puede volver a ejecutar.
-- Generado por scripts/Generar-InstalacionExtraccionXmlDian.py.
-- Requiere el esquema base dian y el rol dian_runtime ya instalados.
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'sqldb-dian-xml-cpabaas-dev'
    THROW 50720, 'Conectado a una base distinta de sqldb-dian-xml-cpabaas-dev.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals
               WHERE [name] = N'dian_runtime' AND [type] = 'R')
    THROW 50721, 'Falta el rol dian_runtime; no se modifico nada.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    -- Fuente: sql/migrations/003_xml_extraction.sql
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

    DECLARE @Definicion nvarchar(max);
    -- Fuente: sql/procedures/sp_ObtenerXmlParaExtraccion.sql
    SET @Definicion = CAST(N'CREATE OR ALTER PROCEDURE [dian].[sp_ObtenerXmlParaExtraccion]
    @DocumentoXmlID bigint,
    @VersionExtractor smallint = 1
AS
BEGIN
    SET NOCOUNT ON;
    IF @DocumentoXmlID IS NULL OR @DocumentoXmlID <= 0 OR @VersionExtractor < 1
        THROW 50702, ''Identificadores de extraccion invalidos.'', 1;
    SELECT x.[DocumentoXmlID], x.[DocumentoID], d.[ClienteID], d.[ClaveDocumento],
           x.[BlobUri], x.[HashXmlSha256], x.[TamanoBytes], x.[TipoXmlDetectado],
           x.[EsVigente], CAST(CASE WHEN e.[DocumentoXmlID] IS NULL THEN 0 ELSE 1 END AS bit) AS [YaExtraido],
           CAST(CASE WHEN err.[DocumentoXmlID] IS NULL THEN 0 ELSE 1 END AS bit) AS [ErrorRegistrado]
    FROM [dian].[DocumentoXml] AS x
    INNER JOIN [dian].[Documento] AS d ON d.[DocumentoID] = x.[DocumentoID]
    LEFT JOIN [dian].[XmlExtraccion] AS e
      ON e.[DocumentoXmlID] = x.[DocumentoXmlID] AND e.[VersionExtractor] = @VersionExtractor
    LEFT JOIN [dian].[XmlExtraccionError] AS err
      ON err.[DocumentoXmlID] = x.[DocumentoXmlID] AND err.[VersionExtractor] = @VersionExtractor
    WHERE x.[DocumentoXmlID] = @DocumentoXmlID;
END;' AS nvarchar(max));
    EXEC sys.sp_executesql @Definicion;

    -- Fuente: sql/procedures/sp_ListarXmlPendientesExtraccion.sql
    SET @Definicion = CAST(N'CREATE OR ALTER PROCEDURE [dian].[sp_ListarXmlPendientesExtraccion]
    @Limite int = 100,
    @VersionExtractor smallint = 1
AS
BEGIN
    SET NOCOUNT ON;
    IF @Limite NOT BETWEEN 1 AND 1000 OR @VersionExtractor < 1
        THROW 50703, ''Limite o version de extraccion invalidos.'', 1;
    SELECT TOP (@Limite) x.[DocumentoXmlID]
    FROM [dian].[DocumentoXml] AS x
    WHERE x.[EsVigente] = 1
      AND NOT EXISTS
      (
          SELECT 1 FROM [dian].[XmlExtraccion] AS e
          WHERE e.[DocumentoXmlID] = x.[DocumentoXmlID]
            AND e.[VersionExtractor] = @VersionExtractor
      )
      AND NOT EXISTS
      (
          SELECT 1 FROM [dian].[XmlExtraccionError] AS err
          WHERE err.[DocumentoXmlID] = x.[DocumentoXmlID]
            AND err.[VersionExtractor] = @VersionExtractor
      )
    ORDER BY x.[DocumentoXmlID];
END;' AS nvarchar(max));
    EXEC sys.sp_executesql @Definicion;

    -- Fuente: sql/procedures/sp_RegistrarExtraccionXml.sql
    SET @Definicion = CAST(N'CREATE OR ALTER PROCEDURE [dian].[sp_RegistrarExtraccionXml]
    @DocumentoXmlID bigint,
    @CabeceraJson nvarchar(max),
    @LineasJson nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @DocumentoXmlID IS NULL OR @DocumentoXmlID <= 0
       OR COALESCE(ISJSON(@CabeceraJson), 0) <> 1
       OR COALESCE(ISJSON(@LineasJson), 0) <> 1
        THROW 50704, ''Solicitud de extraccion invalida.'', 1;

    DECLARE @Version smallint = TRY_CONVERT(smallint, JSON_VALUE(@CabeceraJson, ''$.extractorVersion''));
    DECLARE @Tipo varchar(20) = JSON_VALUE(@CabeceraJson, ''$.xmlType'');
    DECLARE @Clave varchar(128) = LOWER(JSON_VALUE(@CabeceraJson, ''$.uuid''));
    DECLARE @Numero nvarchar(4000) = JSON_VALUE(@CabeceraJson, ''$.invoiceId'');
    DECLARE @Fecha date = TRY_CONVERT(date, JSON_VALUE(@CabeceraJson, ''$.issueDate''), 23);
    DECLARE @NitEmisor nvarchar(4000) = JSON_VALUE(@CabeceraJson, ''$.supplierNit'');
    DECLARE @NombreEmisor nvarchar(4000) = JSON_VALUE(@CabeceraJson, ''$.supplierName'');
    DECLARE @CiudadEmisor nvarchar(4000) = JSON_VALUE(@CabeceraJson, ''$.supplierCity'');
    DECLARE @TaxLevelEmisor nvarchar(4000) = JSON_VALUE(@CabeceraJson, ''$.supplierTaxLevel'');
    DECLARE @TaxSchemeIdEmisor nvarchar(4000) = JSON_VALUE(@CabeceraJson, ''$.supplierTaxSchemeId'');
    DECLARE @TaxSchemeNombreEmisor nvarchar(4000) = JSON_VALUE(@CabeceraJson, ''$.supplierTaxSchemeName'');
    DECLARE @CodigoIndustriaEmisor nvarchar(4000) = JSON_VALUE(@CabeceraJson, ''$.supplierIndustryCode'');
    DECLARE @NitReceptor nvarchar(4000) = JSON_VALUE(@CabeceraJson, ''$.customerNit'');
    DECLARE @NombreReceptor nvarchar(4000) = JSON_VALUE(@CabeceraJson, ''$.customerName'');
    DECLARE @Divisa varchar(4000) = JSON_VALUE(@CabeceraJson, ''$.currency'');
    DECLARE @Cantidad int = TRY_CONVERT' AS nvarchar(max))
        + N'(int, JSON_VALUE(@CabeceraJson, ''$.lineCount''));
    DECLARE @LineExtension decimal(38,18) = TRY_CONVERT(decimal(38,18), JSON_VALUE(@CabeceraJson, ''$.lineExtensionAmount''));
    DECLARE @TaxExclusive decimal(38,18) = TRY_CONVERT(decimal(38,18), JSON_VALUE(@CabeceraJson, ''$.taxExclusiveAmount''));
    DECLARE @TaxInclusive decimal(38,18) = TRY_CONVERT(decimal(38,18), JSON_VALUE(@CabeceraJson, ''$.taxInclusiveAmount''));
    DECLARE @Payable decimal(38,18) = TRY_CONVERT(decimal(38,18), JSON_VALUE(@CabeceraJson, ''$.payableAmount''));
    DECLARE @Iva decimal(38,18) = TRY_CONVERT(decimal(38,18), JSON_VALUE(@CabeceraJson, ''$.ivaTotal''));
    DECLARE @Inc decimal(38,18) = TRY_CONVERT(decimal(38,18), JSON_VALUE(@CabeceraJson, ''$.incTotal''));
    DECLARE @Allowance decimal(38,18) = TRY_CONVERT(decimal(38,18), JSON_VALUE(@CabeceraJson, ''$.allowanceTotal''));
    DECLARE @Charge decimal(38,18) = TRY_CONVERT(decimal(38,18), JSON_VALUE(@CabeceraJson, ''$.chargeTotal''));
    DECLARE @DescuentoHistorico decimal(38,18) = TRY_CONVERT(decimal(38,18), JSON_VALUE(@CabeceraJson, ''$.legacyDiscount''));
    DECLARE @RecargoHistorico decimal(38,18) = TRY_CONVERT(decimal(38,18), JSON_VALUE(@CabeceraJson, ''$.legacyCharge''));
    DECLARE @PrimeraDescripcion nvarchar(4000) = JSON_VALUE(@CabeceraJson, ''$.firstDescription'');

    IF @Version IS NULL OR @Version < 1 OR @Tipo IS NULL OR @Tipo NOT IN (''Invoice'', ''CreditNote'')
       OR @Clave IS NULL OR LEN(@Clave) <> 96
       OR @Clave COLLATE Latin1_General_100_BIN2 LIKE ''%[^0-9a-f]%''
       OR NULLIF(@Numero, N'''') IS NULL OR LEN(@Numero) > 100 OR @Fecha IS NULL
       OR NULLIF(@NitEmisor, N'''') IS NULL OR LEN(@NitEmisor) > 20
       OR NULLIF(@NombreEmisor, N'''') IS NULL OR LEN(@NombreEmisor) > 300
       OR LEN(COALESCE(@CiudadEmisor, N'''')) > 200
       '
        + N'OR LEN(COALESCE(@TaxLevelEmisor, N'''')) > 100
       OR LEN(COALESCE(@TaxSchemeIdEmisor, N'''')) > 100
       OR LEN(COALESCE(@TaxSchemeNombreEmisor, N'''')) > 200
       OR LEN(COALESCE(@CodigoIndustriaEmisor, N'''')) > 100
       OR NULLIF(@NitReceptor, N'''') IS NULL OR LEN(@NitReceptor) > 20
       OR NULLIF(@NombreReceptor, N'''') IS NULL OR LEN(@NombreReceptor) > 300
       OR NULLIF(@Divisa, '''') IS NULL OR LEN(@Divisa) > 10
       OR @Cantidad IS NULL OR @Cantidad < 1
       OR @LineExtension IS NULL OR @TaxExclusive IS NULL OR @TaxInclusive IS NULL
       OR @Payable IS NULL OR @Iva IS NULL OR @Inc IS NULL
       OR @Allowance IS NULL OR @Charge IS NULL
       OR @DescuentoHistorico IS NULL OR @RecargoHistorico IS NULL
       OR LEN(COALESCE(@PrimeraDescripcion, N'''')) > 2000
        THROW 50705, ''Cabecera XML fuera de contrato.'', 1;

    DECLARE @Lineas TABLE
    (
        [Ordinal] int NOT NULL PRIMARY KEY,
        [IdLinea] nvarchar(4000) NULL,
        [Descripcion] nvarchar(max) NULL,
        [CodigoEstandar] nvarchar(4000) NULL,
        [Cantidad] decimal(38,18) NULL,
        [Unidad] nvarchar(4000) NULL,
        [Precio] decimal(38,18) NULL,
        [ImporteLinea] decimal(38,18) NULL
    );
    INSERT INTO @Lineas
        ([Ordinal], [IdLinea], [Descripcion], [CodigoEstandar],
         [Cantidad], [Unidad], [Precio], [ImporteLinea])
    SELECT [ordinal], [lineId], [description], [standardCode],
           [quantity], [unitCode], [price], [lineAmount]
    FROM OPENJSON(@LineasJson) WITH
    (
        [ordinal] int ''$.ordinal'',
        [lineId] nvarchar(4000) ''$.lineId'',
        [description] nvarchar(max) ''$.description'',
        [standardCode] nvarchar(4000) ''$.standardCode'',
        [quantity] decimal(38,18) ''$.quantity'',
        [unitCode] nvarchar(4000) ''$.unitCode'
        + N''',
        [price] decimal(38,18) ''$.price'',
        [lineAmount] decimal(38,18) ''$.lineAmount''
    );
    IF (SELECT COUNT(*) FROM @Lineas) <> @Cantidad
       OR (SELECT MIN([Ordinal]) FROM @Lineas) <> 1
       OR (SELECT MAX([Ordinal]) FROM @Lineas) <> @Cantidad
       OR EXISTS
       (
           SELECT 1 FROM @Lineas
           WHERE NULLIF([IdLinea], N'''') IS NULL OR LEN([IdLinea]) > 100
              OR LEN(COALESCE([CodigoEstandar], N'''')) > 100
              OR LEN(COALESCE([Unidad], N'''')) > 20
              OR [Cantidad] IS NULL OR [Precio] IS NULL OR [ImporteLinea] IS NULL
       )
        THROW 50706, ''Lineas XML fuera de contrato.'', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @LockResult int;
        DECLARE @LockResource nvarchar(255) = CONCAT(N''dian:extraer-xml:'', @DocumentoXmlID);
        EXEC @LockResult = sys.sp_getapplock
            @Resource = @LockResource,
            @LockMode = ''Exclusive'', @LockOwner = ''Transaction'', @LockTimeout = 10000;
        IF @LockResult < 0 THROW 50707, ''No se pudo bloquear el XML.'', 1;

        DECLARE @DocumentoID bigint;
        DECLARE @ClaveSql char(96);
        DECLARE @Hash char(64);
        DECLARE @Estado varchar(30);
        DECLARE @Revision varchar(20);
        SELECT @DocumentoID = x.[DocumentoID], @Hash = x.[HashXmlSha256],
               @ClaveSql = d.[ClaveDocumento], @Estado = d.[EstadoProceso],
               @Revision = d.[EstadoRevision]
        FROM [dian].[DocumentoXml] AS x WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN [dian].[Documento] AS d WITH (UPDLOCK, HOLDLOCK)
            ON d.[DocumentoID] = x.[DocumentoID]
        WHERE x.[DocumentoXmlID] = @DocumentoXmlID AND x.[EsVigente] = 1;
        IF @DocumentoID IS NULL OR @ClaveSql <> CONVERT(char(96), @Clave)
            THROW 50708'
        + N', ''XML no vigente o CUFE discordante.'', 1;

        IF EXISTS (SELECT 1 FROM [dian].[XmlExtraccionError]
                   WHERE [DocumentoXmlID] = @DocumentoXmlID AND [VersionExtractor] = @Version)
            THROW 50710, ''El XML tiene un error de extraccion registrado.'', 1;

        IF EXISTS (SELECT 1 FROM [dian].[XmlExtraccion]
                   WHERE [DocumentoXmlID] = @DocumentoXmlID AND [VersionExtractor] = @Version)
        BEGIN
            COMMIT TRANSACTION;
            SELECT @DocumentoXmlID AS [DocumentoXmlID], ''EXISTENTE'' AS [Resultado];
            RETURN;
        END;
        INSERT INTO [dian].[XmlExtraccion]
            ([DocumentoXmlID], [VersionExtractor], [DocumentoID], [HashXmlSha256],
             [TipoXml], [ClaveDocumento], [NumeroDocumento], [FechaEmision],
             [NitEmisor], [NombreEmisor], [CiudadEmisor], [TaxLevelEmisor],
             [TaxSchemeIdEmisor], [TaxSchemeNombreEmisor], [CodigoIndustriaEmisor],
             [NitReceptor], [NombreReceptor], [Divisa],
             [CantidadLineas], [LineExtensionAmount], [TaxExclusiveAmount],
             [TaxInclusiveAmount], [PayableAmount], [IvaTotal], [IncTotal],
             [AllowanceTotal], [ChargeTotal], [DescuentoHistorico],
             [RecargoHistorico], [PrimeraDescripcion])
        VALUES
            (@DocumentoXmlID, @Version, @DocumentoID, @Hash, @Tipo, @Clave,
             @Numero, @Fecha, @NitEmisor, @NombreEmisor, @CiudadEmisor,
             @TaxLevelEmisor, @TaxSchemeIdEmisor, @TaxSchemeNombreEmisor,
             @CodigoIndustriaEmisor, @NitReceptor,
             @NombreReceptor, @Divisa, @Cantidad, @LineExtension, @TaxExclusive,
             @TaxInclusive, @Payable, @Iva, @Inc, @Allowance, @Charge,
             @DescuentoHistorico, @RecargoHistorico, @PrimeraDescripcion'
        + N');

        INSERT INTO [dian].[XmlLinea]
            ([DocumentoXmlID], [VersionExtractor], [Ordinal], [IdLinea],
             [Descripcion], [CodigoEstandar], [Cantidad], [Unidad], [Precio], [ImporteLinea])
        SELECT @DocumentoXmlID, @Version, [Ordinal], [IdLinea],
               [Descripcion], [CodigoEstandar], [Cantidad], [Unidad], [Precio], [ImporteLinea]
        FROM @Lineas;

        IF @Estado = ''XML_DESCARGADO'' AND @Revision <> ''PENDIENTE''
        BEGIN
            UPDATE [dian].[Documento]
            SET [EstadoProceso] = ''PROCESADO'', [FechaActualizacionUTC] = SYSUTCDATETIME()
            WHERE [DocumentoID] = @DocumentoID;
            INSERT INTO [dian].[DocumentoProcesoHistorial]
                ([DocumentoID], [CargaArchivoID], [EstadoAnterior], [EstadoNuevo],
                 [TipoEvento], [Origen], [Actor], [DetalleJson])
            SELECT @DocumentoID, d.[UltimaCargaID], ''XML_DESCARGADO'', ''PROCESADO'',
                   ''EXTRACCION_XML'', ''FUNCTION'', N''Azure Function'',
                   CONCAT(N''{"documentoXmlId":'', @DocumentoXmlID,
                          N'',"versionExtractor":'', @Version, N''}'')
            FROM [dian].[Documento] AS d WHERE d.[DocumentoID] = @DocumentoID;
        END;
        COMMIT TRANSACTION;
        SELECT @DocumentoXmlID AS [DocumentoXmlID], ''REGISTRADA'' AS [Resultado];
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;';
    EXEC sys.sp_executesql @Definicion;

    -- Fuente: sql/procedures/sp_RegistrarErrorExtraccionXml.sql
    SET @Definicion = CAST(N'CREATE OR ALTER PROCEDURE [dian].[sp_RegistrarErrorExtraccionXml]
    @DocumentoXmlID bigint,
    @VersionExtractor smallint,
    @Codigo varchar(60),
    @Detalle nvarchar(1000)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @DocumentoXmlID IS NULL OR @DocumentoXmlID <= 0 OR @VersionExtractor < 1
       OR NULLIF(@Codigo, '''') IS NULL OR NULLIF(@Detalle, N'''') IS NULL
       OR NOT EXISTS (SELECT 1 FROM [dian].[DocumentoXml]
                      WHERE [DocumentoXmlID] = @DocumentoXmlID)
        THROW 50709, ''Error de extraccion invalido.'', 1;
    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @LockResult int;
        DECLARE @LockResource nvarchar(255) = CONCAT(N''dian:extraer-xml:'', @DocumentoXmlID);
        EXEC @LockResult = sys.sp_getapplock
            @Resource = @LockResource, @LockMode = ''Exclusive'',
            @LockOwner = ''Transaction'', @LockTimeout = 10000;
        IF @LockResult < 0 THROW 50711, ''No se pudo bloquear el XML.'', 1;
        IF EXISTS (SELECT 1 FROM [dian].[XmlExtraccion]
                   WHERE [DocumentoXmlID] = @DocumentoXmlID AND [VersionExtractor] = @VersionExtractor)
        BEGIN
            COMMIT TRANSACTION;
            SELECT @DocumentoXmlID AS [DocumentoXmlID], ''YA_EXTRAIDO'' AS [Resultado];
            RETURN;
        END;
        IF NOT EXISTS
        (
            SELECT 1 FROM [dian].[XmlExtraccionError] WITH (UPDLOCK, HOLDLOCK)
            WHERE [DocumentoXmlID] = @DocumentoXmlID AND [VersionExtractor] = @VersionExtractor
        )
            INSERT INTO [dian].[XmlExtraccionError]
                ([DocumentoXmlID], [VersionExtractor], [Codigo], [Detalle])
            VALUES (@DocumentoXmlID, @VersionExtractor, @Codigo, @Detalle);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > ' AS nvarchar(max))
        + N'0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
    SELECT @DocumentoXmlID AS [DocumentoXmlID], ''ERROR_REGISTRADO'' AS [Resultado];
END;';
    EXEC sys.sp_executesql @Definicion;

    -- Fuente: sql/views/vw_FacturaXmlMlV1.sql
    SET @Definicion = CAST(N'CREATE OR ALTER VIEW [dian].[vw_FacturaXmlMlV1]
AS
SELECT
    CONCAT(N''dian:'', d.[PrimeraCargaID]) AS [id_carga],
    e.[NumeroDocumento] AS [id_factura],
    e.[ClaveDocumento] AS [cufe],
    e.[NumeroDocumento] AS [factura_completa],
    e.[FechaEmision] AS [fecha_emision],
    e.[NitEmisor] AS [nit_proveedor],
    e.[NombreEmisor] AS [nombre_proveedor],
    e.[CiudadEmisor] AS [ciudad_proveedor],
    e.[TaxLevelEmisor] AS [tax_level_proveedor],
    e.[TaxSchemeIdEmisor] AS [tax_scheme_id],
    e.[TaxSchemeNombreEmisor] AS [tax_scheme_nombre],
    e.[CodigoIndustriaEmisor] AS [codigo_industria_proveedor],
    e.[CantidadLineas] AS [cantidad_lineas_xml],
    e.[LineExtensionAmount] AS [line_extension_amount],
    e.[TaxExclusiveAmount] AS [tax_exclusive_amount],
    e.[TaxInclusiveAmount] AS [tax_inclusive_amount],
    e.[PayableAmount] AS [payable_amount],
    e.[IvaTotal] AS [iva_total],
    e.[IncTotal] AS [inc_total],
    e.[DescuentoHistorico] AS [descuento_total],
    e.[RecargoHistorico] AS [recargo_total],
    CONVERT(int, CASE WHEN e.[IvaTotal] > 0 THEN 1 ELSE 0 END) AS [tiene_iva],
    CONVERT(int, CASE WHEN e.[IncTotal] > 0 THEN 1 ELSE 0 END) AS [tiene_inc],
    CONVERT(int, CASE WHEN e.[DescuentoHistorico] > 0 THEN 1 ELSE 0 END) AS [flag_descuento],
    CONVERT(int, CASE WHEN e.[RecargoHistorico] > 0 THEN 1 ELSE 0 END) AS [flag_recargo],
    e.[CantidadLineas] AS [cantidad_items_total],
    e.[PrimeraDescripcion] AS [descripcion_item_1],
    CASE WHEN e.[PrimeraDescripcion] IS NULL THEN NULL
         ELSE CONCAT(e.[PrimeraDescripcion], N'' - '', e.[NombreEmisor]) END AS [item1_proveedor],
    2 + CASE WHEN e.[IvaTotal] > 0 THEN 1 ELSE 0 END
      + CASE WHEN e.[IncTotal] > 0 THEN 1 ELSE 0 END AS [n_registros_sugeridos],
    e.[TaxExclusiveAmount] AS [valor_ba' AS nvarchar(max))
        + N'se_sugerido],
    e.[IvaTotal] AS [valor_iva_sugerido],
    e.[IncTotal] AS [valor_inc_sugerido],
    e.[PayableAmount] AS [valor_cxp_sugerido],
    CAST(NULL AS nvarchar(1000)) AS [observaciones]
FROM [dian].[XmlExtraccion] AS e
JOIN [dian].[DocumentoXml] AS x ON x.[DocumentoXmlID] = e.[DocumentoXmlID]
JOIN [dian].[Documento] AS d ON d.[DocumentoID] = e.[DocumentoID]
WHERE e.[VersionExtractor] = 1 AND e.[TipoXml] = ''Invoice''
  AND x.[EsVigente] = 1 AND d.[EstadoProceso] = ''PROCESADO''
  AND d.[EstadoRevision] <> ''PENDIENTE'';';
    EXEC sys.sp_executesql @Definicion;

    -- Fuente: sql/security/dian_xml_extraction_grants.sql
    -- Ejecutar después de instalar los cuatro procedimientos de extracción.
    GRANT EXECUTE ON OBJECT::[dian].[sp_ObtenerXmlParaExtraccion] TO [dian_runtime];
    GRANT EXECUTE ON OBJECT::[dian].[sp_ListarXmlPendientesExtraccion] TO [dian_runtime];
    GRANT EXECUTE ON OBJECT::[dian].[sp_RegistrarExtraccionXml] TO [dian_runtime];
    GRANT EXECUTE ON OBJECT::[dian].[sp_RegistrarErrorExtraccionXml] TO [dian_runtime];

    IF OBJECT_ID(N'dian.XmlExtraccion', N'U') IS NULL
       OR OBJECT_ID(N'dian.XmlLinea', N'U') IS NULL
       OR OBJECT_ID(N'dian.XmlExtraccionError', N'U') IS NULL
       OR OBJECT_ID(N'dian.sp_ObtenerXmlParaExtraccion', N'P') IS NULL
       OR OBJECT_ID(N'dian.sp_ListarXmlPendientesExtraccion', N'P') IS NULL
       OR OBJECT_ID(N'dian.sp_RegistrarExtraccionXml', N'P') IS NULL
       OR OBJECT_ID(N'dian.sp_RegistrarErrorExtraccionXml', N'P') IS NULL
       OR OBJECT_ID(N'dian.vw_FacturaXmlMlV1', N'V') IS NULL
        THROW 50722, 'Faltan objetos de extraccion XML; se revierte todo.', 1;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;

SELECT DB_NAME() AS [BaseActual],
       (SELECT COUNT(*) FROM sys.tables WHERE [schema_id] = SCHEMA_ID(N'dian')
          AND [name] IN (N'XmlExtraccion', N'XmlLinea', N'XmlExtraccionError')) AS [TablasExtraccion],
       (SELECT COUNT(*) FROM sys.procedures WHERE [schema_id] = SCHEMA_ID(N'dian')
          AND [name] IN (N'sp_ObtenerXmlParaExtraccion', N'sp_ListarXmlPendientesExtraccion',
                         N'sp_RegistrarExtraccionXml', N'sp_RegistrarErrorExtraccionXml')) AS [ProcedimientosExtraccion],
       (SELECT COUNT(*) FROM sys.views WHERE [schema_id] = SCHEMA_ID(N'dian')
          AND [name] = N'vw_FacturaXmlMlV1') AS [VistasExtraccion];
