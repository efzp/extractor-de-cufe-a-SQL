-- Publica un snapshot completo calculado por el motor Python de matching.
-- @FilasJson: arreglo canonico ordenado por documento_xml_id, con una fila por
-- factura aceptada. Los hash de facturas, movimientos y codigo los calcula el
-- productor sobre entradas canonicas; SQL calcula el hash del JSON recibido.
CREATE OR ALTER PROCEDURE [ml].[sp_PublicarDatasetEntrenamientoV1]
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

    DECLARE @Fuente nvarchar(100) = NULLIF(LTRIM(RTRIM(@FuenteContable)), N'');
    DECLARE @HashCodigo varchar(128) = LOWER(NULLIF(LTRIM(RTRIM(@HashCodigoSha256)), ''));
    DECLARE @HashFacturas varchar(128) = LOWER(NULLIF(LTRIM(RTRIM(@HashFacturasSha256)), ''));
    DECLARE @HashMovimientos varchar(128) = LOWER(NULLIF(LTRIM(RTRIM(@HashMovimientosSha256)), ''));
    DECLARE @HashFilas binary(32);
    DECLARE @Cantidad int;
    DECLARE @DatasetVersionID bigint;
    DECLARE @LockResult int;
    DECLARE @LockResource nvarchar(255);

    IF @ClienteID IS NULL OR @ClienteID <= 0
       OR NOT EXISTS (SELECT 1 FROM [dian].[Cliente] WHERE [ClienteID] = @ClienteID)
        THROW 50801, 'ClienteID no valido.', 1;

    IF @Fuente IS NULL OR LEN(@Fuente) > 80
        THROW 50802, 'FuenteContable no valida.', 1;

    IF @HashCodigo IS NULL OR LEN(@HashCodigo) <> 64
       OR @HashCodigo COLLATE Latin1_General_100_BIN2 LIKE '%[^0-9a-f]%'
       OR @HashFacturas IS NULL OR LEN(@HashFacturas) <> 64
       OR @HashFacturas COLLATE Latin1_General_100_BIN2 LIKE '%[^0-9a-f]%'
       OR @HashMovimientos IS NULL OR LEN(@HashMovimientos) <> 64
       OR @HashMovimientos COLLATE Latin1_General_100_BIN2 LIKE '%[^0-9a-f]%'
        THROW 50803, 'Los hash de origen y codigo deben ser SHA-256 hexadecimales.', 1;

    IF @TotalFacturasOrigen IS NULL OR @TotalFacturasOrigen <= 0
        THROW 50804, 'TotalFacturasOrigen debe ser positivo.', 1;

    IF @FilasJson IS NULL OR ISJSON(@FilasJson) <> 1
       OR LEFT(LTRIM(@FilasJson), 1) <> N'['
       OR RIGHT(RTRIM(@FilasJson), 1) <> N']'
        THROW 50805, 'FilasJson debe ser un arreglo JSON.', 1;

    SET @HashFilas = HASHBYTES('SHA2_256', CONVERT(varbinary(max), @FilasJson));

    SELECT * INTO #Filas
    FROM OPENJSON(@FilasJson)
    WITH
    (
        [DocumentoXmlID] bigint '$.documento_xml_id',
        [VersionExtractor] smallint '$.version_extractor',
        [ClaveDocumento] nvarchar(max) '$.cufe',
        [EstadoMatch] nvarchar(max) '$.estado_match',
        [LlaveAsiento] nvarchar(max) '$.llave_asiento',
        [NitProveedorNorm] nvarchar(max) '$.nit_proveedor_norm',
        [CiudadProveedorModelo] nvarchar(max) '$.ciudad_proveedor_modelo',
        [TaxLevelProveedorLimpio] nvarchar(max) '$.tax_level_proveedor_limpio',
        [TaxSchemeIdLimpio] nvarchar(max) '$.tax_scheme_id_limpio',
        [TaxSchemeNombreLimpio] nvarchar(max) '$.tax_scheme_nombre_limpio',
        [CodigoIndustriaProveedorLimpio] nvarchar(max) '$.codigo_industria_proveedor_limpio',
        [FechaEmision] date '$.fecha_emision',
        [PayableAmount] decimal(38,18) '$.payable_amount',
        [DescuentoTotal] decimal(38,18) '$.descuento_total',
        [RecargoTotal] decimal(38,18) '$.recargo_total',
        [TieneIva] bit '$.tiene_iva',
        [TieneInc] bit '$.tiene_inc',
        [FlagDescuento] bit '$.flag_descuento',
        [FlagRecargo] bit '$.flag_recargo',
        [FlagUmbralRfServicios] bit '$.flag_umbral_rf_servicios',
        [FlagUmbralReteicaBogotaServicios] bit '$.flag_umbral_reteica_bogota_servicios',
        [FlagUmbralReteicaBogotaCompras] bit '$.flag_umbral_reteica_bogota_compras',
        [FlagDiferenciaPayableTaxInclusive] bit '$.flag_diferencia_payable_tax_inclusive',
        [StandardItemIdentificationLimpio] nvarchar(max) '$.standard_item_identification_limpio',
        [TargetPlantillaCuentas] nvarchar(max) '$.target_plantilla_cuentas'
    );

    SELECT @Cantidad = COUNT(*) FROM #Filas;

    IF @Cantidad = 0 OR @Cantidad > @TotalFacturasOrigen
        THROW 50806, 'El numero de filas no coincide con el universo declarado.', 1;

    IF EXISTS
    (
        SELECT 1 FROM #Filas
        WHERE [DocumentoXmlID] IS NULL OR [DocumentoXmlID] <= 0
           OR [VersionExtractor] IS NULL OR [VersionExtractor] <> 1
           OR [ClaveDocumento] IS NULL OR LEN([ClaveDocumento]) <> 96
           OR [ClaveDocumento] COLLATE Latin1_General_100_BIN2 LIKE '%[^0-9a-f]%'
           OR [EstadoMatch] IS NULL OR [EstadoMatch] NOT IN (N'OK_UNICO', N'OK_TEXTO', N'OK_VALOR')
           OR NULLIF(LTRIM(RTRIM([LlaveAsiento])), N'') IS NULL
           OR NULLIF(LTRIM(RTRIM([TargetPlantillaCuentas])), N'') IS NULL
           OR [FechaEmision] IS NULL OR [PayableAmount] IS NULL
    )
        THROW 50807, 'Una o mas filas tienen identificadores, match, etiqueta o datos obligatorios invalidos.', 1;

    IF EXISTS (SELECT 1 FROM #Filas GROUP BY [DocumentoXmlID] HAVING COUNT(*) > 1)
       OR EXISTS (SELECT 1 FROM #Filas GROUP BY CONVERT(char(96), [ClaveDocumento]) HAVING COUNT(*) > 1)
        THROW 50808, 'FilasJson contiene XML o CUFE repetidos.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        SET @LockResource = CONCAT(N'ml:dataset:', @ClienteID, N':', @Fuente);

        EXEC @LockResult = sys.sp_getapplock
            @Resource = @LockResource,
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult < 0
            THROW 50809, 'No se pudo bloquear la publicacion del dataset.', 1;

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
                   'YA_EXISTE' AS [Resultado];
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
            THROW 50810, 'Hay filas que ya no corresponden a una factura Invoice vigente y procesada.', 1;

        INSERT INTO [ml].[DatasetVersion]
        (
            [ClienteID], [FuenteContable], [HashCodigoSha256],
            [HashFacturasSha256], [HashMovimientosSha256], [HashFilasSha256],
            [TotalFacturasOrigen], [TotalFilas]
        )
        VALUES
        (
            @ClienteID, CONVERT(nvarchar(80), @Fuente), CONVERT(char(64), @HashCodigo),
            CONVERT(char(64), @HashFacturas), CONVERT(char(64), @HashMovimientos), @HashFilas,
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
            f.[StandardItemIdentificationLimpio], f.[TargetPlantillaCuentas]
        FROM #Filas AS f
        JOIN [ml].[vw_FacturaOrigenMlV1] AS v
          ON v.[ClienteID] = @ClienteID
         AND v.[DocumentoXmlID] = f.[DocumentoXmlID]
         AND v.[VersionExtractor] = f.[VersionExtractor];

        IF @@ROWCOUNT <> @Cantidad
            THROW 50811, 'No se insertaron todas las filas; se revierte la version.', 1;

        COMMIT TRANSACTION;

        SELECT @DatasetVersionID AS [DatasetVersionID], @Cantidad AS [TotalFilas],
               'PUBLICADA' AS [Resultado];
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
