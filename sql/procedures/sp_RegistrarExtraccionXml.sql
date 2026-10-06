CREATE OR ALTER PROCEDURE [dian].[sp_RegistrarExtraccionXml]
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
        THROW 50704, 'Solicitud de extraccion invalida.', 1;

    DECLARE @Version smallint = TRY_CONVERT(smallint, JSON_VALUE(@CabeceraJson, '$.extractorVersion'));
    DECLARE @Tipo varchar(20) = JSON_VALUE(@CabeceraJson, '$.xmlType');
    DECLARE @Clave varchar(128) = LOWER(JSON_VALUE(@CabeceraJson, '$.uuid'));
    DECLARE @Numero nvarchar(4000) = JSON_VALUE(@CabeceraJson, '$.invoiceId');
    DECLARE @Fecha date = TRY_CONVERT(date, JSON_VALUE(@CabeceraJson, '$.issueDate'), 23);
    DECLARE @NitEmisor nvarchar(4000) = JSON_VALUE(@CabeceraJson, '$.supplierNit');
    DECLARE @NombreEmisor nvarchar(4000) = JSON_VALUE(@CabeceraJson, '$.supplierName');
    DECLARE @CiudadEmisor nvarchar(4000) = JSON_VALUE(@CabeceraJson, '$.supplierCity');
    DECLARE @TaxLevelEmisor nvarchar(4000) = JSON_VALUE(@CabeceraJson, '$.supplierTaxLevel');
    DECLARE @TaxSchemeIdEmisor nvarchar(4000) = JSON_VALUE(@CabeceraJson, '$.supplierTaxSchemeId');
    DECLARE @TaxSchemeNombreEmisor nvarchar(4000) = JSON_VALUE(@CabeceraJson, '$.supplierTaxSchemeName');
    DECLARE @CodigoIndustriaEmisor nvarchar(4000) = JSON_VALUE(@CabeceraJson, '$.supplierIndustryCode');
    DECLARE @NitReceptor nvarchar(4000) = JSON_VALUE(@CabeceraJson, '$.customerNit');
    DECLARE @NombreReceptor nvarchar(4000) = JSON_VALUE(@CabeceraJson, '$.customerName');
    DECLARE @Divisa varchar(4000) = JSON_VALUE(@CabeceraJson, '$.currency');
    DECLARE @Cantidad int = TRY_CONVERT(int, JSON_VALUE(@CabeceraJson, '$.lineCount'));
    DECLARE @LineExtension decimal(38,18) = TRY_CONVERT(decimal(38,18), JSON_VALUE(@CabeceraJson, '$.lineExtensionAmount'));
    DECLARE @TaxExclusive decimal(38,18) = TRY_CONVERT(decimal(38,18), JSON_VALUE(@CabeceraJson, '$.taxExclusiveAmount'));
    DECLARE @TaxInclusive decimal(38,18) = TRY_CONVERT(decimal(38,18), JSON_VALUE(@CabeceraJson, '$.taxInclusiveAmount'));
    DECLARE @Payable decimal(38,18) = TRY_CONVERT(decimal(38,18), JSON_VALUE(@CabeceraJson, '$.payableAmount'));
    DECLARE @Iva decimal(38,18) = TRY_CONVERT(decimal(38,18), JSON_VALUE(@CabeceraJson, '$.ivaTotal'));
    DECLARE @Inc decimal(38,18) = TRY_CONVERT(decimal(38,18), JSON_VALUE(@CabeceraJson, '$.incTotal'));
    DECLARE @Allowance decimal(38,18) = TRY_CONVERT(decimal(38,18), JSON_VALUE(@CabeceraJson, '$.allowanceTotal'));
    DECLARE @Charge decimal(38,18) = TRY_CONVERT(decimal(38,18), JSON_VALUE(@CabeceraJson, '$.chargeTotal'));
    DECLARE @DescuentoHistorico decimal(38,18) = TRY_CONVERT(decimal(38,18), JSON_VALUE(@CabeceraJson, '$.legacyDiscount'));
    DECLARE @RecargoHistorico decimal(38,18) = TRY_CONVERT(decimal(38,18), JSON_VALUE(@CabeceraJson, '$.legacyCharge'));
    DECLARE @PrimeraDescripcion nvarchar(4000) = JSON_VALUE(@CabeceraJson, '$.firstDescription');

    IF @Version IS NULL OR @Version < 1 OR @Tipo IS NULL OR @Tipo NOT IN ('Invoice', 'CreditNote')
       OR @Clave IS NULL OR LEN(@Clave) <> 96
       OR @Clave COLLATE Latin1_General_100_BIN2 LIKE '%[^0-9a-f]%'
       OR NULLIF(@Numero, N'') IS NULL OR LEN(@Numero) > 100 OR @Fecha IS NULL
       OR NULLIF(@NitEmisor, N'') IS NULL OR LEN(@NitEmisor) > 20
       OR NULLIF(@NombreEmisor, N'') IS NULL OR LEN(@NombreEmisor) > 300
       OR LEN(COALESCE(@CiudadEmisor, N'')) > 200
       OR LEN(COALESCE(@TaxLevelEmisor, N'')) > 100
       OR LEN(COALESCE(@TaxSchemeIdEmisor, N'')) > 100
       OR LEN(COALESCE(@TaxSchemeNombreEmisor, N'')) > 200
       OR LEN(COALESCE(@CodigoIndustriaEmisor, N'')) > 100
       OR NULLIF(@NitReceptor, N'') IS NULL OR LEN(@NitReceptor) > 20
       OR NULLIF(@NombreReceptor, N'') IS NULL OR LEN(@NombreReceptor) > 300
       OR NULLIF(@Divisa, '') IS NULL OR LEN(@Divisa) > 10
       OR @Cantidad IS NULL OR @Cantidad < 1
       OR @LineExtension IS NULL OR @TaxExclusive IS NULL OR @TaxInclusive IS NULL
       OR @Payable IS NULL OR @Iva IS NULL OR @Inc IS NULL
       OR @Allowance IS NULL OR @Charge IS NULL
       OR @DescuentoHistorico IS NULL OR @RecargoHistorico IS NULL
       OR LEN(COALESCE(@PrimeraDescripcion, N'')) > 2000
        THROW 50705, 'Cabecera XML fuera de contrato.', 1;

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
        [ordinal] int '$.ordinal',
        [lineId] nvarchar(4000) '$.lineId',
        [description] nvarchar(max) '$.description',
        [standardCode] nvarchar(4000) '$.standardCode',
        [quantity] decimal(38,18) '$.quantity',
        [unitCode] nvarchar(4000) '$.unitCode',
        [price] decimal(38,18) '$.price',
        [lineAmount] decimal(38,18) '$.lineAmount'
    );
    IF (SELECT COUNT(*) FROM @Lineas) <> @Cantidad
       OR (SELECT MIN([Ordinal]) FROM @Lineas) <> 1
       OR (SELECT MAX([Ordinal]) FROM @Lineas) <> @Cantidad
       OR EXISTS
       (
           SELECT 1 FROM @Lineas
           WHERE NULLIF([IdLinea], N'') IS NULL OR LEN([IdLinea]) > 100
              OR LEN(COALESCE([CodigoEstandar], N'')) > 100
              OR LEN(COALESCE([Unidad], N'')) > 20
              OR [Cantidad] IS NULL OR [Precio] IS NULL OR [ImporteLinea] IS NULL
       )
        THROW 50706, 'Lineas XML fuera de contrato.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @LockResult int;
        DECLARE @LockResource nvarchar(255) = CONCAT(N'dian:extraer-xml:', @DocumentoXmlID);
        EXEC @LockResult = sys.sp_getapplock
            @Resource = @LockResource,
            @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 10000;
        IF @LockResult < 0 THROW 50707, 'No se pudo bloquear el XML.', 1;

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
            THROW 50708, 'XML no vigente o CUFE discordante.', 1;

        IF EXISTS (SELECT 1 FROM [dian].[XmlExtraccionError]
                   WHERE [DocumentoXmlID] = @DocumentoXmlID AND [VersionExtractor] = @Version)
            THROW 50710, 'El XML tiene un error de extraccion registrado.', 1;

        IF EXISTS (SELECT 1 FROM [dian].[XmlExtraccion]
                   WHERE [DocumentoXmlID] = @DocumentoXmlID AND [VersionExtractor] = @Version)
        BEGIN
            COMMIT TRANSACTION;
            SELECT @DocumentoXmlID AS [DocumentoXmlID], 'EXISTENTE' AS [Resultado];
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
             @DescuentoHistorico, @RecargoHistorico, @PrimeraDescripcion);

        INSERT INTO [dian].[XmlLinea]
            ([DocumentoXmlID], [VersionExtractor], [Ordinal], [IdLinea],
             [Descripcion], [CodigoEstandar], [Cantidad], [Unidad], [Precio], [ImporteLinea])
        SELECT @DocumentoXmlID, @Version, [Ordinal], [IdLinea],
               [Descripcion], [CodigoEstandar], [Cantidad], [Unidad], [Precio], [ImporteLinea]
        FROM @Lineas;

        IF @Estado = 'XML_DESCARGADO' AND @Revision <> 'PENDIENTE'
        BEGIN
            UPDATE [dian].[Documento]
            SET [EstadoProceso] = 'PROCESADO', [FechaActualizacionUTC] = SYSUTCDATETIME()
            WHERE [DocumentoID] = @DocumentoID;
            INSERT INTO [dian].[DocumentoProcesoHistorial]
                ([DocumentoID], [CargaArchivoID], [EstadoAnterior], [EstadoNuevo],
                 [TipoEvento], [Origen], [Actor], [DetalleJson])
            SELECT @DocumentoID, d.[UltimaCargaID], 'XML_DESCARGADO', 'PROCESADO',
                   'EXTRACCION_XML', 'FUNCTION', N'Azure Function',
                   CONCAT(N'{"documentoXmlId":', @DocumentoXmlID,
                          N',"versionExtractor":', @Version, N'}')
            FROM [dian].[Documento] AS d WHERE d.[DocumentoID] = @DocumentoID;
        END;
        COMMIT TRANSACTION;
        SELECT @DocumentoXmlID AS [DocumentoXmlID], 'REGISTRADA' AS [Resultado];
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
