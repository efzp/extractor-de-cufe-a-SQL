"""Prueba de inferencia de solo lectura contra Azure SQL.

Reutiliza el motor historico para obtener las mismas variables que el snapshot
de entrenamiento; no ejecuta matching ni publica resultados en la base.
"""

from __future__ import annotations

import hashlib
import importlib.metadata
import json
import math
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

from ml_dataset.service import _write_xlsx, load_engine, query_frame
from scripts.entrenar_modelo_azure_sql import (
    FECHA,
    ID,
    PREDICTORAS,
    TARGET,
    conectar_sql,
    preparar_filas,
)


FACTURAS_SQL = """
SELECT TOP (?) v.*
FROM [ml].[vw_FacturaOrigenMlV1] AS v
JOIN [dian].[XmlExtraccion] AS e
  ON e.[DocumentoXmlID] = v.[DocumentoXmlID]
 AND e.[VersionExtractor] = v.[VersionExtractor]
JOIN [ml].[DatasetVersion] AS d
  ON d.[DatasetVersionID] = ?
 AND d.[ClienteID] = v.[ClienteID]
WHERE v.[ClienteID] = ?
  AND e.[FechaExtraccionUTC] > d.[FechaCreacionUTC]
  AND NOT EXISTS
  (
      SELECT 1
      FROM [ml].[DatasetFila] AS f
      WHERE f.[DatasetVersionID] = ?
        AND f.[DocumentoXmlID] = v.[DocumentoXmlID]
  )
ORDER BY v.[fecha_emision] DESC, v.[DocumentoXmlID] DESC;
"""


def cargar_manifiesto(carpeta_modelo: Path, cliente_id: int) -> dict:
    ruta = carpeta_modelo / "manifiesto.json"
    if not ruta.is_file() or not (carpeta_modelo / "modelo").is_dir():
        raise ValueError("La carpeta debe contener manifiesto.json y modelo/.")
    manifiesto = json.loads(ruta.read_text(encoding="utf-8"))
    version = manifiesto.get("dataset_version", {})
    if int(version.get("VersionContrato", 0)) != 1:
        raise ValueError("VersionContrato del modelo no compatible.")
    if int(version.get("ClienteID", 0)) != cliente_id:
        raise ValueError("El modelo fue entrenado para otro ClienteID.")
    if int(version.get("DatasetVersionID", 0)) <= 0:
        raise ValueError("Falta DatasetVersionID en el manifiesto.")
    if manifiesto.get("columnas_predictoras") != list(PREDICTORAS):
        raise ValueError("Las columnas predictoras no coinciden con el entrenamiento.")
    if manifiesto.get("target") != TARGET:
        raise ValueError("La etiqueta del modelo no coincide con el entrenamiento.")
    return manifiesto


def comprobar_entorno_modelo(manifiesto: dict) -> None:
    versiones = manifiesto.get("versiones", {})
    python_modelo = str(versiones.get("python", ""))
    if ".".join(python_modelo.split(".")[:2]) != ".".join(
        str(part) for part in sys.version_info[:2]
    ):
        raise RuntimeError(f"Python incompatible: modelo={python_modelo}; actual={sys.version.split()[0]}.")
    for paquete in ("autogluon.tabular", "pandas", "numpy"):
        esperado = versiones.get(paquete)
        try:
            actual = importlib.metadata.version(paquete)
        except importlib.metadata.PackageNotFoundError as error:
            raise RuntimeError(f"Falta {paquete}; usa .venv-ml e instala requirements-ml-training.txt.") from error
        if not esperado or actual != esperado:
            raise RuntimeError(f"Version incompatible de {paquete}: modelo={esperado}; actual={actual}.")


def consultar_facturas(connection, cliente_id: int, dataset_version_id: int, limite: int):
    facturas = query_frame(connection, FACTURAS_SQL,
                          (limite, dataset_version_id, cliente_id, dataset_version_id))
    if facturas.empty:
        raise ValueError("No hay facturas nuevas posteriores al snapshot del modelo para ese cliente.")
    if facturas["DocumentoXmlID"].isna().any() or facturas["DocumentoXmlID"].duplicated().any():
        raise ValueError("La consulta devolvio DocumentoXmlID nulos o repetidos.")
    if facturas["cufe"].isna().any() or facturas["cufe"].duplicated().any():
        raise ValueError("La consulta devolvio CUFE nulos o repetidos.")
    return facturas


def preparar_inferencia(facturas):
    """Usa el XLSX transitorio y las transformaciones historicas del dataset."""
    engine = load_engine()
    faltantes = set(engine.COLUMNAS_FACTURAS) - set(facturas.columns)
    if faltantes:
        raise ValueError(f"Faltan columnas de la vista origen: {sorted(faltantes)}")
    with tempfile.TemporaryDirectory(prefix="ml_inferencia_") as temporal:
        ruta = Path(temporal) / "facturas.xlsx"
        _write_xlsx(facturas[list(engine.COLUMNAS_FACTURAS)], ruta)
        # El dataset tambien normaliza desde un XLSX temporal sin carpeta XML.
        normalizadas = engine.procesar_facturas(
            str(ruta), empresa="cpabaas", ruta_xml_descripciones=Path(temporal) / "sin_xml"
        )
    if len(normalizadas) != len(facturas):
        raise ValueError("La normalizacion cambio el numero de facturas.")
    if normalizadas["cufe"].astype(str).str.lower().tolist() != facturas["cufe"].astype(str).str.lower().tolist():
        raise ValueError("La normalizacion cambio el orden o el CUFE de las facturas.")
    faltantes = (set(PREDICTORAS) | {FECHA}) - set(normalizadas.columns)
    if faltantes:
        raise ValueError(f"El motor no produjo variables: {sorted(faltantes)}")
    filas = normalizadas[[FECHA, *PREDICTORAS]].copy()
    filas.insert(0, ID, facturas["DocumentoXmlID"].to_numpy())
    # preparar_filas exige target; el marcador nunca se entrega al predictor.
    filas[TARGET] = "__SOLO_INFERENCIA__"
    preparadas = preparar_filas(filas)
    if preparadas[ID].tolist() != facturas["DocumentoXmlID"].tolist():
        raise ValueError("Se perdio la correspondencia con DocumentoXmlID.")
    return preparadas[list(PREDICTORAS)].copy()


def calcular_top3(facturas, variables, predictor):
    import pandas as pd

    probabilidades = predictor.predict_proba(variables, as_pandas=True).reset_index(drop=True)
    if len(probabilidades) != len(facturas) or probabilidades.shape[1] < 3:
        raise ValueError("La salida del modelo no coincide con las facturas o las clases.")
    salida = facturas[
        ["DocumentoXmlID", "DocumentoID", "cufe", "fecha_emision", "nit_proveedor"]
    ].reset_index(drop=True).rename(columns={
        "DocumentoXmlID": "documento_xml_id",
        "DocumentoID": "documento_id",
    }).copy()
    salida["fecha_emision"] = pd.to_datetime(salida["fecha_emision"]).dt.date
    for indice, (_, fila) in enumerate(probabilidades.iterrows()):
        valores = pd.to_numeric(fila, errors="coerce")
        if valores.isna().any() or not all(math.isfinite(float(v)) and 0 <= float(v) <= 1 for v in valores):
            raise ValueError(f"Probabilidades invalidas para DocumentoXmlID={salida.at[indice, 'documento_xml_id']}.")
        if not math.isclose(float(valores.sum()), 1.0, abs_tol=1e-4):
            raise ValueError("Las probabilidades de clase no suman 1.")
        for puesto, (etiqueta, probabilidad) in enumerate(valores.nlargest(3).items(), 1):
            salida.at[indice, f"plantilla_top{puesto}"] = str(etiqueta)
            salida.at[indice, f"probabilidad_top{puesto}"] = float(probabilidad)
    return salida


def guardar_resultado(salida_base: Path, facturas, variables, predicciones,
                     manifiesto: dict, manifest_sha256: str):
    ruta = salida_base.expanduser().resolve() / (
        f"inferencia_{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}_{uuid4().hex[:8]}"
    )
    ruta.mkdir(parents=True, exist_ok=False)
    predicciones.to_csv(ruta / "predicciones_top3.csv", index=False, encoding="utf-8-sig")
    auditoria = variables.copy()
    auditoria.insert(0, "documento_xml_id", facturas["DocumentoXmlID"].to_numpy())
    auditoria.to_csv(ruta / "variables_modelo.csv", index=False, encoding="utf-8-sig")
    resumen = {
        "fecha_utc": datetime.now(timezone.utc).isoformat(),
        "dataset_version_id_modelo": manifiesto["dataset_version"]["DatasetVersionID"],
        "cliente_id": manifiesto["dataset_version"]["ClienteID"],
        "facturas": len(predicciones),
        "documento_xml_id": facturas["DocumentoXmlID"].astype(int).tolist(),
        "columnas_predictoras": list(PREDICTORAS),
        "manifest_sha256": manifest_sha256,
        "nota": "Predicciones sin etiqueta real; no representan accuracy y no se escribieron en SQL.",
    }
    (ruta / "resumen.json").write_text(
        json.dumps(resumen, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return ruta, resumen


def ejecutar(*, carpeta_modelo: Path, servidor: str, base: str, driver: str,
            cliente_id: int, limite: int, salida_base: Path, solo_validar: bool = False):
    manifiesto = cargar_manifiesto(carpeta_modelo, cliente_id)
    dataset_version_id = int(manifiesto["dataset_version"]["DatasetVersionID"])
    connection = conectar_sql(servidor, base, driver)
    try:
        facturas = consultar_facturas(connection, cliente_id, dataset_version_id, limite)
    finally:
        connection.close()
    variables = preparar_inferencia(facturas)
    if solo_validar:
        return {"facturas": len(facturas), "documento_xml_id": facturas["DocumentoXmlID"].astype(int).tolist(),
                "variables": list(variables.columns), "solo_validar": True}
    comprobar_entorno_modelo(manifiesto)
    from autogluon.tabular import TabularPredictor

    predictor = TabularPredictor.load(str(carpeta_modelo / "modelo"))
    predicciones = calcular_top3(facturas, variables, predictor)
    manifest_sha256 = hashlib.sha256((carpeta_modelo / "manifiesto.json").read_bytes()).hexdigest()
    ruta, resumen = guardar_resultado(
        salida_base, facturas, variables, predicciones, manifiesto, manifest_sha256
    )
    return {"salida": str(ruta), **resumen}
