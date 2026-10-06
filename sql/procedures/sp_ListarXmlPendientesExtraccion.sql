CREATE OR ALTER PROCEDURE [dian].[sp_ListarXmlPendientesExtraccion]
    @Limite int = 100,
    @VersionExtractor smallint = 1
AS
BEGIN
    SET NOCOUNT ON;
    IF @Limite NOT BETWEEN 1 AND 1000 OR @VersionExtractor < 1
        THROW 50703, 'Limite o version de extraccion invalidos.', 1;
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
END;
