-- Misma proyeccion que dian.vw_FacturaXmlMlV1, con identidad tecnica del XML.
-- No concede acceso automaticamente: otorgar SELECT solo al ejecutor del dataset.
CREATE OR ALTER VIEW [ml].[vw_FacturaOrigenMlV1]
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
   AND CONCAT(N'dian:', d.[PrimeraCargaID]) = v.[id_carga]
JOIN [dian].[XmlExtraccion] AS e
    ON e.[DocumentoID] = d.[DocumentoID]
   AND e.[ClaveDocumento] = d.[ClaveDocumento]
   AND e.[VersionExtractor] = 1
   AND e.[TipoXml] = 'Invoice'
JOIN [dian].[DocumentoXml] AS x
    ON x.[DocumentoXmlID] = e.[DocumentoXmlID]
   AND x.[EsVigente] = 1;
