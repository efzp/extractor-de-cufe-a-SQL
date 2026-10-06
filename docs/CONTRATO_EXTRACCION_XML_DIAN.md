# Contrato de extracción XML DIAN v1

Estado: extractor v1 implementado en código y scripts SQL; pendiente de despliegue y prueba integrada en Azure.

## Objetivo y alcance

Convertir cada XML guardado en `xml-dian` en un registro de documento y sus líneas, sin perder el XML original. Ofrecer, por separado, una proyección con las 34 columnas de `base datos factura.xlsx` para probar el modelo contable anterior. El XML es la fuente de los datos fiscales; la predicción y `target_plantilla_cuentas` provienen de la etapa contable, no del XML.

La extracción canónica admite `Invoice` y `CreditNote` UBL 2.x; conserva `tipo_documento` y los importes tal como aparecen, sin invertir automáticamente el signo de una nota crédito. La proyección histórica v1 emite **solo `Invoice`**, porque el flujo anterior solo procesaba `Invoice`. Otros tipos, incluido `ApplicationResponse`, quedan fuera de este contrato y se registran como no compatibles, sin fingir una factura.

## Evidencia de los archivos suministrados

- Se pudieron leer estructuralmente los 276 XML de `XML definitivos`: 271 `Invoice` y 5 `CreditNote`. Todos tienen `UUID`, `ID`, fecha, proveedor, al menos una línea y totales; los 276 nombres de archivo coinciden con su `UUID`, y `LineCountNumeric` coincide con el número real de líneas. Los 276 importes `PayableAmount` declaran `COP`.
- Los 34 XML adicionales indicados en esta conversación existen y son `Invoice`. Tienen entre 1 y 29 líneas; en los 34 coincide el conteo declarado con el real. 32 de esos 34 CUFE aparecen en `base datos factura.xlsx`; `1b78a...` y `5bc702...` no aparecen allí.
- `base datos factura.xlsx` tiene 270 filas con datos y 247 CUFE distintos. Las 270 filas se enlazan por CUFE a los XML, pero 23 son repeticiones de CUFE: el Excel no debe usarse como clave única. Quedan 29 XML sin fila en el libro: 24 `Invoice` y las 5 `CreditNote`. `facturas_a_predecir.xlsx` contiene los mismos 34 encabezados, pero sus filas visibles de muestra están vacías.
- En las 270 filas enlazadas coincidieron con el XML, sin diferencias, `id_factura`, NIT proveedor, número de líneas, cuatro importes de cabecera, IVA, INC y primera descripción. Se compararon números como números, no como cadenas. Esto valida esa correspondencia concreta, **no** una validación XSD, de firma digital o de todas las columnas históricas.
- El flujo histórico obtenía `descuento_total` y `recargo_total` de `MntDctoCop` y `MntRcgoCop`, con cero si faltaban. En estos XML, ambos nodos aparecen solo en 24 archivos y nunca con valor distinto de cero. Sin embargo, los totales UBL estándar muestran 2 documentos con descuento no nulo y 19 con cargo no nulo. Por ejemplo, el XML `85c9634f...` tiene `AllowanceTotalAmount=44.00` y `ChargeTotalAmount=26300.00`; la salida histórica habría puesto ambos en cero. **No se deben equiparar esas dos interpretaciones.**

## Lectura, identidad y persistencia lógica

1. La unidad de trabajo es `DocumentoXmlID` de `dian.DocumentoXml`, no una URL enviada por Power Automate. Se selecciona únicamente un XML vigente, registrado y todavía no extraído. La cola lleva el ID y una versión de mensaje, nunca bytes del XML ni un SAS.
2. A partir de `DocumentoXml`, `Documento` y `ClienteID`, se deriva la ruta esperada `xml-dian/clientes/{ClienteID}/documentos/{DocumentoID}/{HashXmlSha256}.xml`; la `BlobUri` registrada debe coincidir con la cuenta y esa ruta. La Function lee el Blob con identidad administrada y acceso privado.
3. Antes de parsear, se comprueban límite de tamaño, `TamanoBytes` y SHA-256 exacto de los bytes descargados. El parser deshabilita DTD, entidades externas y acceso a red. Se conserva el XML intacto.
4. Registro lógico de cabecera: clave `(DocumentoXmlID, version_extractor)`, `DocumentoID`, tipo UBL, CUFE/CUDE, ID, fecha, emisor/receptor, divisa, importes, impuestos, `HashXmlSha256`, fecha de extracción y resultado de validación. Registro lógico de líneas: `(DocumentoXmlID, version_extractor, ordinal_linea)` más ID de línea UBL, descripción, código estándar, cantidad, unidad, precio e importe de línea. El ordinal conserva el orden físico del XML; nunca se aplastan varias líneas en una sola celda.
5. La proyección histórica genera **una fila por `Invoice` y CUFE**, no una fila por cada carga o línea. Los duplicados del Excel se emplean solo para cotejo. Reprocesar el mismo `DocumentoXmlID` con la misma versión del extractor no duplica datos; una versión nueva deja trazabilidad de la anterior.
6. El mensaje de cola actual sí contiene `documentoVersionId`, pero `DocumentoXml` y `ConsultaDian` no lo conservan. Antes de afirmar que un XML corresponde a una revisión concreta debe persistirse ese vínculo en la implementación futura. Para XML ya almacenados, solo se asignará una versión si la correspondencia es inequívoca; en caso contrario queda `VERSION_AMBIGUA`, sin escoger automáticamente la revisión vigente.

## Rutas XML y tipos

Se usan los espacios de nombres UBL, no coincidencias globales por nombre local: `cbc=urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2` y `cac=urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2`. En la tabla, `R` es la raíz `Invoice` o `CreditNote`, `P=R/cac:AccountingSupplierParty/cac:Party`, `T=R/cac:LegalMonetaryTotal` para ambos tipos observados, y `L=R/cac:InvoiceLine` o `R/cac:CreditNoteLine`. Las rutas con `[1]` son el primer nodo en orden documental. Texto: Unicode normalizado solo para espacios de borde; números: `decimal(19,4)` sin conversión a `float`; identificadores: texto.

| Campo histórico | Fuente o regla de la proyección `Invoice` v1 |
| --- | --- |
| `id_carga` | `dian:` + `Documento.PrimeraCargaID`, como texto. El antiguo timestamp de ejecución no se puede reconstruir del XML ni es equivalente. |
| `id_factura` | `R/cbc:ID`, texto. |
| `cufe` | `R/cbc:UUID`, minúsculas, 96 hexadecimales. |
| `factura_completa` | Copia de `id_factura`, igual que el flujo antiguo; **no** es el XML completo. |
| `fecha_emision` | `R/cbc:IssueDate`, fecha ISO; en Excel se exporta como fecha, no como serial textual. |
| `nit_proveedor` | `P/cac:PartyTaxScheme/cbc:CompanyID`, conservar como texto. |
| `nombre_proveedor` | `P/cac:PartyTaxScheme/cbc:RegistrationName`; si falta, `P/cac:PartyName/cbc:Name`. |
| `ciudad_proveedor` | `P/cac:PhysicalLocation/cac:Address/cbc:CityName`; si falta, `P/cac:PartyTaxScheme/cac:RegistrationAddress/cbc:CityName`. |
| `tax_level_proveedor` | `P/cac:PartyTaxScheme/cbc:TaxLevelCode`. Se elimina el espacio inicial accidental que añadía el conector Excel; la normalización del modelo ya limpia este campo. |
| `tax_scheme_id` | `P/cac:PartyTaxScheme/cac:TaxScheme/cbc:ID`, texto canónico. El Excel antiguo convirtió `01` en `1` en numerosos casos; antes de usarlo como categoría ML se debe aplicar la misma normalización a entrenamiento e inferencia. |
| `tax_scheme_nombre` | `P/cac:PartyTaxScheme/cac:TaxScheme/cbc:Name`. |
| `codigo_industria_proveedor` | `P/cbc:IndustryClassificationCode`; nulo si no existe, nunca cero inventado. |
| `cantidad_lineas_xml` | `R/cbc:LineCountNumeric` como entero; validar contra `count(L)`. |
| `line_extension_amount` | `T/cbc:LineExtensionAmount`. |
| `tax_exclusive_amount` | `T/cbc:TaxExclusiveAmount`. |
| `tax_inclusive_amount` | `T/cbc:TaxInclusiveAmount`. |
| `payable_amount` | `T/cbc:PayableAmount`. |
| `iva_total` | Suma de `R/cac:TaxTotal/cac:TaxSubtotal/cbc:TaxAmount` **solo** cuando su `cac:TaxCategory/cac:TaxScheme/cbc:ID` es `01`; no sumar impuestos de líneas otra vez. Cero si no hay subtotal `01`. |
| `inc_total` | Igual, con ID de esquema tributario `04`. |
| `descuento_total` | **Compatibilidad histórica:** primer `MntDctoCop` de extensiones; cero si falta. El descuento canónico se guarda aparte desde `T/cbc:AllowanceTotalAmount` y se coteja con `R/cac:AllowanceCharge[cbc:ChargeIndicator='false']`. |
| `recargo_total` | **Compatibilidad histórica:** primer `MntRcgoCop` de extensiones; cero si falta. El cargo canónico se guarda aparte desde `T/cbc:ChargeTotalAmount` y se coteja con `R/cac:AllowanceCharge[cbc:ChargeIndicator='true']`. |
| `tiene_iva` | `1` si `iva_total > 0`; en otro caso `0`. |
| `tiene_inc` | `1` si `inc_total > 0`; en otro caso `0`. |
| `flag_descuento` | `1` si el `descuento_total` **histórico** es positivo; en otro caso `0`. No sustituir por el descuento UBL sin reentrenar el modelo. |
| `flag_recargo` | `1` si el `recargo_total` **histórico** es positivo; en otro caso `0`. |
| `cantidad_items_total` | Número real de nodos `L`. |
| `descripcion_item_1` | `L[1]/cac:Item/cbc:Description[1]`. El dato canónico de línea guarda también `Name` como respaldo, pero este campo replica la primera descripción del flujo viejo. |
| `item1_proveedor` | `descripcion_item_1 + ' - ' + nombre_proveedor`. |
| `n_registros_sugeridos` | `2 + tiene_iva + tiene_inc`; sugerencia histórica, no número real de asientos. |
| `valor_base_sugerido` | Copia de `tax_exclusive_amount`. |
| `valor_iva_sugerido` | Copia de `iva_total`. |
| `valor_inc_sugerido` | Copia de `inc_total`. |
| `valor_cxp_sugerido` | Copia de `payable_amount`. |
| `observaciones` | Nulo/vacío, como en la salida histórica. Los errores de validación van en campos de auditoría separados. |

La tabla de líneas canónica toma `L/cbc:ID`, `L/cac:Item/cbc:Description` (o `cbc:Name` si falta), `L/cac:Item/cac:StandardItemIdentification/cbc:ID`, `L/cbc:InvoicedQuantity` o `L/cbc:CreditedQuantity`, `L/cbc:LineExtensionAmount` y `L/cac:Price/cbc:PriceAmount`. Se conserva cada descripción y código de línea. Para la variable ML histórica `standard_item_identification_limpio` se debe reproducir, en una **etapa de preparación de modelo versionada**, la concatenación de códigos únicos y orden natural de `funciones_de_limpieza_base_datos_factura.py`; `descripciones_lineas_limpia` depende además de la frecuencia de tokens del conjunto, por lo que no es una propiedad estable de un XML aislado.

## Validaciones y tratamiento de diferencias

| Control | Resultado exigido |
| --- | --- |
| Blob | Cuenta, contenedor y ruta esperados; tamaño y SHA-256 iguales a `DocumentoXml`. |
| XML | Bien formado, sin DTD/entidades externas, raíz y namespace reconocidos. La lectura estructural de muestras no reemplaza validación XSD, de certificado ni de firma. |
| Identidad | `UUID` igual a `Documento.ClaveDocumento` normalizado y tipo CUFE/CUDE coherente; `ID`, `IssueDate`, NIT y al menos una línea presentes. |
| Líneas | `LineCountNumeric = count(L)`; si falla, no publicar la proyección ML. |
| Importes | Divisa registrada por importe, números decimales válidos; conservar los importes declarados sin imponer `payable = tax_exclusive + IVA`, pues esa igualdad no es universal en las muestras. Diferencias de totales UBL frente a `DocumentoVersion` se registran para revisión, no se corrigen en silencio. |
| Revisión | Comparar con `DocumentoVersion` solo cuando su vínculo sea inequívoco. Una revisión pendiente no debe hacer que se compare contra la versión equivocada. |
| Publicación | Una extracción inválida conserva el XML y su historial; no se publica como fila compatible ni se declara `PROCESADO`. El error tiene código, detalle acotado y posibilidad de reintento sin consultar de nuevo a la DIAN. |

Ejemplo comprobado: el XML `0ffbe66f...` y la fila 133 de `base datos factura.xlsx` corresponden al CUFE `0ffbe66f...`, factura `K1D812230`, NIT `900276962`, 29 líneas, `payable_amount=351749.98`, `iva_total=49681.37` y primera descripción `DETERGENTE MULTIUSOS`. `tax_exclusive_amount=299368.61` y `line_extension_amount=302068.61` son campos distintos; el contrato preserva ambos.

## Criterios de aceptación antes de implementar

1. Reproducir las diez comparaciones ya verificadas para las 270 filas históricas; extender el cotejo campo a campo a las 34 columnas, documentando diferencias legítimas como `id_carga`, el espacio de `tax_level_proveedor`, los ceros iniciales perdidos por Excel y sus residuos de coma flotante. La prueba local de los 34 XML adicionales está en `docs/RESULTADO_PRUEBA_EXTRACCION_XML.md`.
2. Probar los 34 XML adicionales: 34 lecturas correctas, 34 conteos de líneas correctos, 32 CUFE enlazados al libro y dos sin fila histórica, sin tomarlos por error de extracción.
3. Probar las cinco `CreditNote` como registros canónicos sin emitir filas `Invoice` de compatibilidad.
4. Probar explícitamente los casos de cargos/descuentos UBL no nulos: la proyección histórica mantiene la semántica vieja, mientras los valores canónicos conservan el valor real del UBL y una marca de discrepancia semántica.
5. Probar idempotencia, hash/tamaño incorrecto, ruta Blob incorrecta, XML malformado, líneas declaradas discordantes y versión documental ambigua.

Fuentes revisadas: `base datos factura.xlsx`, `facturas_a_predecir.xlsx`, los XML de `XML definitivos`, el `definition.json` del flujo antiguo, `funciones_de_limpieza_base_datos_factura.py`, `procesamiento_facturas_contabilidad_match.py`, `dian_ingestion/document_message.py`, `dian_ingestion/document_service.py` y `sql/tables/DocumentoXml.sql`.
