"""Entrena localmente AutoGluon con un snapshot publicado en Azure SQL.

Solo lee ml.DatasetVersion y ml.DatasetFila. No ejecuta el matching ni escribe
en SQL. El modelo y los reportes se guardan en una carpeta local nueva.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import math
import os
import struct
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path


VERSION_SQL = """
SELECT [DatasetVersionID], [ClienteID], [FuenteContable], [VersionContrato],
       [HashCodigoSha256], [HashFacturasSha256], [HashMovimientosSha256],
       CONVERT(varchar(64), [HashFilasSha256], 2) AS [HashFilasSha256],
       [TotalFacturasOrigen], [TotalFilas], [FechaCreacionUTC]
FROM [ml].[DatasetVersion]
WHERE [DatasetVersionID] = ?;
"""

FILAS_SQL = """
SELECT [DocumentoXmlID] AS [documento_xml_id],
       [NitProveedorNorm] AS [nit_proveedor_norm],
       [CiudadProveedorModelo] AS [ciudad_proveedor_modelo],
       [TaxLevelProveedorLimpio] AS [tax_level_proveedor_limpio],
       [TaxSchemeIdLimpio] AS [tax_scheme_id_limpio],
       [TaxSchemeNombreLimpio] AS [tax_scheme_nombre_limpio],
       [CodigoIndustriaProveedorLimpio] AS [codigo_industria_proveedor_limpio],
       [FechaEmision] AS [fecha_emision],
       [PayableAmount] AS [payable_amount],
       [DescuentoTotal] AS [descuento_total],
       [RecargoTotal] AS [recargo_total],
       [TieneIva] AS [tiene_iva], [TieneInc] AS [tiene_inc],
       [FlagDescuento] AS [flag_descuento],
       [FlagRecargo] AS [flag_recargo],
       [FlagUmbralRfServicios] AS [flag_umbral_rf_servicios],
       [FlagUmbralReteicaBogotaServicios] AS [flag_umbral_reteica_bogota_servicios],
       [FlagUmbralReteicaBogotaCompras] AS [flag_umbral_reteica_bogota_compras],
       [FlagDiferenciaPayableTaxInclusive] AS [flag_diferencia_payable_tax_inclusive],
       [StandardItemIdentificationLimpio] AS [standard_item_identification_limpio],
       [TargetPlantillaCuentas] AS [target_plantilla_cuentas]
FROM [ml].[DatasetFila]
WHERE [DatasetVersionID] = ?
ORDER BY [DocumentoXmlID];
"""

TARGET = "target_plantilla_cuentas"
ID = "documento_xml_id"
FECHA = "fecha_emision"
PREDICTORAS = (
    "nit_proveedor_norm", "ciudad_proveedor_modelo",
    "tax_level_proveedor_limpio", "tax_scheme_id_limpio",
    "tax_scheme_nombre_limpio", "codigo_industria_proveedor_limpio",
    "payable_amount", "descuento_total", "recargo_total",
    "tiene_iva", "tiene_inc", "flag_descuento", "flag_recargo",
    "flag_umbral_rf_servicios", "flag_umbral_reteica_bogota_servicios",
    "flag_umbral_reteica_bogota_compras",
    "flag_diferencia_payable_tax_inclusive",
    "standard_item_identification_limpio",
)
NUMERICAS = ("payable_amount", "descuento_total", "recargo_total")
BOOLEANAS = (
    "tiene_iva", "tiene_inc", "flag_descuento", "flag_recargo",
    "flag_umbral_rf_servicios", "flag_umbral_reteica_bogota_servicios",
    "flag_umbral_reteica_bogota_compras",
    "flag_diferencia_payable_tax_inclusive",
)
CATEGORICAS = ("nit_proveedor_norm", "codigo_industria_proveedor_limpio")


def argumentos(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-version-id", type=int, required=True)
    parser.add_argument("--servidor", default=os.getenv("DIAN_SQL_SERVER"))
    parser.add_argument("--base", default=os.getenv("DIAN_SQL_DATABASE"))
    parser.add_argument(
        "--driver", default=os.getenv("DIAN_SQL_DRIVER", "ODBC Driver 18 for SQL Server")
    )
    parser.add_argument("--salida", type=Path, required=True,
                        help="Carpeta local donde se creara una subcarpeta por ejecucion.")
    parser.add_argument("--fraccion-prueba", type=float, default=0.20,
                        help="Fraccion objetivo; se reservan meses calendario completos.")
    parser.add_argument("--max-meses-prueba", type=int, default=2,
                        help="Maximo de meses calendario recientes para la prueba (1 a 3).")
    parser.add_argument("--min-observaciones-clase", type=int, default=2)
    parser.add_argument("--meses-recientes", type=int, default=12)
    parser.add_argument("--factor-oversampling", type=int, default=2)
    parser.add_argument("--sin-oversampling-reciente", action="store_true")
    parser.add_argument("--presets", default="best_quality")
    parser.add_argument("--tiempo-segundos", type=int, default=1500)
    parser.add_argument("--solo-validar", action="store_true",
                        help="Comprueba SQL y la particion sin instalar AutoGluon ni entrenar.")
    args = parser.parse_args(argv)
    if args.dataset_version_id <= 0:
        parser.error("--dataset-version-id debe ser positivo.")
    if not args.servidor or not args.base:
        parser.error("Indica --servidor y --base, o configura DIAN_SQL_SERVER y DIAN_SQL_DATABASE.")
    if not 0 < args.fraccion_prueba < 0.5:
        parser.error("--fraccion-prueba debe estar entre 0 y 0.5.")
    if not 1 <= args.max_meses_prueba <= 3:
        parser.error("--max-meses-prueba debe estar entre 1 y 3.")
    if args.min_observaciones_clase < 2 or args.meses_recientes < 1:
        parser.error("El minimo por clase debe ser >= 2 y los meses recientes >= 1.")
    if args.factor_oversampling < 1 or args.tiempo_segundos < 1:
        parser.error("El factor de oversampling y el tiempo deben ser positivos.")
    return args


def conectar_sql(servidor: str, base: str, driver: str):
    import pyodbc
    from azure.identity import AzureCliCredential

    token = AzureCliCredential().get_token("https://database.windows.net/.default").token
    token_bytes = token.encode("utf-16-le")
    token_odbc = struct.pack("=i", len(token_bytes)) + token_bytes
    cadena = (
        f"DRIVER={{{driver}}};SERVER=tcp:{servidor},1433;DATABASE={base};"
        "Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"
    )
    return pyodbc.connect(cadena, attrs_before={1256: token_odbc}, autocommit=True)


def consultar(connection, query: str, parametros: tuple):
    import pandas as pd

    cursor = connection.cursor()
    try:
        cursor.execute(query, parametros)
        columnas = [col[0] for col in cursor.description]
        return pd.DataFrame.from_records(
            (tuple(fila) for fila in cursor.fetchall()), columns=columnas
        )
    finally:
        cursor.close()


def cargar_snapshot(connection, dataset_version_id: int):
    version = consultar(connection, VERSION_SQL, (dataset_version_id,))
    if len(version) != 1:
        raise ValueError(f"No existe DatasetVersionID={dataset_version_id}.")
    meta = version.iloc[0].to_dict()
    if int(meta["VersionContrato"]) != 1:
        raise ValueError("La version del contrato ML no es compatible con este adaptador.")
    filas = consultar(connection, FILAS_SQL, (dataset_version_id,))
    if len(filas) != int(meta["TotalFilas"]):
        raise ValueError("El numero de filas no coincide con ml.DatasetVersion.TotalFilas.")
    if filas[ID].isna().any() or filas[ID].duplicated().any():
        raise ValueError("El snapshot contiene DocumentoXmlID nulos o repetidos.")
    return meta, filas


def preparar_filas(filas):
    """Replica las transformaciones relevantes del entrenamiento historico."""
    import pandas as pd

    esperadas = set(PREDICTORAS) | {ID, FECHA, TARGET}
    faltantes = esperadas - set(filas.columns)
    if faltantes:
        raise ValueError(f"Faltan columnas del contrato ML: {sorted(faltantes)}")
    salida = filas[[ID, FECHA, *PREDICTORAS, TARGET]].copy()
    salida[FECHA] = pd.to_datetime(salida[FECHA], errors="coerce")
    if salida[FECHA].isna().any():
        raise ValueError("Hay fechas de emision nulas o invalidas.")
    salida[TARGET] = salida[TARGET].astype("string").str.strip()
    if salida[TARGET].isna().any() or salida[TARGET].eq("").any():
        raise ValueError("Hay etiquetas de plantilla nulas o vacias.")
    salida[TARGET] = salida[TARGET].astype(object)
    salida["codigo_industria_proveedor_limpio"] = (
        salida["codigo_industria_proveedor_limpio"]
        .astype("string").str.split(";", n=1).str[0].str.strip()
        .replace("", pd.NA)
    )
    for columna in (*NUMERICAS, *BOOLEANAS):
        salida[columna] = pd.to_numeric(salida[columna], errors="coerce").astype("float64")
    for columna in CATEGORICAS:
        salida[columna] = (
            salida[columna].astype("string").str.strip()
            .replace({"": pd.NA, "nan": pd.NA, "None": pd.NA, "<NA>": pd.NA})
            .astype("category")
        )
    return salida


def partir_temporal(filas, fraccion_prueba: float, max_meses_prueba: int = 2):
    """Reserva meses completos recientes hasta la meta o el limite temporal."""
    ordenado = filas.sort_values([FECHA, ID], kind="mergesort").reset_index(drop=True)
    meta_filas = math.ceil(len(ordenado) * fraccion_prueba)
    ultimo_mes = ordenado[FECHA].max().to_period("M")
    inicio_mes = (ultimo_mes - (max_meses_prueba - 1)).to_timestamp()
    meses = ordenado.loc[ordenado[FECHA] >= inicio_mes, FECHA].dt.to_period("M")
    conteos = meses.value_counts()
    primer_mes_prueba = ultimo_mes
    acumuladas = 0
    for retroceso in range(max_meses_prueba):
        mes = ultimo_mes - retroceso
        acumuladas += int(conteos.get(mes, 0))
        primer_mes_prueba = mes
        if acumuladas >= meta_filas:
            break
    corte = primer_mes_prueba.to_timestamp()
    train = ordenado.loc[ordenado[FECHA] < corte].copy()
    test = ordenado.loc[ordenado[FECHA] >= corte].copy()
    if len(train) < 2 or test.empty:
        raise ValueError("No hay suficientes filas anteriores al periodo de prueba.")
    return train, test


def filtrar_clases_entrenables(train, minimo: int):
    conteos = train[TARGET].value_counts()
    validas = set(conteos[conteos >= minimo].index)
    filtrado = train[train[TARGET].isin(validas)].copy()
    if filtrado[TARGET].nunique() < 2:
        raise ValueError("Quedaron menos de dos clases entrenables en la particion historica.")
    return filtrado, conteos


def oversampling_reciente(train, fecha_inicio_prueba, meses: int, factor: int):
    """Replica solo filas de meses completos anteriores al primer mes de prueba."""
    import pandas as pd

    inicio_prueba = pd.Timestamp(fecha_inicio_prueba).to_period("M").to_timestamp()
    corte = (inicio_prueba.to_period("M") - meses).to_timestamp()
    recientes = train.loc[(train[FECHA] >= corte) & (train[FECHA] < inicio_prueba)].copy()
    if factor == 1:
        return train.copy(), {
            "activo": False, "meses_recientes": meses, "factor": factor,
            "fecha_corte": corte.date().isoformat(),
            "fecha_fin_exclusiva": inicio_prueba.date().isoformat(),
            "filas_recientes": len(recientes),
            "filas_antes": len(train), "filas_despues": len(train),
        }
    salida = pd.concat([train] + [recientes.copy() for _ in range(factor - 1)],
                       ignore_index=True)
    return salida, {
        "activo": True, "meses_recientes": meses, "factor": factor,
        "fecha_corte": corte.date().isoformat(), "filas_recientes": len(recientes),
        "fecha_fin_exclusiva": inicio_prueba.date().isoformat(),
        "filas_antes": len(train), "filas_despues": len(salida),
    }


def datos_modelo(filas):
    """Excluye deliberadamente identificadores, fecha, match y asiento."""
    return filas[[*PREDICTORAS, TARGET]].copy()


def _version_paquete(nombre: str) -> str | None:
    try:
        return importlib.metadata.version(nombre)
    except importlib.metadata.PackageNotFoundError:
        return None


def _serializable(valor):
    if valor is None or isinstance(valor, (str, int, float, bool)):
        return valor
    if hasattr(valor, "isoformat"):
        return valor.isoformat()
    if hasattr(valor, "item"):
        return _serializable(valor.item())
    return str(valor)


def hash_lectura_sql(filas) -> str:
    """Detecta cambios posteriores en las columnas leidas de esta version."""
    contenido = json.dumps(
        filas.to_dict(orient="records"), ensure_ascii=False, sort_keys=True,
        separators=(",", ":"), default=_serializable,
    )
    return hashlib.sha256(contenido.encode("utf-8")).hexdigest()


def main(argv: list[str] | None = None):
    import pandas as pd

    args = argumentos(argv)
    connection = conectar_sql(args.servidor, args.base, args.driver)
    try:
        meta, filas_sql = cargar_snapshot(connection, args.dataset_version_id)
    finally:
        connection.close()

    filas = preparar_filas(filas_sql)
    train_total, test = partir_temporal(
        filas, args.fraccion_prueba, args.max_meses_prueba
    )
    train_filtrado, conteos = filtrar_clases_entrenables(
        train_total, args.min_observaciones_clase
    )
    train, oversampling = oversampling_reciente(
        train_filtrado, test[FECHA].min(), args.meses_recientes,
        1 if args.sin_oversampling_reciente else args.factor_oversampling,
    )
    clases_train = set(train_filtrado[TARGET])
    conocidas = test[TARGET].isin(clases_train)
    resumen = {
        "dataset_version_id": args.dataset_version_id,
        "hash_lectura_sql_sha256": hash_lectura_sql(filas_sql),
        "cliente_id": int(meta["ClienteID"]),
        "fuente_contable": str(meta["FuenteContable"]),
        "filas_snapshot": len(filas),
        "min_observaciones_clase": args.min_observaciones_clase,
        "fraccion_prueba_objetivo": args.fraccion_prueba,
        "fraccion_prueba_real": len(test) / len(filas),
        "max_meses_prueba": args.max_meses_prueba,
        "meses_prueba_reales": int(test[FECHA].dt.to_period("M").nunique()),
        "primer_mes_prueba": str(test[FECHA].min().to_period("M")),
        "filas_train_antes_filtro": len(train_total),
        "filas_train_entrenables": len(train_filtrado),
        "filas_train_tras_oversampling": len(train),
        "filas_prueba": len(test),
        "filas_prueba_clase_conocida": int(conocidas.sum()),
        "filas_prueba_clase_nueva": int((~conocidas).sum()),
        "clases_train_entrenables": len(clases_train),
        "clases_train_excluidas": int((conteos < args.min_observaciones_clase).sum()),
        "periodo_train_desde": train_filtrado[FECHA].min().date().isoformat(),
        "periodo_train_hasta": train_filtrado[FECHA].max().date().isoformat(),
        "periodo_prueba_desde": test[FECHA].min().date().isoformat(),
        "periodo_prueba_hasta": test[FECHA].max().date().isoformat(),
        "oversampling": oversampling,
    }
    if args.solo_validar:
        print(json.dumps(resumen, ensure_ascii=False, indent=2))
        return resumen

    try:
        from autogluon.tabular import TabularPredictor
    except ImportError as error:
        raise RuntimeError(
            "Falta AutoGluon. Instala requirements-ml-training.txt en un entorno local."
        ) from error

    fecha_utc = datetime.now(timezone.utc)
    salida = args.salida.expanduser().resolve() / (
        f"dataset_v{args.dataset_version_id}_{fecha_utc:%Y%m%dT%H%M%SZ}_{uuid.uuid4().hex[:8]}"
    )
    salida.mkdir(parents=True, exist_ok=False)
    modelo_path = salida / "modelo"
    train_data = datos_modelo(train)
    test_data = datos_modelo(test)

    predictor = TabularPredictor(
        label=TARGET,
        problem_type="binary" if len(clases_train) == 2 else "multiclass",
        eval_metric="accuracy",
        path=str(modelo_path),
        learner_kwargs={"label_count_threshold": args.min_observaciones_clase},
    ).fit(
        train_data=train_data,
        presets=args.presets,
        time_limit=args.tiempo_segundos,
        dynamic_stacking=False,
    )

    # AutoGluon puede descartar clases raras aunque hayan pasado nuestro filtro.
    clases_modelo = set(predictor.class_labels)
    conocidas = test[TARGET].isin(clases_modelo)
    resumen["clases_modelo"] = len(clases_modelo)
    resumen["filas_prueba_clase_conocida"] = int(conocidas.sum())
    resumen["filas_prueba_clase_nueva"] = int((~conocidas).sum())

    datos_prueba = test_data.drop(columns=[TARGET])
    predicciones = predictor.predict(datos_prueba).astype("string")
    probabilidades = predictor.predict_proba(datos_prueba, as_pandas=True)
    top_n = min(3, len(probabilidades.columns))
    top_etiquetas = probabilidades.apply(
        lambda fila: [str(etiqueta) for etiqueta in fila.nlargest(top_n).index], axis=1
    )
    evaluacion = pd.DataFrame({
        ID: test[ID].to_numpy(),
        "fecha_emision": test[FECHA].dt.date.to_numpy(),
        "etiqueta_real": test[TARGET].to_numpy(),
        "etiqueta_predicha": predicciones.to_numpy(),
        "clase_conocida": conocidas.to_numpy(),
    })
    evaluacion["acierto"] = evaluacion["etiqueta_real"] == evaluacion["etiqueta_predicha"]
    evaluacion["etiquetas_top3"] = [
        json.dumps(etiquetas, ensure_ascii=False) for etiquetas in top_etiquetas
    ]
    evaluacion["acierto_top3"] = [
        str(real) in etiquetas for real, etiquetas in zip(evaluacion["etiqueta_real"], top_etiquetas)
    ]
    evaluacion["confianza_top1"] = probabilidades.max(axis=1).to_numpy()
    resumen["accuracy_prueba_total"] = float(evaluacion["acierto"].mean())
    resumen["accuracy_prueba_clases_conocidas"] = (
        float(evaluacion.loc[evaluacion["clase_conocida"], "acierto"].mean())
        if conocidas.any() else None
    )
    resumen["accuracy_top3_prueba_total"] = float(evaluacion["acierto_top3"].mean())
    resumen["accuracy_top3_prueba_clases_conocidas"] = (
        float(evaluacion.loc[evaluacion["clase_conocida"], "acierto_top3"].mean())
        if conocidas.any() else None
    )
    clase_mayoritaria = str(train_filtrado[TARGET].value_counts().idxmax())
    resumen["accuracy_base_clase_mayoritaria"] = float((test[TARGET] == clase_mayoritaria).mean())
    resumen["clase_mayoritaria_train"] = clase_mayoritaria

    particion = pd.concat([
        train_total[[ID, FECHA]].assign(particion="train"),
        test[[ID, FECHA]].assign(particion="prueba"),
    ]).sort_values(ID)
    particion["entrenable"] = particion[ID].isin(set(train_filtrado[ID]))
    particion.to_csv(salida / "particion.csv", index=False, encoding="utf-8-sig")
    evaluacion.to_csv(salida / "predicciones_prueba.csv", index=False, encoding="utf-8-sig")
    predictor.leaderboard(silent=True).to_csv(salida / "leaderboard_interno.csv", index=False)

    manifest = {
        "fecha_utc": fecha_utc.isoformat(),
        "servidor": args.servidor, "base": args.base,
        "dataset_version": {k: _serializable(v) for k, v in meta.items()},
        "script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "columnas_predictoras": list(PREDICTORAS),
        "target": TARGET,
        "particion": "meses calendario recientes por FechaEmision, no por fecha contable",
        "fraccion_prueba": args.fraccion_prueba,
        "max_meses_prueba": args.max_meses_prueba,
        "min_observaciones_clase": args.min_observaciones_clase,
        "presets": args.presets, "tiempo_segundos": args.tiempo_segundos,
        "versiones": {
            "python": sys.version.split()[0],
            "autogluon.tabular": _version_paquete("autogluon.tabular"),
            "pandas": _version_paquete("pandas"),
            "numpy": _version_paquete("numpy"),
            "scikit-learn": _version_paquete("scikit-learn"),
            "pyodbc": _version_paquete("pyodbc"),
        },
        "resumen": resumen,
        "nota": "El leaderboard es interno; accuracy_prueba_total usa facturas no vistas.",
    }
    (salida / "manifiesto.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps({"salida": str(salida), **resumen}, ensure_ascii=False, indent=2))
    return manifest


if __name__ == "__main__":
    main()
