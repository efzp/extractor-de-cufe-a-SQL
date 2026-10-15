"""Smoke test offline del artefacto AutoGluon en Linux (sin Azure ni SQL).

Verifica SHA-256 del tar.gz y manifiesto, extrae solo archivos seguros, ejecuta
la limpieza historica sobre una factura sintetica y compara el top 3 de diez
facturas anonimizadas por DocumentoXmlID con una inferencia de referencia.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import platform
import sys
import tarfile
import tempfile
from datetime import date
from decimal import Decimal
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from ml_inferencia import service  # noqa: E402
from scripts.entrenar_modelo_azure_sql import (  # noqa: E402
    BOOLEANAS, CATEGORICAS, NUMERICAS, PREDICTORAS,
)


def sha256_archivo(ruta: Path) -> str:
    digest = hashlib.sha256()
    with ruta.open("rb") as archivo:
        for bloque in iter(lambda: archivo.read(1024 * 1024), b""):
            digest.update(bloque)
    return digest.hexdigest()


def extraer_modelo_seguro(paquete: Path, destino: Path) -> None:
    with tarfile.open(paquete, "r:gz") as archivo:
        miembros = archivo.getmembers()
        if not miembros or sum(item.size for item in miembros) > 4_000_000_000:
            raise ValueError("Paquete vacio o excesivamente grande.")
        for item in miembros:
            ruta = PurePosixPath(item.name)
            if (ruta.is_absolute() or not ruta.parts
                    or (ruta.parts[0] != "modelo" and item.name != "manifiesto.json")
                    or any(parte in (".", "..") for parte in ruta.parts)
                    or not (item.isfile() or item.isdir())
                    or (item.name == "manifiesto.json" and not item.isfile())):
                raise ValueError(f"Entrada no permitida en tar.gz: {item.name}")
        archivo.extractall(destino)
    if not (destino / "modelo" / "predictor.pkl").is_file():
        raise ValueError("El paquete no contiene modelo/predictor.pkl.")


def probar_limpieza() -> dict:
    import pandas as pd

    engine = service.load_engine()
    factura = {columna: None for columna in engine.COLUMNAS_FACTURAS}
    factura.update({
        "id_carga": "dian:1", "id_factura": "FV-1", "cufe": "a" * 96,
        "factura_completa": "FV-1", "fecha_emision": date(2026, 10, 5),
        "nit_proveedor": "901913064", "nombre_proveedor": "Proveedor Uno",
        "ciudad_proveedor": "Bogota", "codigo_industria_proveedor": "1000;2000",
        "tax_exclusive_amount": Decimal("100.00"),
        "tax_inclusive_amount": Decimal("119.00"),
        "payable_amount": Decimal("119.00"), "iva_total": Decimal("19.00"),
        "inc_total": Decimal("0"), "descuento_total": Decimal("0"),
        "recargo_total": Decimal("0"),
        "DocumentoXmlID": 1, "DocumentoID": 1, "VersionExtractor": 1,
    })
    variables = service.preparar_inferencia(pd.DataFrame([factura]))
    if list(variables.columns) != list(PREDICTORAS):
        raise ValueError("La limpieza no produjo las 18 variables en el orden esperado.")
    if str(variables.iloc[0]["nit_proveedor_norm"]) != "901913064":
        raise ValueError("La limpieza altero el NIT de la factura sintetica.")
    if float(variables.iloc[0]["payable_amount"]) != 119.0:
        raise ValueError("La limpieza altero el valor de la factura sintetica.")
    return {"facturas_sinteticas": 1, "variables": len(variables.columns)}


def cargar_referencia(referencia_dir: Path):
    import pandas as pd

    resumen = json.loads((referencia_dir / "resumen.json").read_text(encoding="utf-8"))
    predicciones = pd.read_csv(referencia_dir / "predicciones_top3.csv")
    # Preservar codigos como "01": la inferencia original no los trato como numeros.
    texto = {columna: "string" for columna in PREDICTORAS
             if columna not in (*NUMERICAS, *BOOLEANAS)}
    auditoria = pd.read_csv(referencia_dir / "variables_modelo.csv", dtype=texto)
    if len(predicciones) != 10 or len(auditoria) != 10 or int(resumen["facturas"]) != 10:
        raise ValueError("La referencia debe contener exactamente diez facturas.")
    ids = predicciones["documento_xml_id"].astype(int).tolist()
    if ids != auditoria["documento_xml_id"].astype(int).tolist() or ids != resumen["documento_xml_id"]:
        raise ValueError("Los DocumentoXmlID de la referencia no coinciden en orden.")
    if resumen["columnas_predictoras"] != list(PREDICTORAS):
        raise ValueError("La referencia usa otro contrato de variables.")
    variables = auditoria[list(PREDICTORAS)].copy()
    for columna in (*NUMERICAS, *BOOLEANAS):
        variables[columna] = pd.to_numeric(variables[columna], errors="coerce").astype("float64")
    for columna in CATEGORICAS:
        variables[columna] = (
            variables[columna].astype("string").str.strip()
            .replace({"": pd.NA, "nan": pd.NA, "None": pd.NA, "<NA>": pd.NA})
            .astype("category")
        )
    return resumen, predicciones, variables


def comparar_top3(referencia, calculadas) -> None:
    for i in range(len(referencia)):
        xml_id = int(referencia.iloc[i]["documento_xml_id"])
        if xml_id != int(calculadas.iloc[i]["documento_xml_id"]):
            raise ValueError("Cambio el orden de los DocumentoXmlID.")
        for puesto in (1, 2, 3):
            etiqueta = f"plantilla_top{puesto}"
            probabilidad = f"probabilidad_top{puesto}"
            if str(referencia.iloc[i][etiqueta]) != str(calculadas.iloc[i][etiqueta]):
                raise ValueError(f"Top {puesto} distinto para DocumentoXmlID={xml_id}.")
            if not math.isclose(float(referencia.iloc[i][probabilidad]),
                                float(calculadas.iloc[i][probabilidad]),
                                rel_tol=0, abs_tol=1e-6):
                raise ValueError(
                    f"Probabilidad top {puesto} distinta para DocumentoXmlID={xml_id}: "
                    f"referencia={referencia.iloc[i][probabilidad]}, "
                    f"calculada={calculadas.iloc[i][probabilidad]}."
                )


def ejecutar(paquete: Path, manifiesto: Path, referencia_dir: Path,
            sha256_paquete: str) -> dict:
    if not paquete.is_file() or not manifiesto.is_file() or not referencia_dir.is_dir():
        raise ValueError("Falta paquete, manifiesto o carpeta de referencia.")
    digest = sha256_archivo(paquete)
    if digest != sha256_paquete.lower():
        raise ValueError("SHA-256 del paquete distinto al esperado.")
    resumen, referencia, variables = cargar_referencia(referencia_dir)
    hash_manifiesto = sha256_archivo(manifiesto)
    if hash_manifiesto != resumen["manifest_sha256"]:
        raise ValueError("SHA-256 del manifiesto distinto a la referencia.")
    with tempfile.TemporaryDirectory(prefix="dian_ml_linux_smoke_") as temporal:
        carpeta = Path(temporal)
        extraer_modelo_seguro(paquete, carpeta)
        if sha256_archivo(carpeta / "manifiesto.json") != hash_manifiesto:
            raise ValueError("El manifiesto incluido en el paquete es distinto al externo.")
        metadatos = service.cargar_manifiesto(carpeta, int(resumen["cliente_id"]))
        service.comprobar_entorno_modelo(metadatos)
        limpieza = probar_limpieza()

        from autogluon.tabular import TabularPredictor

        predictor = TabularPredictor.load(str(carpeta / "modelo"))
        facturas = referencia[[
            "documento_xml_id", "documento_id", "cufe", "fecha_emision", "nit_proveedor"
        ]].rename(columns={"documento_xml_id": "DocumentoXmlID", "documento_id": "DocumentoID"})
        calculadas = service.calcular_top3(facturas, variables, predictor)
        comparar_top3(referencia, calculadas)

    return {
        "resultado": "OK_OFFLINE_SIN_SQL",
        "plataforma": platform.system(),
        "modelo_artefacto_sha256": digest,
        "manifiesto_sha256": hash_manifiesto,
        "dataset_version_id": metadatos["dataset_version"]["DatasetVersionID"],
        "facturas_referencia": len(referencia),
        "opciones_top3_verificadas": len(referencia) * 3,
        "limpieza": limpieza,
    }


def main(argv: list[str] | None = None) -> dict:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--paquete", type=Path, required=True)
    parser.add_argument("--manifiesto", type=Path, required=True)
    parser.add_argument("--referencia-dir", type=Path, required=True)
    parser.add_argument("--sha256-paquete", required=True)
    args = parser.parse_args(argv)
    resultado = ejecutar(args.paquete, args.manifiesto, args.referencia_dir, args.sha256_paquete)
    print(json.dumps(resultado, ensure_ascii=False, indent=2))
    return resultado


if __name__ == "__main__":
    main()
