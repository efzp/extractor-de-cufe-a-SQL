-- Instalacion aditiva del dataset de entrenamiento ML v1 en Azure SQL.
-- Un solo envio, sin GO. No elimina objetos ni datos. No vuelve a instalar objetos existentes.
-- Generado por scripts/Generar-InstalacionDatasetEntrenamientoMl.py.
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'sqldb-dian-xml-cpabaas-dev'
    THROW 50830, 'Conectado a una base distinta de sqldb-dian-xml-cpabaas-dev.', 1;
IF OBJECT_ID(N'dian.Cliente', N'U') IS NULL
   OR OBJECT_ID(N'dian.XmlExtraccion', N'U') IS NULL
   OR OBJECT_ID(N'dian.vw_FacturaXmlMlV1', N'V') IS NULL
    THROW 50831, 'Faltan objetos base de DIAN; no se modifico nada.', 1;
IF OBJECT_ID(N'ml.DatasetVersion', N'U') IS NOT NULL
   OR OBJECT_ID(N'ml.DatasetFila', N'U') IS NOT NULL
   OR OBJECT_ID(N'ml.vw_FacturaOrigenMlV1', N'V') IS NOT NULL
   OR OBJECT_ID(N'ml.sp_PublicarDatasetEntrenamientoV1', N'P') IS NOT NULL
    THROW 50832, 'Ya existen objetos ML; no se modifico nada.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    -- Fuente: sql/migrations/005_ml_dataset.sql
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

    DECLARE @Definicion nvarchar(max);
    -- Fuente: sql/views/vw_FacturaOrigenMlV1.sql
    SET @Definicion = CAST(N'CREATE OR ALTER VIEW [ml].[vw_FacturaOrigenMlV1]
AS
SELECT
    d.[ClienteID],
    d.[DocumentoID],
    e.[DocumentoXmlID],
    e.[VersionExtractor],
    e.[HashXmlSha256],
    v.[id_carga],
    v.[id_factura],
    v.[cufe],
    v.[factura_completa],
    v.[fecha_emision],
    v.[nit_proveedor],
    v.[nombre_proveedor],
    v.[ciudad_proveedor],
    v.[tax_level_proveedor],
    v.[tax_scheme_id],
    v.[tax_scheme_nombre],
    v.[codigo_industria_proveedor],
    v.[cantidad_lineas_xml],
    v.[line_extension_amount],
    v.[tax_exclusive_amount],
    v.[tax_inclusive_amount],
    v.[payable_amount],
    v.[iva_total],
    v.[inc_total],
    v.[descuento_total],
    v.[recargo_total],
    v.[tiene_iva],
    v.[tiene_inc],
    v.[flag_descuento],
    v.[flag_recargo],
    v.[cantidad_items_total],
    v.[descripcion_item_1],
    v.[item1_proveedor],
    v.[n_registros_sugeridos],
    v.[valor_base_sugerido],
    v.[valor_iva_sugerido],
    v.[valor_inc_sugerido],
    v.[valor_cxp_sugerido],
    v.[observaciones]
FROM [dian].[vw_FacturaXmlMlV1] AS v
JOIN [dian].[Documento] AS d
    ON d.[ClaveDocumento] = v.[cufe]
   AND CONCAT(N''dian:'', d.[PrimeraCargaID]) = v.[id_carga]
JOIN [dian].[XmlExtraccion] AS e
    ON e.[DocumentoID] = d.[DocumentoID]
   AND e.[ClaveDocumento] = d.[ClaveDocumento]
   AND e.[VersionExtractor] = 1
   AND e.[TipoXml] = ''Invoice''
JOIN [dian].[DocumentoXml] AS x
    ON x.[DocumentoXmlID] = e.[DocumentoXmlID]
   AND x.[EsVigente] = 1;' AS nvarchar(max));
    EXEC sys.sp_executesql @Definicion;

    -- Fuente: sql/procedures/sp_PublicarDatasetEntrenamientoV1.sql
    SET @Definicion = CAST(N'CREATE OR ALTER PROCEDURE [ml].[sp_PublicarDatasetEntrenamientoV1]
    @ClienteID bigint,
    @FuenteContable nvarchar(100),
    @HashCodigoSha256 varchar(128),
    @HashFacturasSha256 varchar(128),
    @HashMovimientosSha256 varchar(128),
    @TotalFacturasOrigen int,
    @FilasJson nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Fuente nvarchar(100) = NULLIF(LTRIM(RTRIM(@FuenteContable)), N'''');
    DECLARE @HashCodigo varchar(128) = LOWER(NULLIF(LTRIM(RTRIM(@HashCodigoSha256)), ''''));
    DECLARE @HashFacturas varchar(128) = LOWER(NULLIF(LTRIM(RTRIM(@HashFacturasSha256)), ''''));
    DECLARE @HashMovimientos varchar(128) = LOWER(NULLIF(LTRIM(RTRIM(@HashMovimientosSha256)), ''''));
    DECLARE @HashFilas binary(32);
    DECLARE @Cantidad int;
    DECLARE @DatasetVersionID bigint;
    DECLARE @LockResult int;
    DECLARE @LockResource nvarchar(255);

    IF @ClienteID IS NULL OR @ClienteID <= 0
       OR NOT EXISTS (SELECT 1 FROM [dian].[Cliente] WHERE [ClienteID] = @ClienteID)
        THROW 50801, ''ClienteID no valido.'', 1;

    IF @Fuente IS NULL OR LEN(@Fuente) > 80
        THROW 50802, ''FuenteContable no valida.'', 1;

    IF @HashCodigo IS NULL OR LEN(@HashCodigo) <> 64
       OR @HashCodigo COLLATE Latin1_General_100_BIN2 LIKE ''%[^0-9a-f]%''
       OR @HashFacturas IS NULL OR LEN(@HashFacturas) <> 64
       OR @HashFacturas COLLATE Latin1_General_100_BIN2 LIKE ''%[^0-9a-f]%''
       OR @HashMovimientos IS NULL OR LEN(@HashMovimientos) <> 64
       OR @HashMovimientos COLLATE Latin1_General_100_BIN2 LIKE ''%[^0-9a-f]%''
        THROW 50803, ''Los hash de origen y codigo deben ser SHA-256 hexadecimales.'', 1;

    IF @TotalFacturasOrigen IS NULL OR @TotalFacturasOrigen <= 0
        THROW 50804, ''TotalFacturasOrigen debe ser positivo.'', 1;

    IF ' AS nvarchar(max))
        + N'@FilasJson IS NULL OR ISJSON(@FilasJson) <> 1
       OR LEFT(LTRIM(@FilasJson), 1) <> N''[''
       OR RIGHT(RTRIM(@FilasJson), 1) <> N'']''
        THROW 50805, ''FilasJson debe ser un arreglo JSON.'', 1;

    SET @HashFilas = HASHBYTES(''SHA2_256'', CONVERT(varbinary(max), @FilasJson));

    SELECT * INTO #Filas
    FROM OPENJSON(@FilasJson)
    WITH
    (
        [DocumentoXmlID] bigint ''$.documento_xml_id'',
        [VersionExtractor] smallint ''$.version_extractor'',
        [ClaveDocumento] nvarchar(max) ''$.cufe'',
        [EstadoMatch] nvarchar(max) ''$.estado_match'',
        [LlaveAsiento] nvarchar(max) ''$.llave_asiento'',
        [NitProveedorNorm] nvarchar(max) ''$.nit_proveedor_norm'',
        [CiudadProveedorModelo] nvarchar(max) ''$.ciudad_proveedor_modelo'',
        [TaxLevelProveedorLimpio] nvarchar(max) ''$.tax_level_proveedor_limpio'',
        [TaxSchemeIdLimpio] nvarchar(max) ''$.tax_scheme_id_limpio'',
        [TaxSchemeNombreLimpio] nvarchar(max) ''$.tax_scheme_nombre_limpio'',
        [CodigoIndustriaProveedorLimpio] nvarchar(max) ''$.codigo_industria_proveedor_limpio'',
        [FechaEmision] date ''$.fecha_emision'',
        [PayableAmount] decimal(38,18) ''$.payable_amount'',
        [DescuentoTotal] decimal(38,18) ''$.descuento_total'',
        [RecargoTotal] decimal(38,18) ''$.recargo_total'',
        [TieneIva] bit ''$.tiene_iva'',
        [TieneInc] bit ''$.tiene_inc'',
        [FlagDescuento] bit ''$.flag_descuento'',
        [FlagRecargo] bit ''$.flag_recargo'',
        [FlagUmbralRfServicios] bit ''$.flag_umbral_rf_servicios'',
        [FlagUmbralReteicaBogotaServicios] bit ''$.flag_umbral_reteica_bogota_servicios'',
        [FlagUmbralReteicaBogotaCompras] bit ''$.flag_umbral_reteica_bogota_compras'',
        [FlagDiferenciaPayableTaxInclusive] bit ''$.flag_diferencia_payable_tax_inclus'
        + N'ive'',
        [StandardItemIdentificationLimpio] nvarchar(max) ''$.standard_item_identification_limpio'',
        [TargetPlantillaCuentas] nvarchar(max) ''$.target_plantilla_cuentas''
    );

    SELECT @Cantidad = COUNT(*) FROM #Filas;

    IF @Cantidad = 0 OR @Cantidad > @TotalFacturasOrigen
        THROW 50806, ''El numero de filas no coincide con el universo declarado.'', 1;

    IF EXISTS
    (
        SELECT 1 FROM #Filas
        WHERE [DocumentoXmlID] IS NULL OR [DocumentoXmlID] <= 0
           OR [VersionExtractor] IS NULL OR [VersionExtractor] <> 1
           OR [ClaveDocumento] IS NULL OR LEN([ClaveDocumento]) <> 96
           OR [ClaveDocumento] COLLATE Latin1_General_100_BIN2 LIKE ''%[^0-9a-f]%''
           OR [EstadoMatch] IS NULL OR [EstadoMatch] NOT IN (N''OK_UNICO'', N''OK_TEXTO'', N''OK_VALOR'')
           OR NULLIF(LTRIM(RTRIM([LlaveAsiento])), N'''') IS NULL
           OR NULLIF(LTRIM(RTRIM([TargetPlantillaCuentas])), N'''') IS NULL
           OR [FechaEmision] IS NULL OR [PayableAmount] IS NULL
    )
        THROW 50807, ''Una o mas filas tienen identificadores, match, etiqueta o datos obligatorios invalidos.'', 1;

    IF EXISTS (SELECT 1 FROM #Filas GROUP BY [DocumentoXmlID] HAVING COUNT(*) > 1)
       OR EXISTS (SELECT 1 FROM #Filas GROUP BY CONVERT(char(96), [ClaveDocumento]) HAVING COUNT(*) > 1)
        THROW 50808, ''FilasJson contiene XML o CUFE repetidos.'', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        SET @LockResource = CONCAT(N''ml:dataset:'', @ClienteID, N'':'', @Fuente);

        EXEC @LockResult = sys.sp_getapplock
            @Resource = @LockResource,
            @LockMode = ''Exclusive'',
            @LockOwner = ''Transaction'',
            @LockTimeout = 10000;

        IF @LockResult < 0
            THROW 50809, ''No se pudo bloquear la publicacion del'
        + N' dataset.'', 1;

        SELECT @DatasetVersionID = [DatasetVersionID]
        FROM [ml].[DatasetVersion] WITH (UPDLOCK, HOLDLOCK)
        WHERE [ClienteID] = @ClienteID
          AND [FuenteContable] = CONVERT(nvarchar(80), @Fuente)
          AND [HashCodigoSha256] = CONVERT(char(64), @HashCodigo)
          AND [HashFacturasSha256] = CONVERT(char(64), @HashFacturas)
          AND [HashMovimientosSha256] = CONVERT(char(64), @HashMovimientos)
          AND [HashFilasSha256] = @HashFilas
          AND [TotalFacturasOrigen] = @TotalFacturasOrigen;

        IF @DatasetVersionID IS NOT NULL
        BEGIN
            COMMIT TRANSACTION;
            SELECT @DatasetVersionID AS [DatasetVersionID], @Cantidad AS [TotalFilas],
                   ''YA_EXISTE'' AS [Resultado];
            RETURN;
        END;

        IF EXISTS
        (
            SELECT 1
            FROM #Filas AS f
            LEFT JOIN [ml].[vw_FacturaOrigenMlV1] AS v
              ON v.[ClienteID] = @ClienteID
             AND v.[DocumentoXmlID] = f.[DocumentoXmlID]
             AND v.[VersionExtractor] = f.[VersionExtractor]
            WHERE v.[DocumentoXmlID] IS NULL
               OR v.[cufe] COLLATE Latin1_General_100_BIN2 <> f.[ClaveDocumento] COLLATE Latin1_General_100_BIN2
               OR v.[fecha_emision] <> f.[FechaEmision]
        )
            THROW 50810, ''Hay filas que ya no corresponden a una factura Invoice vigente y procesada.'', 1;

        INSERT INTO [ml].[DatasetVersion]
        (
            [ClienteID], [FuenteContable], [HashCodigoSha256],
            [HashFacturasSha256], [HashMovimientosSha256], [HashFilasSha256],
            [TotalFacturasOrigen], [TotalFilas]
        )
        VALUES
        (
            @ClienteID, CONVERT(nvarchar(80), @Fuente), CONVERT(char(64), @HashCodigo),
   '
        + N'         CONVERT(char(64), @HashFacturas), CONVERT(char(64), @HashMovimientos), @HashFilas,
            @TotalFacturasOrigen, @Cantidad
        );

        SET @DatasetVersionID = SCOPE_IDENTITY();

        INSERT INTO [ml].[DatasetFila]
        (
            [DatasetVersionID], [DocumentoXmlID], [VersionExtractor], [DocumentoID],
            [ClaveDocumento], [HashXmlSha256], [EstadoMatch], [LlaveAsiento],
            [NitProveedorNorm], [CiudadProveedorModelo], [TaxLevelProveedorLimpio],
            [TaxSchemeIdLimpio], [TaxSchemeNombreLimpio], [CodigoIndustriaProveedorLimpio],
            [FechaEmision], [PayableAmount], [DescuentoTotal], [RecargoTotal],
            [TieneIva], [TieneInc], [FlagDescuento], [FlagRecargo],
            [FlagUmbralRfServicios], [FlagUmbralReteicaBogotaServicios],
            [FlagUmbralReteicaBogotaCompras], [FlagDiferenciaPayableTaxInclusive],
            [StandardItemIdentificationLimpio], [TargetPlantillaCuentas]
        )
        SELECT
            @DatasetVersionID, f.[DocumentoXmlID], f.[VersionExtractor], v.[DocumentoID],
            CONVERT(char(96), f.[ClaveDocumento]), v.[HashXmlSha256],
            CONVERT(varchar(20), f.[EstadoMatch]), f.[LlaveAsiento],
            f.[NitProveedorNorm], f.[CiudadProveedorModelo], f.[TaxLevelProveedorLimpio],
            f.[TaxSchemeIdLimpio], f.[TaxSchemeNombreLimpio], f.[CodigoIndustriaProveedorLimpio],
            f.[FechaEmision], f.[PayableAmount], f.[DescuentoTotal], f.[RecargoTotal],
            f.[TieneIva], f.[TieneInc], f.[FlagDescuento], f.[FlagRecargo],
            f.[FlagUmbralRfServicios], f.[FlagUmbralReteicaBogotaServicios],
            f.[FlagUmbralReteicaBogotaCompras], f.[FlagDiferenciaPayableTaxInclusive],
            f.[StandardItemIdentificationLimpio], f.[TargetPlantilla'
        + N'Cuentas]
        FROM #Filas AS f
        JOIN [ml].[vw_FacturaOrigenMlV1] AS v
          ON v.[ClienteID] = @ClienteID
         AND v.[DocumentoXmlID] = f.[DocumentoXmlID]
         AND v.[VersionExtractor] = f.[VersionExtractor];

        IF @@ROWCOUNT <> @Cantidad
            THROW 50811, ''No se insertaron todas las filas; se revierte la version.'', 1;

        COMMIT TRANSACTION;

        SELECT @DatasetVersionID AS [DatasetVersionID], @Cantidad AS [TotalFilas],
               ''PUBLICADA'' AS [Resultado];
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;';
    EXEC sys.sp_executesql @Definicion;

    IF OBJECT_ID(N'ml.DatasetVersion', N'U') IS NULL
       OR OBJECT_ID(N'ml.DatasetFila', N'U') IS NULL
       OR OBJECT_ID(N'ml.vw_FacturaOrigenMlV1', N'V') IS NULL
       OR OBJECT_ID(N'ml.sp_PublicarDatasetEntrenamientoV1', N'P') IS NULL
        THROW 50833, 'Faltan objetos ML; se revierte la instalacion.', 1;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;

SELECT DB_NAME() AS [BaseActual],
       (SELECT COUNT(*) FROM sys.tables WHERE [schema_id] = SCHEMA_ID(N'ml')) AS [TablasMl],
       (SELECT COUNT(*) FROM sys.views WHERE [schema_id] = SCHEMA_ID(N'ml')) AS [VistasMl],
       (SELECT COUNT(*) FROM sys.procedures WHERE [schema_id] = SCHEMA_ID(N'ml')) AS [ProcedimientosMl];
