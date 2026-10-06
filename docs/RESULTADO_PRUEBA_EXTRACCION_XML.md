# Resultado de la prueba de extracción XML

Prueba local y de solo lectura de los 34 XML adicionales indicados para el contrato DIAN. Se usó `base datos factura.xlsx` como referencia histórica y `scripts/Probar-ExtraccionXmlHistorica.ps1` como extractor y comparador. No se consultó Blob Storage ni se modificó Azure SQL, los XML o el Excel.

## Resultado

| Medida | Resultado |
| --- | ---: |
| XML `Invoice` extraídos | 34 |
| XML con fila histórica por CUFE | 32 |
| XML sin fila histórica | 2 |
| Filas Excel comparadas | 32 |
| Campos comparables por fila | 33 de 34 |
| Comparaciones de campo | 1.056 |
| Líneas de producto extraídas | 100 |
| Diferencias literales | 37 |
| Diferencias explicadas por representación | 37 |
| Diferencias de contenido no explicadas | 0 |

Los 34 XML se pudieron leer con DTD, entidades externas y red deshabilitados. En los 34, el nombre de archivo coincide con el CUFE y `LineCountNumeric` coincide con el número de nodos `InvoiceLine`. Se obtuvieron 100 líneas tabulares, cada una con ordinal, ID de línea, descripción, código estándar, cantidad, unidad, precio e importe; ninguna carece de descripción ni código estándar.

`id_carga` no entra en la comparación: en el Excel es el timestamp de una ejecución anterior de Power Automate y no se encuentra en el XML. La proyección local lo deja nulo. En producción se completaría con el identificador de carga persistido en SQL, claramente diferenciado del valor histórico.

## Diferencias literales encontradas

| Campo | Casos | Explicación y tratamiento |
| --- | ---: | --- |
| `tax_scheme_id` | 29 | El XML conserva el código textual `01`; Excel guardó `1` por conversión numérica. El extractor debe conservar `01` como dato canónico. La preparación del modelo debe normalizar ambas representaciones de forma idéntica antes de usar el campo como categoría. |
| `iva_total` | 4 | Excel contiene residuos de coma flotante, por ejemplo `4776.6000000000004` frente al decimal XML `4776.60`. La diferencia es mucho menor que un centavo; el contrato usa decimales exactos. |
| `valor_iva_sugerido` | 4 | Repite la misma diferencia de representación de `iva_total`; no son cuatro documentos adicionales. |

La comparación de texto elimina espacios de borde. Esto evita confundir con una diferencia fiscal el espacio inicial que el flujo antiguo añadía a `tax_level_proveedor` al escribir en Excel. La clasificación de las 37 diferencias no significa que `01` y `1` sean intercambiables para un modelo categórico sin normalización explícita.

Los dos XML sin fila en el Excel son `1b78a1a...` (factura `FMD64919`, seis líneas) y `5bc7024...` (factura `FE3846`, una línea). Se extrajeron correctamente; su ausencia del libro no se trata como un error del XML.

Como ejemplo, `0ffbe66f...` produjo `id_factura=K1D812230`, `fecha_emision=2025-10-29`, `nit_proveedor=900276962`, `cantidad_lineas_xml=29`, `iva_total=49681.37`, `payable_amount=351749.98` y `descripcion_item_1=DETERGENTE MULTIUSOS`. Esos valores coinciden con la fila 133 del libro; el único contraste literal en esa fila es `tax_scheme_id` (`01` frente a `1`).

Al reconciliar `LineExtensionAmount` de cabecera con la suma de importes de línea, 30 XML coinciden exactamente y 4 difieren: `1b78a1a...` por −0.0030 COP, `2a38107...` por +0.36 COP, `4eba1e6...` por −0.32 COP y `4fbca57...` por +0.40 COP (suma de líneas menos cabecera). El extractor conserva ambos valores declarados y reporta la diferencia; no ajusta ningún importe. Esas diferencias pequeñas pueden deberse a reglas de redondeo, pero no se presupone esa causa sin revisar el detalle fiscal.

Fuera de los 34 XML de esta prueba se comprobó el caso `85c9634f...`, fila 186 del libro: el UBL contiene `AllowanceTotalAmount=44.00` y `ChargeTotalAmount=26300.00`, mientras el Excel histórico tiene descuento y recargo en cero. La extracción canónica y la proyección para el modelo antiguo deben mantenerse separadas, tal como indica el contrato.

## Qué queda sin probar

Esta corrida verifica la extracción local de los 34 `Invoice` y su comparación semántica con el Excel. No verifica lectura del Blob, credenciales, metadatos SQL, vínculo con `DocumentoVersionID`, validación XSD, firma digital ni la proyección de las cinco `CreditNote` presentes en el conjunto histórico. Esas pruebas corresponden a la implementación posterior.

Para repetirla, ejecutar `scripts/Probar-ExtraccionXmlHistorica.ps1` con `-XmlDirectory` apuntando a la carpeta `XML definitivos` y `-WorkbookPath` apuntando a `base datos factura.xlsx`. La salida incluye las 34 filas proyectadas, el resumen por campo y el detalle de diferencias; no escribe archivos.
