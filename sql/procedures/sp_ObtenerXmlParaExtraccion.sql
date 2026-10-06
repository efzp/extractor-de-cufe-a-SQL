CREATE OR ALTER PROCEDURE [dian].[sp_ObtenerXmlParaExtraccion]
    @DocumentoXmlID bigint,
    @VersionExtractor smallint = 1
AS
BEGIN
    SET NOCOUNT ON;
    IF @DocumentoXmlID IS NULL OR @DocumentoXmlID <= 0 OR @VersionExtractor < 1
        THROW 50702, 'Identificadores de extraccion invalidos.', 1;
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
END;
