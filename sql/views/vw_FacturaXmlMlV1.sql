-- Proyección de compatibilidad del Excel histórico: solo Invoice, una fila por XML vigente.
-- No concede SELECT al rol dian_runtime; otorgarlo únicamente al consumidor autorizado.
CREATE OR ALTER VIEW [dian].[vw_FacturaXmlMlV1]
AS
SELECT
    CONCAT(N'dian:', d.[PrimeraCargaID]) AS [id_carga],
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
         ELSE CONCAT(e.[PrimeraDescripcion], N' - ', e.[NombreEmisor]) END AS [item1_proveedor],
    2 + CASE WHEN e.[IvaTotal] > 0 THEN 1 ELSE 0 END
      + CASE WHEN e.[IncTotal] > 0 THEN 1 ELSE 0 END AS [n_registros_sugeridos],
    e.[TaxExclusiveAmount] AS [valor_base_sugerido],
    e.[IvaTotal] AS [valor_iva_sugerido],
    e.[IncTotal] AS [valor_inc_sugerido],
    e.[PayableAmount] AS [valor_cxp_sugerido],
    CAST(NULL AS nvarchar(1000)) AS [observaciones]
FROM [dian].[XmlExtraccion] AS e
JOIN [dian].[DocumentoXml] AS x ON x.[DocumentoXmlID] = e.[DocumentoXmlID]
JOIN [dian].[Documento] AS d ON d.[DocumentoID] = e.[DocumentoID]
WHERE e.[VersionExtractor] = 1 AND e.[TipoXml] = 'Invoice'
  AND x.[EsVigente] = 1 AND d.[EstadoProceso] = 'PROCESADO'
  AND d.[EstadoRevision] <> 'PENDIENTE';
