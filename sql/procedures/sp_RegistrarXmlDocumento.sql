SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE [dian].[sp_RegistrarXmlDocumento]
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

    DECLARE @Hash varchar(128) = LOWER(NULLIF(LTRIM(RTRIM(@HashXmlSha256)), ''));
    DECLARE @Uri nvarchar(1000) = NULLIF(LTRIM(RTRIM(@BlobUri)), N'');
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
        THROW 50501, 'Los identificadores deben ser positivos.', 1;

    IF @Hash IS NULL
       OR LEN(@Hash) <> 64
       OR @Hash COLLATE Latin1_General_100_BIN2 LIKE '%[^0-9a-f]%'
        THROW 50502, 'El SHA-256 no es valido.', 1;

    IF @TamanoBytes IS NULL OR @TamanoBytes <= 0
        THROW 50503, 'El XML debe tener contenido.', 1;

    IF @Uri IS NULL OR LEFT(@Uri, 8) <> N'https://'
       OR CHARINDEX(N'?', @Uri) > 0
        THROW 50504, 'La URI del Blob no es valida.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        SET @LockResource = CONCAT(N'dian:consulta-documento:', @DocumentoID);

        EXEC @LockResult = sys.sp_getapplock
            @Resource = @LockResource,
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult < 0
            THROW 50505, 'No se pudo bloquear el documento.', 1;

        SELECT
            @ClienteID = [ClienteID],
            @EstadoDocumento = [EstadoProceso]
        FROM [dian].[Documento] WITH (UPDLOCK, HOLDLOCK)
        WHERE [DocumentoID] = @DocumentoID;

        IF @ClienteID IS NULL
            THROW 50506, 'El documento no existe.', 1;

        SELECT
            @DocumentoConsultaID = [DocumentoID],
            @EstadoConsulta = [Estado]
        FROM [dian].[ConsultaDian] WITH (UPDLOCK, HOLDLOCK)
        WHERE [ConsultaDianID] = @ConsultaDianID;

        IF @DocumentoConsultaID IS NULL
           OR @DocumentoConsultaID <> @DocumentoID
            THROW 50507, 'La consulta no corresponde al documento.', 1;

        SET @RutaEsperada = CONCAT(
            N'/xml-dian/clientes/', @ClienteID,
            N'/documentos/', @DocumentoID,
            N'/', @Hash, N'.xml'
        );

        IF RIGHT(@Uri, LEN(@RutaEsperada)) <> @RutaEsperada
            THROW 50508, 'La ruta del Blob no es deterministica.', 1;

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
                THROW 50509, 'Ya existe un XML vigente diferente.', 1;

            SET @Resultado = 'XML_EXISTENTE';
        END
        ELSE
        BEGIN
            IF @EstadoConsulta <> 'INICIADA'
               OR @EstadoDocumento <> 'CONSULTANDO_DIAN'
                THROW 50510, 'La consulta ya no admite registrar XML.', 1;

            IF EXISTS
            (
                SELECT 1
                FROM [dian].[DocumentoXml]
                WHERE [DocumentoID] = @DocumentoID
                  AND [HashXmlSha256] = CONVERT(char(64), @Hash)
            )
                THROW 50511, 'El hash ya existe en un XML no vigente.', 1;

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
                N'application/xml', @TipoXmlDetectado, 1
            );

            SET @DocumentoXmlID = SCOPE_IDENTITY();
            SET @Resultado = 'XML_REGISTRADO';
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
END;
GO

GRANT EXECUTE ON OBJECT::[dian].[sp_RegistrarXmlDocumento] TO [dian_runtime];
GO
