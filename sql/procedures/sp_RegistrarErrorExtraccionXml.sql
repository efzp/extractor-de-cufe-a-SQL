CREATE OR ALTER PROCEDURE [dian].[sp_RegistrarErrorExtraccionXml]
    @DocumentoXmlID bigint,
    @VersionExtractor smallint,
    @Codigo varchar(60),
    @Detalle nvarchar(1000)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @DocumentoXmlID IS NULL OR @DocumentoXmlID <= 0 OR @VersionExtractor < 1
       OR NULLIF(@Codigo, '') IS NULL OR NULLIF(@Detalle, N'') IS NULL
       OR NOT EXISTS (SELECT 1 FROM [dian].[DocumentoXml]
                      WHERE [DocumentoXmlID] = @DocumentoXmlID)
        THROW 50709, 'Error de extraccion invalido.', 1;
    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @LockResult int;
        DECLARE @LockResource nvarchar(255) = CONCAT(N'dian:extraer-xml:', @DocumentoXmlID);
        EXEC @LockResult = sys.sp_getapplock
            @Resource = @LockResource, @LockMode = 'Exclusive',
            @LockOwner = 'Transaction', @LockTimeout = 10000;
        IF @LockResult < 0 THROW 50711, 'No se pudo bloquear el XML.', 1;
        IF EXISTS (SELECT 1 FROM [dian].[XmlExtraccion]
                   WHERE [DocumentoXmlID] = @DocumentoXmlID AND [VersionExtractor] = @VersionExtractor)
        BEGIN
            COMMIT TRANSACTION;
            SELECT @DocumentoXmlID AS [DocumentoXmlID], 'YA_EXTRAIDO' AS [Resultado];
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
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
    SELECT @DocumentoXmlID AS [DocumentoXmlID], 'ERROR_REGISTRADO' AS [Resultado];
END;
