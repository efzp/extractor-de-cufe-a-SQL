-- Ejecutar despues de instalar los tres procedimientos contables.
-- El rol no recibe SELECT, INSERT ni UPDATE directos sobre tablas.
IF NOT EXISTS
(
    SELECT 1 FROM sys.database_principals
    WHERE [name] = N'dian_runtime' AND [type] = 'R'
)
    THROW 50870, 'Falta el rol dian_runtime.', 1;

IF OBJECT_ID(N'contabilidad.sp_IniciarCargaContable', N'P') IS NULL
   OR OBJECT_ID(N'contabilidad.sp_RegistrarMovimientoContable', N'P') IS NULL
   OR OBJECT_ID(N'contabilidad.sp_FinalizarCargaContable', N'P') IS NULL
    THROW 50871, 'Faltan procedimientos contables; no se concedieron permisos.', 1;

GRANT EXECUTE ON OBJECT::[contabilidad].[sp_IniciarCargaContable] TO [dian_runtime];
GRANT EXECUTE ON OBJECT::[contabilidad].[sp_RegistrarMovimientoContable] TO [dian_runtime];
GRANT EXECUTE ON OBJECT::[contabilidad].[sp_FinalizarCargaContable] TO [dian_runtime];
