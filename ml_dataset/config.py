from __future__ import annotations

import os
from dataclasses import dataclass


class DatasetConfigurationError(ValueError):
    pass


@dataclass(frozen=True)
class DatasetSettings:
    sql_server: str
    sql_database: str
    sql_driver: str
    storage_account: str
    queue_name: str

    @classmethod
    def from_environment(cls) -> "DatasetSettings":
        def required(name: str) -> str:
            value = os.environ.get(name, "").strip()
            if not value or value.startswith("CONFIGURE_"):
                raise DatasetConfigurationError(f"Falta configurar {name}.")
            return value

        return cls(
            sql_server=required("DIAN_SQL_SERVER"),
            sql_database=required("DIAN_SQL_DATABASE"),
            sql_driver=os.environ.get("DIAN_SQL_DRIVER", "ODBC Driver 18 for SQL Server").strip(),
            storage_account=required("DIAN_STORAGE_ACCOUNT"),
            queue_name=required("ML_DATASET_QUEUE_NAME"),
        )
